import Foundation
import OSLog
import FirebaseFirestore

/// CRUD + listener service for `ActivityCollection` documents at
/// `progressItems/{progressId}/collections/{collectionId}`.
///
/// Stats are stored on the collection and refreshed lazily via
/// `refreshStats(...)` — they are *not* recomputed on every activity write.
class ActivityCollectionService {
    private let db = Firestore.firestore()

    // MARK: - Ref helpers

    private func collectionsRef(for progressItemId: String) -> CollectionReference {
        db.collection("progressItems")
            .document(progressItemId)
            .collection("collections")
    }

    private func activitiesRef(for progressItemId: String) -> CollectionReference {
        db.collection("progressItems")
            .document(progressItemId)
            .collection("activities")
    }

    // MARK: - Create

    func createCollection(
        progressItemId: String,
        name: String,
        notes: String? = nil,
        isFavorite: Bool = false
    ) async throws -> ActivityCollection {
        let collection = ActivityCollection(
            name: name,
            notes: notes,
            isFavorite: isFavorite
        )

        AppLogger.activityCollection.debug("createCollection progressId=\(progressItemId) name=\(name)")
        do {
            try await BackendClient.shared.request(
                "POST", "/progress/\(progressItemId)/collections", body: collection
            )
            AppLogger.activityCollection.debug("createCollection succeeded id=\(collection.id)")
        } catch {
            AppLogger.activityCollection.error("createCollection failed: \(error)")
            throw error
        }
        return collection
    }

    // MARK: - Read

    func fetchCollections(for progressItemId: String) async throws -> [ActivityCollection] {
        AppLogger.activityCollection.debug("fetchCollections progressId=\(progressItemId)")
        do {
            let snapshot = try await collectionsRef(for: progressItemId)
                .order(by: "createdAt", descending: false)
                .getDocuments()
            return snapshot.documents.compactMap { ActivityCollection(document: $0) }
        } catch {
            AppLogger.activityCollection.error("fetchCollections failed progressId=\(progressItemId): \(error)")
            throw error
        }
    }

    func fetchCollection(id: String, for progressItemId: String) async throws -> ActivityCollection? {
        AppLogger.activityCollection.debug("fetchCollection id=\(id) progressId=\(progressItemId)")
        do {
            let doc = try await collectionsRef(for: progressItemId)
                .document(id)
                .getDocument()
            return ActivityCollection(document: doc)
        } catch {
            AppLogger.activityCollection.error("fetchCollection failed id=\(id): \(error)")
            throw error
        }
    }

    // MARK: - Update

    func updateCollection(
        _ collection: ActivityCollection,
        progressItemId: String,
        name: String? = nil,
        notes: String?? = nil,
        isFavorite: Bool? = nil
    ) async throws {
        AppLogger.activityCollection.debug("updateCollection id=\(collection.id) progressId=\(progressItemId)")
        // Patch body: only the provided fields are sent. `notes` distinguishes
        // "not provided" (key omitted) from "clear" (explicit null) so the
        // backend merges accordingly without touching activityIds/stats.
        let body = CollectionPatch(
            name: name,
            isFavorite: isFavorite,
            notesProvided: notes != nil,
            notesValue: notes.flatMap { $0 }
        )
        do {
            try await BackendClient.shared.request(
                "PATCH", "/progress/\(progressItemId)/collections/\(collection.id)", body: body
            )
            AppLogger.activityCollection.debug("updateCollection succeeded id=\(collection.id)")
        } catch {
            AppLogger.activityCollection.error("updateCollection failed id=\(collection.id): \(error)")
            throw error
        }
    }

    /// Encodable patch that omits absent fields and can send an explicit null
    /// for `notes` (clear) vs. omitting it (leave unchanged).
    private struct CollectionPatch: Encodable {
        let name: String?
        let isFavorite: Bool?
        let notesProvided: Bool
        let notesValue: String?

