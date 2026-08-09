import Foundation
import OSLog
import FirebaseFirestore

/// CRUD + listener service for `Activity` documents at
/// `progressItems/{progressId}/activities/{activityId}`.
///
/// Also owns the many-to-many wiring with `ActivityCollection`: whenever an
/// activity's `collectionIds` change, the corresponding collections'
/// `activityIds` are kept in sync in the same Firestore batch.
class ActivityService {
    private let db = Firestore.firestore()

    // MARK: - Collection helpers

    private func activitiesRef(for progressItemId: String) -> CollectionReference {
        db.collection("progressItems")
            .document(progressItemId)
            .collection("activities")
    }

    // MARK: - Create

    /// Creates an activity and, in the same atomic batch, appends its ID to
    /// `activityIds` on every collection it belongs to. If `collectionIds` is
    /// empty, the caller is expected to have supplied at least the default
    /// collection; this service does not look up the default itself.
    func createActivity(
        progressItemId: String,
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
        createdBy: String? = nil
    ) async throws -> Activity {
        let activity = Activity(
            title: title,
            notes: notes,
            timestamp: timestamp,
            endTimestamp: endTimestamp,
            isAllDay: isAllDay,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName,
            isCompleted: isCompleted,
            collectionIds: collectionIds,
            createdBy: createdBy
        )

        AppLogger.activity.debug("createActivity progressId=\(progressItemId) title=\(title) collections=\(collectionIds)")
        do {
            // The backend persists the activity (forcing `createdBy` to the
            // caller) and links it into each collection's `activityIds`.
            try await BackendClient.shared.request(
                "POST", "/progress/\(progressItemId)/activities", body: activity
            )
            AppLogger.activity.debug("createActivity succeeded id=\(activity.id)")
        } catch {
            AppLogger.activity.error("createActivity failed progressId=\(progressItemId): \(error)")
            throw error
        }
        return activity
    }

    // MARK: - Read

    func fetchActivities(for progressItemId: String) async throws -> [Activity] {
        AppLogger.activity.debug("fetchActivities progressId=\(progressItemId)")
        do {
            let snapshot = try await activitiesRef(for: progressItemId)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            return snapshot.documents.compactMap { Activity(document: $0) }
        } catch {
            AppLogger.activity.error("fetchActivities failed progressId=\(progressItemId): \(error)")
            throw error
        }
    }

    func fetchActivity(id: String, for progressItemId: String) async throws -> Activity? {
        AppLogger.activity.debug("fetchActivity id=\(id) progressId=\(progressItemId)")
        do {
            let doc = try await activitiesRef(for: progressItemId)
                .document(id)
                .getDocument()
            return Activity(document: doc)
        } catch {
            AppLogger.activity.error("fetchActivity failed id=\(id): \(error)")
            throw error
        }
    }

    /// Activities with a non-nil `timestamp` — for the Calendar view.
    func fetchActivitiesWithTime(for progressItemId: String) async throws -> [Activity] {
        AppLogger.activity.debug("fetchActivitiesWithTime progressId=\(progressItemId)")
        do {
            let snapshot = try await activitiesRef(for: progressItemId)
                .whereField("timestamp", isGreaterThan: Timestamp(date: .distantPast))
                .order(by: "timestamp", descending: false)
                .getDocuments()
            return snapshot.documents.compactMap { Activity(document: $0) }
        } catch {
            AppLogger.activity.error("fetchActivitiesWithTime failed progressId=\(progressItemId): \(error)")
            throw error
        }
    }

    /// Activities with a location — for the Map view. Firestore can't filter
    /// on `GeoPoint` presence directly, so we fetch all and filter in memory.
    func fetchActivitiesWithLocation(for progressItemId: String) async throws -> [Activity] {
        AppLogger.activity.debug("fetchActivitiesWithLocation progressId=\(progressItemId)")
        do {
            let all = try await fetchActivities(for: progressItemId)
            return all.filter { $0.hasLocation }
        } catch {
            AppLogger.activity.error("fetchActivitiesWithLocation failed progressId=\(progressItemId): \(error)")
            throw error
        }
    }

    // MARK: - Update

