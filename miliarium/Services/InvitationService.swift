import Foundation
import FirebaseFirestore

/// CRUD + listener service for `invitations/{invitationId}` (top-level
/// collection). Surfaces both *received* (filtered by `toUserId`) and
/// *sent* (filtered by `fromUserId`) views, plus a per-progress lookup
/// used by the "Invited Users" owner-side panel.
class InvitationService {
    private let db = Firestore.firestore()

    private func invitationsRef() -> CollectionReference {
        db.collection("invitations")
    }

    // MARK: - Read

    /// Invitations addressed to `userId` (i.e. the recipient view).
    func fetchReceivedInvitations(for userId: String) async throws -> [Invitation] {
        let snapshot = try await invitationsRef()
            .whereField("toUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snapshot.documents.compactMap { Invitation(document: $0) }
    }

    /// Invitations the given user has *sent* (owner view).
    func fetchSentInvitations(by userId: String) async throws -> [Invitation] {
        let snapshot = try await invitationsRef()
            .whereField("fromUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snapshot.documents.compactMap { Invitation(document: $0) }
    }

    /// All invitations associated with a single progress, regardless of
    /// direction. Used by the owner-side "Invited Users" panel.
    func fetchInvitations(forProgress progressItemId: String) async throws -> [Invitation] {
        let snapshot = try await invitationsRef()
            .whereField("progressItemId", isEqualTo: progressItemId)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snapshot.documents.compactMap { Invitation(document: $0) }
    }

    // MARK: - Write

    func acceptInvitation(_ invitationId: String) async throws {
        let doc = try await invitationsRef().document(invitationId).getDocument()
        guard let invitation = Invitation(document: doc) else {
            throw NSError(
                domain: "InvitationError",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Invitation not found"]
            )
        }

        let invitationRef = invitationsRef().document(invitationId)
        let progressLinkRef = db.collection("users")
            .document(invitation.toUserId)
            .collection("progressLinks")
            .document(invitation.progressItemId)

        let batch = db.batch()
        batch.updateData(
            [
                "status": InvitationStatus.accepted.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ],
            forDocument: invitationRef
        )
        batch.setData(
            [
                "userId": invitation.toUserId,
                "progressItemId": invitation.progressItemId,
                "linkedAt": FieldValue.serverTimestamp(),
                "role": ProgressRole.collaborator.rawValue
            ],
            forDocument: progressLinkRef,
            merge: true
        )

        try await Self.commitBatch(batch)
    }

    func declineInvitation(_ invitationId: String) async throws {
        try await invitationsRef().document(invitationId).updateData([
            "status": InvitationStatus.declined.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    /// Owner-side withdrawal of a pending invitation. Sets status to
    /// `.revoked` so history is preserved (use `deleteInvitation` if you
    /// actually want it gone from the collection).
    func revokeInvitation(_ invitationId: String) async throws {
        try await invitationsRef().document(invitationId).updateData([
            "status": InvitationStatus.revoked.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func sendInvitation(
        from fromUserId: String,
        to toUserId: String,
        progressItemId: String,
        progressItemTitle: String
    ) async throws {
        // Reject if a *pending* invitation for the same (sender, receiver,
        // progress) tuple already exists. Note: this is a read-then-write
        // and not transactional — two concurrent sends could both pass the
        // check. Acceptable for the single-user-per-device case.
        let existingSnapshot = try await invitationsRef()
            .whereField("fromUserId", isEqualTo: fromUserId)
            .whereField("toUserId", isEqualTo: toUserId)
            .whereField("progressItemId", isEqualTo: progressItemId)
            .whereField("status", isEqualTo: InvitationStatus.pending.rawValue)
            .getDocuments()

        if !existingSnapshot.documents.isEmpty {
            throw NSError(
                domain: "InvitationError",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "An invitation already exists for this progress item"]
            )
        }

        let invitationId = UUID().uuidString
        let invitationRef = invitationsRef().document(invitationId)

        // Note: sender/recipient email and name are NOT snapshotted on the
        // invitation. Views resolve them live via `AppUser` so renames /
        // email changes propagate automatically.
        let data: [String: Any] = [
            "fromUserId": fromUserId,
            "toUserId": toUserId,
            "progressItemId": progressItemId,
            "progressItemTitle": progressItemTitle,
            "status": InvitationStatus.pending.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]

        try await invitationRef.setData(data)
    }

    /// Hard-deletes an invitation. Prefer `revokeInvitation` to preserve
    /// audit history.
    func deleteInvitation(_ invitationId: String) async throws {
        try await invitationsRef().document(invitationId).delete()
    }

    // MARK: - Listeners

    /// Real-time listener for invitations *received* by `userId`.
    /// `onChange` is invoked on whatever queue Firestore uses — callers on
    /// `@MainActor` must hop themselves.
    func setReceivedInvitationsListener(
        for userId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        let query = invitationsRef()
            .whereField("toUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[InvitationService] Received listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            onChange(snapshot.documents.compactMap { Invitation(document: $0) })
        }
    }

    /// Real-time listener for invitations *sent* by `userId`.
    func setSentInvitationsListener(
        for userId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        let query = invitationsRef()
            .whereField("fromUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[InvitationService] Sent listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            onChange(snapshot.documents.compactMap { Invitation(document: $0) })
        }
    }

    /// Real-time listener for all invitations attached to one progress
    /// (used by the owner-side "Invited Users" panel).
    func setProgressInvitationsListener(
        for progressItemId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        let query = invitationsRef()
            .whereField("progressItemId", isEqualTo: progressItemId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                print("[InvitationService] Progress listener error: \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            onChange(snapshot.documents.compactMap { Invitation(document: $0) })
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

let invitationService = InvitationService()