        enum CodingKeys: String, CodingKey { case name, isFavorite, notes }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let name { try c.encode(name, forKey: .name) }
            if let isFavorite { try c.encode(isFavorite, forKey: .isFavorite) }
            if notesProvided {
                if let notesValue {
                    try c.encode(notesValue, forKey: .notes)
                } else {
                    try c.encodeNil(forKey: .notes)
                }
            }
        }
    }

    /// Recomputes `stats` from the activities currently referenced by
    /// `activityIds` and writes the result back. Fetches all activities for
    /// the progress in one call to avoid Firestore's 30-item `in` query limit.
    @discardableResult
    func refreshStats(
        for collection: ActivityCollection,
        progressItemId: String
    ) async throws -> ActivityCollection {
        AppLogger.activityCollection.debug("refreshStats collectionId=\(collection.id) progressId=\(progressItemId)")
        do {
            // Compute stats client-side (reads stay client-side in this phase),
            // then persist the result through the backend.
            let snapshot = try await activitiesRef(for: progressItemId).getDocuments()
            let allActivities = snapshot.documents.compactMap { Activity(document: $0) }

            let memberIds = Set(collection.activityIds)
            let members = allActivities.filter { memberIds.contains($0.id) }

            var updated = collection
            updated.stats = ActivityCollection.computeStats(from: members)
            updated.statsUpdatedAt = Date()
            updated.updatedAt = Date()

            let s = updated.stats
            try await BackendClient.shared.request(
                "POST", "/progress/\(progressItemId)/collections/\(collection.id)/stats",
                body: StatsBody(
                    total: s.total,
                    firstAt: s.firstAt,
                    lastAt: s.lastAt,
                    completedCount: s.completedCount,
                    locationCount: s.locationCount,
                    timeCount: s.timeCount
                )
            )
            AppLogger.activityCollection.debug("refreshStats succeeded collectionId=\(collection.id) memberCount=\(members.count)")
            return updated
        } catch {
            AppLogger.activityCollection.error("refreshStats failed collectionId=\(collection.id): \(error)")
            throw error
        }
    }

    private struct StatsBody: Encodable {
        let total: Int
        let firstAt: Date?
        let lastAt: Date?
        let completedCount: Int
        let locationCount: Int
        let timeCount: Int
    }

    // MARK: - Delete

    /// Deletes a collection. The client only removes the collection doc; the
    /// backend `onCollectionDeleted` trigger pulls the collection's ID out of
    /// every member activity's `collectionIds` (see backend/cascadeDeletes.ts).
    /// An orphaned activity with no collections still appears in the virtual
    /// "All activities" view.
    func deleteCollection(
        _ collection: ActivityCollection,
        progressItemId: String
    ) async throws {
        AppLogger.activityCollection.debug("deleteCollection id=\(collection.id) progressId=\(progressItemId)")
        do {
            try await BackendClient.shared.request(
                "DELETE", "/progress/\(progressItemId)/collections/\(collection.id)"
            )
            AppLogger.activityCollection.debug("deleteCollection succeeded id=\(collection.id)")
        } catch {
            AppLogger.activityCollection.error("deleteCollection failed id=\(collection.id): \(error)")
            throw error
        }
    }

    // MARK: - Listener

    /// Listens to a single collection document and calls `onChange` whenever
    /// it changes. The callback receives `nil` if the document is deleted.
    func setCollectionListener(
        id: String,
        progressItemId: String,
        onChange: @escaping (ActivityCollection?) -> Void
    ) -> ListenerRegistration {
        let ref = collectionsRef(for: progressItemId).document(id)
        AppLogger.activityCollection.debug("setCollectionListener id=\(id) progressId=\(progressItemId)")
        return ref.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.activityCollection.error("collectionListener error id=\(id): \(error)")
                return
            }
            let collection = snapshot.flatMap { ActivityCollection(document: $0) }
            AppLogger.activityCollection.debug("collectionListener update id=\(id) exists=\(collection != nil)")
            onChange(collection)
        }
    }

    func setCollectionsListener(
        for progressItemId: String,
        onChange: @escaping ([ActivityCollection]) -> Void
    ) -> ListenerRegistration {
        let query = collectionsRef(for: progressItemId)
            .order(by: "createdAt", descending: false)

        AppLogger.activityCollection.debug("setCollectionsListener progressId=\(progressItemId)")
        return query.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.activityCollection.error("collectionsListener error progressId=\(progressItemId): \(error)")
                return
            }
            guard let snapshot else {
                AppLogger.activityCollection.error("collectionsListener received nil snapshot progressId=\(progressItemId)")
                return
            }
            let collections = snapshot.documents.compactMap { ActivityCollection(document: $0) }
            AppLogger.activityCollection.debug("collectionsListener update progressId=\(progressItemId) count=\(collections.count)")
            onChange(collections)
        }
    }

}

let activityCollectionService = ActivityCollectionService()