    /// Updates an existing activity. When `collectionIds` is provided, the
    /// many-to-many back-references are reconciled in the same batch.
    func updateActivity(
        _ activity: Activity,
        progressItemId: String,
        title: String? = nil,
        notes: String?? = nil,
        timestamp: Date?? = nil,
        endTimestamp: Date?? = nil,
        isAllDay: Bool? = nil,
        latitude: Double?? = nil,
        longitude: Double?? = nil,
        locationName: String?? = nil,
        isCompleted: Bool?? = nil,
        collectionIds: [String]? = nil
    ) async throws {
        var updated = activity
        updated.updatedAt = Date()

        if let title { updated.title = title }
        if let notes { updated.notes = notes }
        if let timestamp { updated.timestamp = timestamp }
        if let endTimestamp { updated.endTimestamp = endTimestamp }
        if let isAllDay { updated.isAllDay = isAllDay }
        if let latitude { updated.latitude = latitude }
        if let longitude { updated.longitude = longitude }
        if let locationName { updated.locationName = locationName }
        if let isCompleted { updated.isCompleted = isCompleted }

        // Apply a new collection membership set if the caller passed one; the
        // backend reconciles the collection back-references against the stored
        // old set.
        if let collectionIds {
            updated.collectionIds = Array(Set(collectionIds))
        }

        AppLogger.activity.debug("updateActivity id=\(activity.id) progressId=\(progressItemId)")
        do {
            // Send the fully-resolved activity; the backend replaces the doc and
            // reconciles collection back-references against the stored old set.
            try await BackendClient.shared.request(
                "PATCH", "/progress/\(progressItemId)/activities/\(activity.id)", body: updated
            )
            AppLogger.activity.debug("updateActivity succeeded id=\(activity.id)")
        } catch {
            AppLogger.activity.error("updateActivity failed id=\(activity.id): \(error)")
            throw error
        }
    }

    // MARK: - Delete

    /// Deletes an activity. The client only removes the activity doc; the
    /// backend `onActivityUnlinkCollections` trigger pulls the activity's ID
    /// out of every collection's `activityIds`, and `onActivityDeleted`
    /// cleans up its media docs + Storage files. See backend/cascadeDeletes.ts.
    func deleteActivity(_ activity: Activity, progressItemId: String) async throws {
        AppLogger.activity.debug("deleteActivity id=\(activity.id) progressId=\(progressItemId)")
        do {
            try await BackendClient.shared.request(
                "DELETE", "/progress/\(progressItemId)/activities/\(activity.id)"
            )
            AppLogger.activity.debug("deleteActivity succeeded id=\(activity.id)")
        } catch {
            AppLogger.activity.error("deleteActivity failed id=\(activity.id): \(error)")
            throw error
        }
    }

    // MARK: - Membership convenience

    func addActivity(
        _ activityId: String,
        toCollection collectionId: String,
        progressItemId: String
    ) async throws {
        AppLogger.activity.debug("addActivity activityId=\(activityId) toCollection=\(collectionId) progressId=\(progressItemId)")
        do {
            try await BackendClient.shared.request(
                "POST",
                "/progress/\(progressItemId)/activities/\(activityId)/collections/\(collectionId)"
            )
            AppLogger.activity.debug("addActivity succeeded activityId=\(activityId) collectionId=\(collectionId)")
        } catch {
            AppLogger.activity.error("addActivity failed activityId=\(activityId) collectionId=\(collectionId): \(error)")
            throw error
        }
    }

    func removeActivity(
        _ activityId: String,
        fromCollection collectionId: String,
        progressItemId: String
    ) async throws {
        AppLogger.activity.debug("removeActivity activityId=\(activityId) fromCollection=\(collectionId) progressId=\(progressItemId)")
        do {
            try await BackendClient.shared.request(
                "DELETE",
                "/progress/\(progressItemId)/activities/\(activityId)/collections/\(collectionId)"
            )
            AppLogger.activity.debug("removeActivity succeeded activityId=\(activityId) collectionId=\(collectionId)")
        } catch {
            AppLogger.activity.error("removeActivity failed activityId=\(activityId) collectionId=\(collectionId): \(error)")
            throw error
        }
    }

    // MARK: - Listener

    func setActivitiesListener(
        for progressItemId: String,
        onChange: @escaping ([Activity]) -> Void
    ) -> ListenerRegistration {
        let query = activitiesRef(for: progressItemId)
            .order(by: "createdAt", descending: true)

        AppLogger.activity.debug("setActivitiesListener progressId=\(progressItemId)")
        return query.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.activity.error("activitiesListener error progressId=\(progressItemId): \(error)")
                return
            }
            guard let snapshot else {
                AppLogger.activity.error("activitiesListener received nil snapshot progressId=\(progressItemId)")
                return
            }
            let activities = snapshot.documents.compactMap { Activity(document: $0) }
            AppLogger.activity.debug("activitiesListener update progressId=\(progressItemId) count=\(activities.count)")
            onChange(activities)
        }
    }

}

let activityService = ActivityService()
