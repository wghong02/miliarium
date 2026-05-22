import Foundation
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

    private func collectionsRef(for progressItemId: String) -> CollectionReference {
        db.collection("progressItems")
            .document(progressItemId)
            .collection("collections")
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
        latitude: Double? = nil,
        longitude: Double? = nil,
        locationName: String? = nil,
        isCompleted: Bool? = nil,
        collectionIds: [String] = []
    ) async throws -> Activity {
        let activity = Activity(
            title: title,
            notes: notes,
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            locationName: locationName,
            isCompleted: isCompleted,
            collectionIds: collectionIds
        )

        let activityRef = activitiesRef(for: progressItemId).document(activity.id)

        let batch = db.batch()
        batch.setData(activity.asFirestoreMap(), forDocument: activityRef)

        for collectionId in collectionIds {
            let collectionRef = collectionsRef(for: progressItemId).document(collectionId)
            batch.updateData(
                [
                    "activityIds": FieldValue.arrayUnion([activity.id]),
                    "updatedAt": Timestamp(date: Date())
                ],
                forDocument: collectionRef
            )
        }

        try await Self.commitBatch(batch)
        return activity
    }

    // MARK: - Read

    func fetchActivities(for progressItemId: String) async throws -> [Activity] {
        let snapshot = try await activitiesRef(for: progressItemId)
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { Activity(document: $0) }
    }

    func fetchActivity(id: String, for progressItemId: String) async throws -> Activity? {
        let doc = try await activitiesRef(for: progressItemId)
            .document(id)
            .getDocument()

        return Activity(document: doc)
    }

    /// Activities with a non-nil `timestamp` — for the Calendar view.
    func fetchActivitiesWithTime(for progressItemId: String) async throws -> [Activity] {
        let snapshot = try await activitiesRef(for: progressItemId)
            .whereField("timestamp", isGreaterThan: Timestamp(date: .distantPast))
            .order(by: "timestamp", descending: false)
            .getDocuments()

        return snapshot.documents.compactMap { Activity(document: $0) }
    }

    /// Activities with a location — for the Map view. Firestore can't filter
    /// on `GeoPoint` presence directly, so we fetch all and filter in memory.
    func fetchActivitiesWithLocation(for progressItemId: String) async throws -> [Activity] {
        let all = try await fetchActivities(for: progressItemId)
        return all.filter { $0.hasLocation }
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
        if let latitude { updated.latitude = latitude }
        if let longitude { updated.longitude = longitude }
        if let locationName { updated.locationName = locationName }
        if let isCompleted { updated.isCompleted = isCompleted }

        // Reconcile collection membership if the caller passed a new list.
        let oldCollectionIds = Set(activity.collectionIds)
        let newCollectionIds = collectionIds.map { Set($0) }
        if let newCollectionIds {
            updated.collectionIds = Array(newCollectionIds)
        }

        let activityRef = activitiesRef(for: progressItemId).document(activity.id)
        let batch = db.batch()
        batch.setData(updated.asFirestoreMap(), forDocument: activityRef)

        if let newCollectionIds {
            let now = Timestamp(date: Date())
            let added = newCollectionIds.subtracting(oldCollectionIds)
            let removed = oldCollectionIds.subtracting(newCollectionIds)

            for collectionId in added {
                let ref = collectionsRef(for: progressItemId).document(collectionId)
                batch.updateData(
                    [
                        "activityIds": FieldValue.arrayUnion([activity.id]),
                        "updatedAt": now
                    ],
                    forDocument: ref
                )
            }
            for collectionId in removed {
                let ref = collectionsRef(for: progressItemId).document(collectionId)
                batch.updateData(
                    [
                        "activityIds": FieldValue.arrayRemove([activity.id]),
                        "updatedAt": now
                    ],
                    forDocument: ref
                )
            }
        }

        try await Self.commitBatch(batch)
    }

    // MARK: - Delete

    /// Deletes an activity and removes its ID from every collection it
    /// belonged to.
    func deleteActivity(_ activity: Activity, progressItemId: String) async throws {
        let activityRef = activitiesRef(for: progressItemId).document(activity.id)

        let batch = db.batch()
        batch.deleteDocument(activityRef)

        let now = Timestamp(date: Date())
        for collectionId in activity.collectionIds {
            let ref = collectionsRef(for: progressItemId).document(collectionId)
            batch.updateData(
                [
                    "activityIds": FieldValue.arrayRemove([activity.id]),
                    "updatedAt": now
                ],
                forDocument: ref
            )
        }

        try await Self.commitBatch(batch)
    }

    // MARK: - Membership convenience

    func addActivity(
        _ activityId: String,
        toCollection collectionId: String,
        progressItemId: String
    ) async throws {
        let now = Timestamp(date: Date())
        let batch = db.batch()
        batch.updateData(
            [
                "collectionIds": FieldValue.arrayUnion([collectionId]),
                "updatedAt": now
            ],
            forDocument: activitiesRef(for: progressItemId).document(activityId)
        )
        batch.updateData(
            [
                "activityIds": FieldValue.arrayUnion([activityId]),
                "updatedAt": now
            ],
            forDocument: collectionsRef(for: progressItemId).document(collectionId)
        )
        try await Self.commitBatch(batch)
    }

    func removeActivity(
        _ activityId: String,
        fromCollection collectionId: String,
        progressItemId: String
    ) async throws {
        let now = Timestamp(date: Date())
        let batch = db.batch()
        batch.updateData(
            [
                "collectionIds": FieldValue.arrayRemove([collectionId]),
                "updatedAt": now
            ],
            forDocument: activitiesRef(for: progressItemId).document(activityId)
        )
        batch.updateData(
            [
                "activityIds": FieldValue.arrayRemove([activityId]),
                "updatedAt": now
            ],
            forDocument: collectionsRef(for: progressItemId).document(collectionId)
        )
        try await Self.commitBatch(batch)
    }

    // MARK: - Listener

    func setActivitiesListener(
        for progressItemId: String,
        onChange: @escaping ([Activity]) -> Void
    ) -> ListenerRegistration {
        let query = activitiesRef(for: progressItemId)
            .order(by: "createdAt", descending: true)

        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[ActivityService] Listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else {
                print("[ActivityService] Snapshot is nil")
                return
            }
            let activities = snapshot.documents.compactMap { Activity(document: $0) }
            onChange(activities)
        }
    }

    // MARK: - Batch helper

    nonisolated private static func commitBatch(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

let activityService = ActivityService()
