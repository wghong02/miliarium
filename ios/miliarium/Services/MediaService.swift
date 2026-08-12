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

    /// Per-file upload cap. Enforced here for fast feedback and, authoritatively,
    /// by the backend on commit (which reads the stored object's real size).
    static let maxUploadBytes: Int64 = 20 * 1024 * 1024 // 20 MB

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
        let thumbnailStoragePath: String
        let thumbnailUploadURL: String
    }

    /// Asks the backend for signed PUT URLs (full-size + JPEG thumbnail).
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

    /// Downscales an image so its longest edge is at most `maxDimension` pixels.
    /// Returns the original when it's already small enough.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxDimension else { return image }
        let factor = maxDimension / longest
        let newSize = CGSize(
            width: (image.size.width * image.scale * factor).rounded(),
            height: (image.size.height * image.scale * factor).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    /// A small JPEG thumbnail image (≤400px) for the grid.
    private static func thumbnailImage(from image: UIImage) -> UIImage {
        downscaled(image, maxDimension: 400)
    }

    private static func videoThumbnail(_ asset: AVURLAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    private var uploadsTempDir: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Upload (background session)

    /// Prepares a picked photo or video and hands the byte transfer to the
    /// background upload session (so it survives app suspension). A JPEG
    /// thumbnail is uploaded alongside. The item appears in the grid once its
    /// bytes upload and the doc commits; in the meantime it's tracked live in
    /// `uploadCenter`. Pass exactly one of `image` / `videoFileURL`.
    func enqueueUpload(
        image: UIImage? = nil,
        videoFileURL: URL? = nil,
        progressItemId: String,
        activityId: String,
        uploadedBy: String
    ) async throws {
        let workId = UUID().uuidString
        let tempDir = uploadsTempDir

        let mainContentType: String
        let ext: String
        let type: String
        var width: Int?
        var height: Int?
        var durationSeconds: Double?
        let mainFile: URL
        var preview: UIImage?

        if let image {
            let scaled = Self.downscaled(image, maxDimension: 2048)
            guard let data = scaled.jpegData(compressionQuality: 0.85) else {
                throw MediaServiceError.imageEncodingFailed
            }
            guard Int64(data.count) <= Self.maxUploadBytes else { throw MediaServiceError.tooLarge }
            mainContentType = "image/jpeg"; ext = "jpg"; type = "image"
            width = Int(scaled.size.width * scaled.scale)
            height = Int(scaled.size.height * scaled.scale)
            mainFile = tempDir.appendingPathComponent("\(workId).jpg")
            try data.write(to: mainFile)
            preview = Self.thumbnailImage(from: scaled)
        } else if let videoFileURL {
            ext = videoFileURL.pathExtension.isEmpty ? "mov" : videoFileURL.pathExtension.lowercased()
            let attrs = try? FileManager.default.attributesOfItem(atPath: videoFileURL.path)
            if let size = (attrs?[.size] as? NSNumber)?.int64Value, size > Self.maxUploadBytes {
                throw MediaServiceError.tooLarge
            }
            let asset = AVURLAsset(url: videoFileURL)
            durationSeconds = try? await asset.load(.duration).seconds
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                width = Int(abs(size.width)); height = Int(abs(size.height))
            }
            mainContentType = contentType(forVideoExtension: ext); type = "video"
            mainFile = tempDir.appendingPathComponent("\(workId).\(ext)")
            try? FileManager.default.removeItem(at: mainFile)
            try FileManager.default.copyItem(at: videoFileURL, to: mainFile)
            preview = Self.videoThumbnail(asset)
        } else {
            throw MediaServiceError.uploadFailed
        }

        let ticket = try await requestUploadTicket(
            progressItemId: progressItemId, activityId: activityId,
            contentType: mainContentType, ext: ext
        )

        var thumbFile: URL?
        if let preview, let thumbData = preview.jpegData(compressionQuality: 0.7) {
            let url = tempDir.appendingPathComponent("\(workId)_thumb.jpg")
            try? thumbData.write(to: url)
            thumbFile = url
        }

        let info = UploadTaskInfo(
            kind: .main, mediaId: ticket.mediaId,
            progressItemId: progressItemId, activityId: activityId,
            storagePath: ticket.storagePath, thumbnailStoragePath: ticket.thumbnailStoragePath,
            type: type, width: width, height: height, durationSeconds: durationSeconds,
            tempFilePath: mainFile.path
        )
        await MediaCommitStore.shared.register(info)
        let previewForCenter = preview
        await MainActor.run {
            uploadCenter.add(mediaId: ticket.mediaId, activityId: activityId, preview: previewForCenter)
        }
        BackgroundUploadManager.shared.enqueue(
            mainURLString: ticket.uploadURL, mainFile: mainFile, mainContentType: mainContentType,
            thumbnailURLString: ticket.thumbnailUploadURL, thumbnailFile: thumbFile, info: info
        )
        AppLogger.media.debug("enqueued upload media=\(ticket.mediaId) type=\(type)")
    }

    // MARK: - Read

    /// Fetches all media for an activity, newest first (via the backend).
    func fetchMedia(
        progressItemId: String,
        activityId: String
    ) async throws -> [ActivityMedia] {
        struct Response: Decodable { let media: [ActivityMedia] }
        let response: Response = try await BackendClient.shared.send(
            "GET", "/progress/\(progressItemId)/activities/\(activityId)/media"
        )
        return response.media
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
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed: return "Could not encode the selected image."
        case .uploadFailed: return "The upload failed. Please try again."
        case .tooLarge: return "Each file must be 20 MB or smaller. Please choose a smaller one."
        }
    }
}

let mediaService = MediaService()
