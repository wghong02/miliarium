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

    /// Time dimension — start datetime. Used by the Calendar view.
    var timestamp: Date?

    /// Optional end datetime. Only meaningful when `timestamp` is also set;
    /// an end without a start is not allowed by the editor UI but the
    /// model tolerates it (treated as no range).
    var endTimestamp: Date?

    /// Whole-day activity. When `true`, the hour/minute components of
    /// `timestamp` (and `endTimestamp`, if set) are insignificant and the
    /// UI suppresses time pickers. The actual stored values are normalized
    /// to start-of-day in the editor.
    var isAllDay: Bool

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
        endTimestamp: Date? = nil,
        isAllDay: Bool = false,
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
        self.endTimestamp = endTimestamp
        self.isAllDay = isAllDay
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
            endTimestamp: (data["endTimestamp"] as? Timestamp)?.dateValue(),
            isAllDay: data["isAllDay"] as? Bool ?? false,
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
        if let endTimestamp {
            map["endTimestamp"] = Timestamp(date: endTimestamp)
        }
        if isAllDay {
            map["isAllDay"] = true
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

    /// True only when both a start and a (strictly later) end are set.
    nonisolated var hasEndTime: Bool {
        guard let start = timestamp, let end = endTimestamp else { return false }
        return end > start
    }

    nonisolated var hasLocation: Bool { latitude != nil && longitude != nil }

    nonisolated var hasCompletion: Bool { isCompleted != nil }

    /// Pretty short string for the activity's time slot:
    /// - All-day single day: `"All day"`
    /// - All-day multi-day:  `"May 31 – Jun 2"`
    /// - Timed, no end:       `"9:00 AM"`
    /// - Timed, end same day: `"9:00 AM – 10:30 AM"`
    /// - Timed, cross-day:    `"May 31, 9:00 AM – Jun 1, 2:00 PM"`
    /// Returns `nil` when `timestamp` is `nil`.
    nonisolated var timeRangeDescription: String? {
        guard let start = timestamp else { return nil }
        let cal = Foundation.Calendar.current

        if isAllDay {
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "MMM d"
            if let end = endTimestamp, !cal.isDate(start, inSameDayAs: end) {
                return "\(dateFmt.string(from: start)) – \(dateFmt.string(from: end))"
            }
            return "All day"
        }

        let timeFmt = DateFormatter()
        timeFmt.dateStyle = .none
        timeFmt.timeStyle = .short

        guard hasEndTime, let end = endTimestamp else {
            return timeFmt.string(from: start)
        }

        if cal.isDate(start, inSameDayAs: end) {
            return "\(timeFmt.string(from: start)) – \(timeFmt.string(from: end))"
        }
        let dateTimeFmt = DateFormatter()
        dateTimeFmt.dateFormat = "MMM d, h:mm a"
        return "\(dateTimeFmt.string(from: start)) – \(dateTimeFmt.string(from: end))"
    }

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
/// can belong to multiple collections (many-to-many), or to none — in which
/// case they only appear in the virtual "All activities" view on the Home
/// tab. There is no special "default" collection in the data model.
struct ActivityCollection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    var notes: String?

    /// User-facing pinning flag used for sorting / surfacing in the UI.
    var isFavorite: Bool

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

        // Legacy "isDefault" field in older Firestore docs is ignored — the
        // default-collection concept was removed; those rows are now regular
        // collections.
        self.init(
            id: document.documentID,
            name: name,
            notes: data["notes"] as? String,
            isFavorite: data["isFavorite"] as? Bool ?? false,
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
