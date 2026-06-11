import Foundation
import FirebaseFirestore

/// A piece of media (photo or video) attached to an activity.
///
/// **Storage shape** — each media item is its own doc in a subcollection
/// under the parent activity, with the binary stored in Firebase Storage:
///
///     progressItems/{progressItemId}/activities/{activityId}/media/{mediaId}
///       type, storagePath, uploadedBy, uploadedAt,
///       sizeBytes, width?, height?, durationSeconds?
///
///     gs://{bucket}/activities/{progressItemId}/{activityId}/{mediaId}.{ext}
///
/// Using a subcollection (instead of an array on the activity doc) means
/// uploads from multiple devices never conflict and the parent activity
/// doc stays small enough for cheap listener traffic.
enum ActivityMediaType: String, Codable, Sendable {
    case image
    case video
}

struct ActivityMedia: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let type: ActivityMediaType
    /// Full Storage path including extension, e.g.
    /// `activities/{progressItemId}/{activityId}/{mediaId}.jpg`.
    /// Use `Storage.storage().reference(withPath:)` to get a download URL.
    let storagePath: String
    /// User ID of whoever uploaded it.
    let uploadedBy: String
    let uploadedAt: Date
    let sizeBytes: Int64?
    /// Original pixel dimensions — useful for laying out thumbnails without
    /// downloading the full asset first.
    let width: Int?
    let height: Int?
    /// Only set for videos.
    let durationSeconds: Double?

    nonisolated init(
        id: String = UUID().uuidString,
        type: ActivityMediaType,
        storagePath: String,
        uploadedBy: String,
        uploadedAt: Date = Date(),
        sizeBytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.storagePath = storagePath
        self.uploadedBy = uploadedBy
        self.uploadedAt = uploadedAt
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let typeString = data["type"] as? String,
              let type = ActivityMediaType(rawValue: typeString),
              let storagePath = data["storagePath"] as? String,
              let uploadedBy = data["uploadedBy"] as? String,
              let uploadedAt = (data["uploadedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        self.init(
            id: document.documentID,
            type: type,
            storagePath: storagePath,
            uploadedBy: uploadedBy,
            uploadedAt: uploadedAt,
            sizeBytes: (data["sizeBytes"] as? Int64) ?? (data["sizeBytes"] as? Int).map(Int64.init),
            width: data["width"] as? Int,
            height: data["height"] as? Int,
            durationSeconds: data["durationSeconds"] as? Double
        )
    }

    nonisolated func asFirestoreMap() -> [String: Any] {
        var map: [String: Any] = [
            "type": type.rawValue,
            "storagePath": storagePath,
            "uploadedBy": uploadedBy,
            "uploadedAt": Timestamp(date: uploadedAt),
        ]
        if let sizeBytes { map["sizeBytes"] = sizeBytes }
        if let width { map["width"] = width }
        if let height { map["height"] = height }
        if let durationSeconds { map["durationSeconds"] = durationSeconds }
        return map
    }
}
