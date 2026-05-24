import Foundation
import FirebaseFirestore

// MARK: - Activity

/// An Activity is the atomic entry in the app. It has up to three optional
/// dimensions (text, time, location) plus an optional completion flag, and
/// belongs to zero or more ActivityCollections.
struct Activity: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var notes: String?

    // MARK: Optional dimensions

    /// Time dimension — used by the Calendar view.
    var timestamp: Date?

    /// Location dimension — used by the Map view.
    var latitude: Double?
    var longitude: Double?
    var locationName: String?

    /// Achievement-style completion. `nil` = not an achievement, `false` =
    /// pending, `true` = completed.
    var isCompleted: Bool?

    /// IDs of the ActivityCollections this activity belongs to (many-to-many).
    var collectionIds: [String]

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Initializers

    nonisolated init(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        timestamp: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        isCompleted: Bool? = nil,
        collectionIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
        self.isCompleted = isCompleted
        self.collectionIds = collectionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Parse from Firestore document.
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let title = data["title"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        let geoPoint = data["location"] as? GeoPoint

        self.init(
            id: document.documentID,
            title: title,
            notes: data["notes"] as? String,
            timestamp: (data["timestamp"] as? Timestamp)?.dateValue(),
            latitude: geoPoint?.latitude,
            longitude: geoPoint?.longitude,
            locationName: data["locationName"] as? String,
            isCompleted: data["isCompleted"] as? Bool,
            collectionIds: data["collectionIds"] as? [String] ?? [],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Convert to Firestore map for saving.
    nonisolated func asFirestoreMap() -> [String: Any] {
        var map: [String: Any] = [
            "title": title,
            "collectionIds": collectionIds,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let notes, !notes.isEmpty {
            map["notes"] = notes
        }
        if let timestamp {
            map["timestamp"] = Timestamp(date: timestamp)
        }
        if let latitude, let longitude {
            map["location"] = GeoPoint(latitude: latitude, longitude: longitude)
        }
        if let locationName, !locationName.isEmpty {
            map["locationName"] = locationName
        }
        if let isCompleted {
            map["isCompleted"] = isCompleted
        }

        return map
    }

    // MARK: - Convenience

    nonisolated var hasTime: Bool { timestamp != nil }

    nonisolated var hasLocation: Bool { latitude != nil && longitude != nil }

    nonisolated var hasCompletion: Bool { isCompleted != nil }

    /// Returns a `(latitude, longitude)` tuple when both coordinates are present.
    nonisolated var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }
}

// MARK: - ActivityCollection

/// Stored, denormalized stats for an ActivityCollection. Refreshed lazily via
/// an explicit "Update stats" action rather than recomputed on every write.
struct ActivityCollectionStats: Sendable, Codable, Hashable {
    var total: Int
    var firstAt: Date?
    var lastAt: Date?
    var completedCount: Int
    var locationCount: Int
    var timeCount: Int

    nonisolated static let empty = ActivityCollectionStats(
        total: 0,
        firstAt: nil,
        lastAt: nil,
        completedCount: 0,
        locationCount: 0,
        timeCount: 0
    )
}

/// An ActivityCollection groups Activities under a progress item. Activities
/// can belong to multiple collections (many-to-many). Every progress comes
/// with a "default collection" so new activities always have a home.
struct ActivityCollection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var notes: String?

    /// User-facing pinning flag used for sorting / surfacing in the UI.
    var isFavorite: Bool

    /// The auto-created starter collection for a progress. Used to find the
    /// fallback target when no collection is selected.
    var isDefault: Bool

    /// IDs of activities in this collection.
    var activityIds: [String]

    /// Stored, denormalized aggregate stats — refreshed lazily on demand.
    var stats: ActivityCollectionStats

    /// When the stats were last refreshed. `nil` means never computed.
    var statsUpdatedAt: Date?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Initializers

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        notes: String? = nil,
        isFavorite: Bool = false,
        isDefault: Bool = false,
        activityIds: [String] = [],
        stats: ActivityCollectionStats = .empty,
        statsUpdatedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.isFavorite = isFavorite
        self.isDefault = isDefault
        self.activityIds = activityIds
        self.stats = stats
        self.statsUpdatedAt = statsUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Parse from Firestore document.
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let name = data["name"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        let statsData = data["stats"] as? [String: Any] ?? [:]
        let stats = ActivityCollectionStats(
            total: statsData["total"] as? Int ?? 0,
            firstAt: (statsData["firstAt"] as? Timestamp)?.dateValue(),
            lastAt: (statsData["lastAt"] as? Timestamp)?.dateValue(),
            completedCount: statsData["completedCount"] as? Int ?? 0,
            locationCount: statsData["locationCount"] as? Int ?? 0,
            timeCount: statsData["timeCount"] as? Int ?? 0
        )

        self.init(
            id: document.documentID,
            name: name,
            notes: data["notes"] as? String,
            isFavorite: data["isFavorite"] as? Bool ?? false,
            isDefault: data["isDefault"] as? Bool ?? false,
            activityIds: data["activityIds"] as? [String] ?? [],
            stats: stats,
            statsUpdatedAt: (data["statsUpdatedAt"] as? Timestamp)?.dateValue(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Convert to Firestore map for saving.
    nonisolated func asFirestoreMap() -> [String: Any] {
        var statsMap: [String: Any] = [
            "total": stats.total,
            "completedCount": stats.completedCount,
            "locationCount": stats.locationCount,
            "timeCount": stats.timeCount
        ]
        if let firstAt = stats.firstAt {
            statsMap["firstAt"] = Timestamp(date: firstAt)
        }
        if let lastAt = stats.lastAt {
            statsMap["lastAt"] = Timestamp(date: lastAt)
        }

        var map: [String: Any] = [
            "name": name,
            "isFavorite": isFavorite,
            "isDefault": isDefault,
            "activityIds": activityIds,
            "stats": statsMap,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let notes, !notes.isEmpty {
            map["notes"] = notes
        }
        if let statsUpdatedAt {
            map["statsUpdatedAt"] = Timestamp(date: statsUpdatedAt)
        }

        return map
    }

    // MARK: - Convenience

    /// Compute fresh stats from a list of activities (those belonging to this
    /// collection). Does not mutate `self` — the caller assigns the result.
    nonisolated static func computeStats(from activities: [Activity]) -> ActivityCollectionStats {
        let timed = activities.compactMap { $0.timestamp }.sorted()
        return ActivityCollectionStats(
            total: activities.count,
            firstAt: timed.first,
            lastAt: timed.last,
            completedCount: activities.filter { $0.isCompleted == true }.count,
            locationCount: activities.filter { $0.hasLocation }.count,
            timeCount: activities.filter { $0.hasTime }.count
        )
    }
}
