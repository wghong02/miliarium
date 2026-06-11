import Foundation
import UIKit
import AVFoundation
import FirebaseFirestore
import FirebaseStorage
internal import os

/// Upload, list, and delete photo/video attachments on an activity.
///
/// The binary lives in Firebase Storage at:
///   `gs://{bucket}/activities/{progressItemId}/{activityId}/{mediaId}.{ext}`
///
/// Each upload also writes a metadata doc at:
///   `progressItems/{progressItemId}/activities/{activityId}/media/{mediaId}`
///
/// **Deletion**: removing a media item only deletes the Firestore doc and
/// the Storage file. When an entire activity is deleted, the
/// `onActivityDeleted` Cloud Function cascades-deletes the media
/// subcollection + Storage files on the server.
final class MediaService {
    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    // MARK: - References

    private func mediaCollection(
        progressItemId: String,
        activityId: String
    ) -> CollectionReference {
        db.collection("progressItems")
            .document(progressItemId)
            .collection("activities")
            .document(activityId)
            .collection("media")
    }

    private func storagePath(
        progressItemId: String,
        activityId: String,
        mediaId: String,
        fileExtension: String
    ) -> String {
        "activities/\(progressItemId)/\(activityId)/\(mediaId).\(fileExtension)"
    }

    // MARK: - Upload

    /// Uploads an image to Storage and writes a metadata doc to Firestore.
    /// The image is JPEG-compressed to ~85% quality to keep file sizes
    /// reasonable. Returns the created `ActivityMedia`.
    func uploadImage(
        _ image: UIImage,
        progressItemId: String,
        activityId: String,
        uploadedBy: String
    ) async throws -> ActivityMedia {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw MediaServiceError.imageEncodingFailed
        }
        let mediaId = UUID().uuidString
        let path = storagePath(
            progressItemId: progressItemId,
            activityId: activityId,
            mediaId: mediaId,
            fileExtension: "jpg"
        )

        AppLogger.media.debug("uploadImage start path=\(path) bytes=\(data.count)")

        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.customMetadata = ["uploadedBy": uploadedBy]

        let ref = storage.reference(withPath: path)
        _ = try await ref.putDataAsync(data, metadata: metadata)

        let media = ActivityMedia(
            id: mediaId,
            type: .image,
            storagePath: path,
            uploadedBy: uploadedBy,
            sizeBytes: Int64(data.count),
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )

        try await mediaCollection(
            progressItemId: progressItemId,
            activityId: activityId
        )
        .document(mediaId)
        .setData(media.asFirestoreMap())

        AppLogger.media.debug("uploadImage succeeded path=\(path)")
        return media
    }

    /// Uploads a video file (already on disk) to Storage and writes the
    /// matching Firestore doc. Pass the on-disk URL of the video — usually
    /// what `PhotosPickerItem.loadTransferable(type: Movie.self)` returns.
    func uploadVideo(
        fileURL: URL,
        progressItemId: String,
        activityId: String,
        uploadedBy: String
    ) async throws -> ActivityMedia {
        let mediaId = UUID().uuidString
        let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased()
        let path = storagePath(
            progressItemId: progressItemId,
            activityId: activityId,
            mediaId: mediaId,
            fileExtension: ext
        )

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.int64Value

        AppLogger.media.debug("uploadVideo start path=\(path) bytes=\(sizeBytes ?? -1)")

        // Probe duration + dimensions so the UI can render a sensibly-sized
        // thumbnail without downloading the full file.
        let asset = AVURLAsset(url: fileURL)
        let duration: Double? = await {
            do { return try await asset.load(.duration).seconds }
            catch { return nil }
        }()
        let (videoWidth, videoHeight): (Int?, Int?) = await {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return (nil, nil) }
                let size = try await track.load(.naturalSize)
                return (Int(abs(size.width)), Int(abs(size.height)))
            } catch {
                return (nil, nil)
            }
        }()

        let metadata = StorageMetadata()
        metadata.contentType = contentType(forVideoExtension: ext)
        metadata.customMetadata = ["uploadedBy": uploadedBy]

        let ref = storage.reference(withPath: path)
        _ = try await ref.putFileAsync(from: fileURL, metadata: metadata)

        let media = ActivityMedia(
            id: mediaId,
            type: .video,
            storagePath: path,
            uploadedBy: uploadedBy,
            sizeBytes: sizeBytes,
            width: videoWidth,
            height: videoHeight,
            durationSeconds: duration
        )

        try await mediaCollection(
            progressItemId: progressItemId,
            activityId: activityId
        )
        .document(mediaId)
        .setData(media.asFirestoreMap())

        AppLogger.media.debug("uploadVideo succeeded path=\(path)")
        return media
    }

    // MARK: - Read

    /// Fetches all media for an activity, newest first.
    func fetchMedia(
        progressItemId: String,
        activityId: String
    ) async throws -> [ActivityMedia] {
        let snapshot = try await mediaCollection(
            progressItemId: progressItemId,
            activityId: activityId
        )
        .order(by: "uploadedAt", descending: true)
        .getDocuments()
        return snapshot.documents.compactMap { ActivityMedia(document: $0) }
    }

    /// Live listener for the media subcollection.
    func setMediaListener(
        progressItemId: String,
        activityId: String,
        onChange: @escaping ([ActivityMedia]) -> Void
    ) -> ListenerRegistration {
        return mediaCollection(progressItemId: progressItemId, activityId: activityId)
            .order(by: "uploadedAt", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    AppLogger.media.error("mediaListener error: \(error.localizedDescription)")
                    return
                }
                guard let snapshot else { return }
                let items = snapshot.documents.compactMap { ActivityMedia(document: $0) }
                onChange(items)
            }
    }

    /// Returns a downloadable URL for the given Storage path. Useful for
    /// `AsyncImage` and `AVPlayer` to stream the asset directly.
    func downloadURL(for storagePath: String) async throws -> URL {
        try await storage.reference(withPath: storagePath).downloadURL()
    }

    // MARK: - Delete

    /// Deletes a single media item: removes the Storage file AND the
    /// Firestore doc. Tolerant of either side already being missing —
    /// "not found" is treated as success so retries are idempotent.
    func deleteMedia(
        _ media: ActivityMedia,
        progressItemId: String,
        activityId: String
    ) async throws {
        AppLogger.media.debug("deleteMedia id=\(media.id) path=\(media.storagePath)")

        // Storage delete — ignore not-found.
        do {
            try await storage.reference(withPath: media.storagePath).delete()
        } catch let error as NSError where error.domain == StorageErrorDomain
            && error.code == StorageErrorCode.objectNotFound.rawValue {
            AppLogger.media.debug("deleteMedia: storage object already missing")
        }

        // Firestore delete — also idempotent.
        try await mediaCollection(
            progressItemId: progressItemId,
            activityId: activityId
        )
        .document(media.id)
        .delete()
    }

    // MARK: - Helpers

    private func contentType(forVideoExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }
}

enum MediaServiceError: LocalizedError {
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "Could not encode the selected image."
        }
    }
}

let mediaService = MediaService()
