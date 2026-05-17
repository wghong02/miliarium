import Foundation
import Observation
import FirebaseFirestore

private enum CreateProgressFailure: Error {
    case timedOut
}

/// Progress data lives in `progressItems/{progressItemId}`.
/// Per-user membership is tracked in `users/{userId}/progressLinks/{progressItemId}` (document id matches the item id).
/// Each progress has an associated calendar at `calendars/{calendarId}` with nested events.
@Observable
@MainActor
final class ProgressStore {
    private(set) var progresses: [ProgressItem] = []
    private(set) var selectedProgressId: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    private var listener: ListenerRegistration?
    private var userId: String?

    /// Set after a successful server write; cleared once the snapshot listener shows that progress locally.
    private var pendingSelectProgressId: String?

    func updateUserId(_ id: String?) {
        listener?.remove()
        listener = nil
        userId = id
        progresses = []
        selectedProgressId = nil
        pendingSelectProgressId = nil
        errorMessage = nil

        guard let id else {
            isLoading = false
            return
        }

        isLoading = true
        let query = Firestore.firestore()
            .collection("users")
            .document(id)
            .collection("progressLinks")
            .order(by: "linkedAt", descending: true)

        listener = query.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let snapshot else {
                    self.isLoading = false
                    return
                }
                self.errorMessage = nil
                let orderedIds = snapshot.documents.map(\.documentID)
                let items = await self.fetchProgressItems(ids: orderedIds)
                self.isLoading = false
                // Server snapshot is source of truth — only update in-memory list after Firestore delivers data.
                self.progresses = items

                if let pending = self.pendingSelectProgressId,
                   items.contains(where: { $0.id == pending }) {
                    self.selectedProgressId = pending
                    self.pendingSelectProgressId = nil
                } else if self.pendingSelectProgressId != nil {
                    // Write succeeded but rows not visible yet (or still fetching); do not fake local selection.
                } else {
                    if self.selectedProgressId == nil, let first = items.first {
                        self.selectedProgressId = first.id
                    } else if let sid = self.selectedProgressId,
                              !items.contains(where: { $0.id == sid }) {
                        self.selectedProgressId = items.first?.id
                    }
                }
            }
        }
    }

    func selectProgress(id: String?) {
        selectedProgressId = id
    }

    /// Creates one progress document + link + calendar. Waits at most **3 seconds**; does not retry.
    @discardableResult
    func createProgress(title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let userId else { return false }
        errorMessage = nil
        let db = Firestore.firestore()
        let progressRef = db.collection("progressItems").document()
        let linkRef = db.collection("users").document(userId).collection("progressLinks").document(progressRef.documentID)
        
        // Create calendar for this progress (using Calendar model)
        let calendar = Calendar(progressItemId: progressRef.documentID, createdAt: Date(), updatedAt: Date())
        let calendarRef = db.collection("calendars").document(calendar.id)
        
        let batch = db.batch()
        
        // Add progress item
        batch.setData(
            [
                "title": trimmed,
                "ownerUserId": userId,
                "content": ProgressContent().asFirestoreMap(),
                "createdAt": FieldValue.serverTimestamp(),
            ],
            forDocument: progressRef
        )
        
        // Add progress link
        batch.setData(
            [
                "userId": userId,
                "progressItemId": progressRef.documentID,
                "linkedAt": FieldValue.serverTimestamp(),
            ],
            forDocument: linkRef
        )
        
        // Add calendar
        batch.setData(
            [
                "progressItemId": calendar.progressItemId,
                "ownerUserId": userId,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
            ],
            forDocument: calendarRef
        )
        
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.commitBatch(batch)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CreateProgressFailure.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
            // Do not update selection until the listener receives this document from Firestore (server-first).
            pendingSelectProgressId = progressRef.documentID
            return true
        } catch CreateProgressFailure.timedOut {
            errorMessage = "Couldn't create progress in time. Check your connection and try again."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes a progress item, its link, and its calendar (with all nested events via cascade delete).
    /// - Parameter progressId: The ID of the progress item to delete
    /// - Returns: `true` if deletion succeeded, `false` otherwise
    @discardableResult
    func deleteProgress(progressId: String) async -> Bool {
        guard let userId else {
            errorMessage = "User not authenticated"
            return false
        }

        errorMessage = nil
        let db = Firestore.firestore()

        // References to delete
        let progressRef = db.collection("progressItems").document(progressId)
        let linkRef = db.collection("users").document(userId).collection("progressLinks").document(progressId)

        // Find and delete calendar (cascade delete will handle nested events)
        do {
            // Fetch all related invitations to delete them
            let invitationsSnapshot = try await db.collection("invitations")
                .whereField("progressItemId", isEqualTo: progressId)
                .getDocuments()
            let calendarSnapshot = try await db.collection("calendars")
                .whereField("progressItemId", isEqualTo: progressId)
                .limit(to: 1)
                .getDocuments()

            let batch = db.batch()

            // First, cascade delete the calendar and all its events
            if let calendarDoc = calendarSnapshot.documents.first {
                let calendarId = calendarDoc.documentID

                // Fetch all events to delete them
                let eventsSnapshot = try await db.collection("calendars")
                    .document(calendarId)
                    .collection("events")
                    .getDocuments()

                // Delete all events
                for eventDoc in eventsSnapshot.documents {
                    batch.deleteDocument(eventDoc.reference)
                }

                // Delete calendar
                batch.deleteDocument(calendarDoc.reference)
            }

            // Delete all invitations related to this progress
            for invitationDoc in invitationsSnapshot.documents {
                batch.deleteDocument(invitationDoc.reference)
            }

            // Delete progress and link
            batch.deleteDocument(progressRef)
            batch.deleteDocument(linkRef)

            // Commit batch (all deletions atomic)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.commitBatch(batch)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CreateProgressFailure.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
            
            return true
        } catch CreateProgressFailure.timedOut {
            errorMessage = "Couldn't delete progress in time. Check your connection and try again."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

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

    private func fetchProgressItems(ids: [String]) async -> [ProgressItem] {
        guard !ids.isEmpty else { return [] }
        let db = Firestore.firestore()
        return await withTaskGroup(of: (Int, ProgressItem?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    do {
                        let doc = try await db.collection("progressItems").document(id).getDocument()
                        return (index, ProgressItem(document: doc))
                    } catch {
                        return (index, nil)
                    }
                }
            }
            var pairs: [(Int, ProgressItem)] = []
            for await (index, item) in group {
                if let item {
                    pairs.append((index, item))
                }
            }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}