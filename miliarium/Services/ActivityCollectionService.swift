import Foundation
import FirebaseFirestore

/// CRUD + listener service for `ActivityCollection` documents at
/// `progressItems/{progressId}/collections/{collectionId}`.
///
/// Stats are stored on the collection and refreshed lazily via
/// `refreshStats(...)` — they are *not* recomputed on every activity write.
class ActivityCollectionService {
    private let db = Firestore.firestore()

    nonisolated static let defaultCollectionName = "default collection"

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
        isFavorite: Bool = false,
        isDefault: Bool = false
    ) async throws -> ActivityCollection {
        let collection = ActivityCollection(
            name: name,
            notes: notes,
            isFavorite: isFavorite,
            isDefault: isDefault
        )

        let ref = collectionsRef(for: progressItemId).document(collection.id)
        try await ref.setData(collection.asFirestoreMap())
        return collection
    }

    // MARK: - Read

    func fetchCollections(for progressItemId: String) async throws -> [ActivityCollection] {
        let snapshot = try await collectionsRef(for: progressItemId)
            .order(by: "createdAt", descending: false)
            .getDocuments()

        return snapshot.documents.compactMap { ActivityCollection(document: $0) }
    }

    func fetchCollection(id: String, for progressItemId: String) async throws -> ActivityCollection? {
        let doc = try await collectionsRef(for: progressItemId)
            .document(id)
            .getDocument()
        return ActivityCollection(document: doc)
    }

    /// Returns the (first) default collection for a progress, if one exists.
    func fetchDefaultCollection(for progressItemId: String) async throws -> ActivityCollection? {
        let snapshot = try await collectionsRef(for: progressItemId)
            .whereField("isDefault", isEqualTo: true)
            .limit(to: 1)
            .getDocuments()
        return snapshot.documents.first.flatMap { ActivityCollection(document: $0) }
    }

    // MARK: - Update

    func updateCollection(
        _ collection: ActivityCollection,
        progressItemId: String,
        name: String? = nil,
        notes: String?? = nil,
        isFavorite: Bool? = nil
    ) async throws {
        var updated = collection
        updated.updatedAt = Date()

        if let name { updated.name = name }
        if let notes { updated.notes = notes }
        if let isFavorite { updated.isFavorite = isFavorite }

        let ref = collectionsRef(for: progressItemId).document(collection.id)
        try await ref.setData(updated.asFirestoreMap())
    }

    /// Recomputes `stats` from the activities currently referenced by
    /// `activityIds` and writes the result back. Fetches all activities for
    /// the progress in one call to avoid Firestore's 30-item `in` query limit.
    @discardableResult
    func refreshStats(
        for collection: ActivityCollection,
        progressItemId: String
    ) async throws -> ActivityCollection {
        let snapshot = try await activitiesRef(for: progressItemId).getDocuments()
        let allActivities = snapshot.documents.compactMap { Activity(document: $0) }

        let memberIds = Set(collection.activityIds)
        let members = allActivities.filter { memberIds.contains($0.id) }

        var updated = collection
        updated.stats = ActivityCollection.computeStats(from: members)
        updated.statsUpdatedAt = Date()
        updated.updatedAt = Date()

        let ref = collectionsRef(for: progressItemId).document(collection.id)
        try await ref.setData(updated.asFirestoreMap())
        return updated
    }

    // MARK: - Delete

    /// Deletes a collection. The default collection cannot be deleted.
    /// Activities remain — their `collectionIds` are cleaned of the removed
    /// collection's ID in the same atomic batch.
    func deleteCollection(
        _ collection: ActivityCollection,
        progressItemId: String
    ) async throws {
        if collection.isDefault {
            throw ActivityCollectionError.cannotDeleteDefault
        }

        let batch = db.batch()
        let now = Timestamp(date: Date())

        // Remove this collection from every member activity's collectionIds.
        for activityId in collection.activityIds {
            let activityRef = activitiesRef(for: progressItemId).document(activityId)
            batch.updateData(
                [
                    "collectionIds": FieldValue.arrayRemove([collection.id]),
                    "updatedAt": now
                ],
                forDocument: activityRef
            )
        }

        let collectionRef = collectionsRef(for: progressItemId).document(collection.id)
        batch.deleteDocument(collectionRef)

        try await Self.commitBatch(batch)
    }

    // MARK: - Listener

    func setCollectionsListener(
        for progressItemId: String,
        onChange: @escaping ([ActivityCollection]) -> Void
    ) -> ListenerRegistration {
        let query = collectionsRef(for: progressItemId)
            .order(by: "createdAt", descending: false)

        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[ActivityCollectionService] Listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else {
                print("[ActivityCollectionService] Snapshot is nil")
                return
            }
            let collections = snapshot.documents.compactMap { ActivityCollection(document: $0) }
            onChange(collections)
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

enum ActivityCollectionError: LocalizedError {
    case cannotDeleteDefault

    var errorDescription: String? {
        switch self {
        case .cannotDeleteDefault:
            return "The default collection cannot be deleted."
        }
    }
}

let activityCollectionService = ActivityCollectionService()
