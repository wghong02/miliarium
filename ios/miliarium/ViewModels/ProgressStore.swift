import Foundation
import OSLog
import Observation
import FirebaseFirestore

private enum CreateProgressFailure: Error {
    case timedOut
}

/// Progress data lives in `progressItems/{progressItemId}`.
/// Per-user membership is tracked in `users/{userId}/progressLinks/{progressItemId}` (document id matches the item id).
/// Each progress owns two subcollections — `activities/{id}` and `collections/{id}` — that
/// together implement the unified activities model.
@Observable
@MainActor
final class ProgressStore {
    private(set) var progresses: [ProgressItem] = []
    private(set) var selectedProgressId: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    /// Role per linked progress, sourced directly from the link doc's
    /// `role` field. Missing entries fall back to inference from the
    /// progress item's `ownerUserId` (via `role(forProgressId:)`).
    private(set) var rolesByProgressId: [String: ProgressRole] = [:]

    private var listener: ListenerRegistration?
    private var userId: String?

    /// Set after a successful server write; cleared once the snapshot listener shows that progress locally.
    private var pendingSelectProgressId: String?

    func updateUserId(_ id: String?) {
        listener?.remove()
        listener = nil
        userId = id
        progresses = []
        rolesByProgressId = [:]
        selectedProgressId = nil
        pendingSelectProgressId = nil
        errorMessage = nil

        guard let id else {
            isLoading = false
            AppLogger.progressStore.debug("updateUserId: cleared (signed out)")
            return
        }

        AppLogger.progressStore.debug("updateUserId userId=\(id)")
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
                    AppLogger.progressStore.error("progressLinksListener error userId=\(id): \(error)")
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let snapshot else {
                    AppLogger.progressStore.error("progressLinksListener nil snapshot userId=\(id)")
                    self.isLoading = false
                    return
                }
                self.errorMessage = nil
                let orderedIds = snapshot.documents.map(\.documentID)
                // Capture roles from the link docs; missing entries fall
                // back to inference at lookup time.
                var roles: [String: ProgressRole] = [:]
                for doc in snapshot.documents {
                    if let raw = doc.data()["role"] as? String,
                       let role = ProgressRole(rawValue: raw) {
                        roles[doc.documentID] = role
                    }
                }
                let items = await self.fetchProgressItems(ids: orderedIds)
                self.isLoading = false
                AppLogger.progressStore.debug("progressLinksListener update userId=\(id) count=\(items.count)")
                // Server snapshot is source of truth — only update in-memory list after Firestore delivers data.
                self.progresses = items
                self.rolesByProgressId = roles

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

    /// Returns the current user's role on the given progress. Prefers the
    /// link doc's stored `role` field; if absent (e.g. older link docs that
    /// predate the field), infers from the progress item's `ownerUserId`.
    /// Returns `nil` only when neither source has data, which shouldn't
    /// happen for a progress the user is actually linked to.
    func role(forProgressId progressId: String) -> ProgressRole? {
        if let stored = rolesByProgressId[progressId] {
            return stored
        }
        guard let userId,
              let item = progresses.first(where: { $0.id == progressId }) else {
            return nil
        }
        return item.inferredRole(forUserId: userId)
    }

    /// Convenience used by views: `true` when the current user owns the
    /// given progress (or, if role isn't known yet, when ownership is
    /// inferrable from the loaded progress item).
    func isOwner(of progressId: String) -> Bool {
        role(forProgressId: progressId) == .owner
    }

    /// Updates the summary of a progress item (via the backend).
    func updateProgressSummary(progressId: String, summary: String) async -> Bool {
        AppLogger.progressStore.debug("updateProgressSummary progressId=\(progressId)")
        errorMessage = nil
        struct Body: Encodable { let summary: String }

        do {
            try await BackendClient.shared.request(
                "PATCH", "/progress/\(progressId)", body: Body(summary: summary)
            )

            // Update local cache immediately; the listener will confirm.
            if let index = progresses.firstIndex(where: { $0.id == progressId }) {
                progresses[index].content.summary = summary
            }

            AppLogger.progressStore.debug("updateProgressSummary succeeded progressId=\(progressId)")
            return true
        } catch {
            AppLogger.progressStore.error("updateProgressSummary failed progressId=\(progressId): \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates one progress document + owner link. No default collection is
    /// seeded — users can either create their own collections or leave
    /// activities un-collected (they still appear in the virtual "All
    /// activities" view). Waits at most **3 seconds**; does not retry.
    @discardableResult
    func createProgress(title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, userId != nil else { return false }
        AppLogger.progressStore.debug("createProgress title=\(trimmed)")
        errorMessage = nil
        // Client-generated id so we can select the new progress once the
        // listener delivers it; the backend creates the doc + owner link.
        let newId = UUID().uuidString
        struct Body: Encodable { let id: String; let title: String }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await BackendClient.shared.request(
                        "POST", "/progress", body: Body(id: newId, title: trimmed)
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw CreateProgressFailure.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
            // Do not update selection until the listener receives this document from Firestore (server-first).
            pendingSelectProgressId = newId
            AppLogger.progressStore.debug("createProgress succeeded id=\(newId) title=\(trimmed)")
            return true
        } catch CreateProgressFailure.timedOut {
            AppLogger.progressStore.error("createProgress timed out title=\(trimmed)")
            errorMessage = "Couldn't create progress in time. Check your connection and try again."
            return false
        } catch {
            AppLogger.progressStore.error("createProgress failed title=\(trimmed): \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Deletes a progress item and everything that references it: every
    /// invitation, every activity, every collection, and the
    /// `progressLinks/{progressId}` doc under *every* user (owner +
    /// collaborators). Only the owner may delete; collaborators get an
    /// authorization error.
    ///
    /// The cross-user link cleanup uses a `progressLinks` collection-group
    /// query — a matching collection-group index on the `progressItemId`
    /// field is required (Firebase will surface a "create index" deep link
    /// the first time the query runs).
    ///
    /// - Parameter progressId: The ID of the progress item to delete
    /// - Returns: `true` if deletion succeeded, `false` otherwise
    @discardableResult
    func deleteProgress(progressId: String) async -> Bool {
        guard userId != nil else {
            errorMessage = "User not authenticated"
            return false
        }
        guard isOwner(of: progressId) else {
            errorMessage = "Only the owner can delete this progress."
            return false
        }

        AppLogger.progressStore.debug("deleteProgress progressId=\(progressId)")
        errorMessage = nil

        do {
            // The backend verifies ownership and deletes the top-level progress
            // doc; the `onProgressDeleted` trigger cascades everything that
            // referenced it — activities + collections subtrees (and their media
            // / Storage), plus every invitation and every user's progressLink.
            // See backend/cascadeDeletes.ts.
            try await BackendClient.shared.request("DELETE", "/progress/\(progressId)")
            AppLogger.progressStore.debug("deleteProgress succeeded progressId=\(progressId)")
            return true
        } catch {
            AppLogger.progressStore.error("deleteProgress failed progressId=\(progressId): \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func fetchProgressItems(ids: [String]) async -> [ProgressItem] {
        guard !ids.isEmpty else { return [] }
        AppLogger.progressStore.debug("fetchProgressItems count=\(ids.count)")
        let db = Firestore.firestore()
        return await withTaskGroup(of: (Int, ProgressItem?, String?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    do {
                        let doc = try await db.collection("progressItems").document(id).getDocument()
                        return (index, ProgressItem(document: doc), nil)
                    } catch {
                        return (index, nil, "\(error)")
                    }
                }
            }
            var pairs: [(Int, ProgressItem)] = []
            for await (index, item, errorDescription) in group {
                if let item {
                    pairs.append((index, item))
                } else if let errorDescription {
                    AppLogger.progressStore.error("fetchProgressItems failed for id=\(ids[index]): \(errorDescription)")
                }
            }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}