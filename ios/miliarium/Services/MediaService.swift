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
/// **Deletion**: the client deletes only the Firestore media doc. The
/// `onMediaDeleted` Cloud Function reacts and removes the Storage binary
/// server-side. When an entire activity is deleted, `onActivityDeleted`
/// cascades-deletes the media subcollection + Storage files. Uploads still
/// write to Storage directly from the client.
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

    // MARK: - Backend upload helpers

    private struct UploadTicket: Decodable {
        let mediaId: String
        let storagePath: String
        let uploadURL: String
    }

    /// Asks the backend for a short-lived signed PUT URL + the storage path.
    private func requestUploadTicket(
        progressItemId: String,
        activityId: String,
        contentType: String,
        ext: String
    ) async throws -> UploadTicket {
        struct Body: Encodable { let contentType: String; let ext: String }
        return try await BackendClient.shared.send(
            "POST",
            "/progress/\(progressItemId)/activities/\(activityId)/media/upload-url",
            body: Body(contentType: contentType, ext: ext)
        )
    }

    /// Uploads bytes (in-memory `data` or an on-disk `fileURL`) straight to the
    /// signed URL. The signature authorizes the write, so no bearer token here.
    private func putToSignedURL(
        _ urlString: String,
        contentType: String,
        data: Data?,
        fileURL: URL?
    ) async throws {
        guard let url = URL(string: urlString) else { throw MediaServiceError.uploadFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let response: URLResponse
        if let fileURL {
            (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
        } else {
            (_, response) = try await URLSession.shared.upload(for: req, from: data ?? Data())
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MediaServiceError.uploadFailed
        }
    }

    private struct CommitBody: Encodable {
        let mediaId: String
        let storagePath: String
        let type: String
        let width: Int?
        let height: Int?
        let durationSeconds: Double?
    }

    /// Commits the media metadata doc after a successful upload.
    private func commitMedia(
        progressItemId: String,
        activityId: String,
        body: CommitBody
    ) async throws {
        try await BackendClient.shared.request(
            "POST",
            "/progress/\(progressItemId)/activities/\(activityId)/media",
            body: body
        )
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
        AppLogger.media.debug("uploadImage start bytes=\(data.count)")

        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)

        let ticket = try await requestUploadTicket(
            progressItemId: progressItemId,
            activityId: activityId,
            contentType: "image/jpeg",
            ext: "jpg"
        )
        try await putToSignedURL(ticket.uploadURL, contentType: "image/jpeg", data: data, fileURL: nil)
        try await commitMedia(
            progressItemId: progressItemId,
            activityId: activityId,
            body: CommitBody(
                mediaId: ticket.mediaId,
                storagePath: ticket.storagePath,
                type: "image",
                width: width,
                height: height,
                durationSeconds: nil
            )
        )

        AppLogger.media.debug("uploadImage succeeded path=\(ticket.storagePath)")
        return ActivityMedia(
            id: ticket.mediaId,
            type: .image,
            storagePath: ticket.storagePath,
            uploadedBy: uploadedBy,
            sizeBytes: Int64(data.count),
            width: width,
            height: height
        )
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
        let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased()

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes?[.size] as? NSNumber)?.int64Value

        AppLogger.media.debug("uploadVideo start ext=\(ext) bytes=\(sizeBytes ?? -1)")

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

        let type = contentType(forVideoExtension: ext)
        let ticket = try await requestUploadTicket(
            progressItemId: progressItemId,
            activityId: activityId,
            contentType: type,
            ext: ext
        )
        try await putToSignedURL(ticket.uploadURL, contentType: type, data: nil, fileURL: fileURL)
        try await commitMedia(
            progressItemId: progressItemId,
            activityId: activityId,
            body: CommitBody(
                mediaId: ticket.mediaId,
                storagePath: ticket.storagePath,
                type: "video",
                width: videoWidth,
                height: videoHeight,
                durationSeconds: duration
            )
        )

        AppLogger.media.debug("uploadVideo succeeded path=\(ticket.storagePath)")
        return ActivityMedia(
            id: ticket.mediaId,
            type: .video,
            storagePath: ticket.storagePath,
            uploadedBy: uploadedBy,
            sizeBytes: sizeBytes,
            width: videoWidth,
            height: videoHeight,
            durationSeconds: duration
        )
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

    /// Deletes a single media item by removing its Firestore doc. The
    /// `onMediaDeleted` Cloud Function reacts to that deletion and removes
    /// the corresponding Storage binary server-side, so the client never
    /// touches Storage on delete. Deleting an already-missing doc is a
    /// no-op, so retries are safe.
    func deleteMedia(
        _ media: ActivityMedia,
        progressItemId: String,
        activityId: String
    ) async throws {
        AppLogger.media.debug("deleteMedia id=\(media.id) path=\(media.storagePath)")

        try await BackendClient.shared.request(
            "DELETE",
            "/progress/\(progressItemId)/activities/\(activityId)/media/\(media.id)"
        )

        AppLogger.media.debug("deleteMedia succeeded id=\(media.id)")
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
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "Could not encode the selected image."
        case .uploadFailed: return "The upload failed. Please try again."
        }
    }
}

let mediaService = MediaService()
