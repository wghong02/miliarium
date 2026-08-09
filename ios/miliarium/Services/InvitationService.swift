import Foundation
import OSLog
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
        AppLogger.invitation.debug("fetchReceivedInvitations userId=\(userId)")
        do {
            let snapshot = try await invitationsRef()
                .whereField("toUserId", isEqualTo: userId)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            return snapshot.documents.compactMap { Invitation(document: $0) }
        } catch {
            AppLogger.invitation.error("fetchReceivedInvitations failed userId=\(userId): \(error)")
            throw error
        }
    }

    /// Invitations the given user has *sent* (owner view).
    func fetchSentInvitations(by userId: String) async throws -> [Invitation] {
        AppLogger.invitation.debug("fetchSentInvitations userId=\(userId)")
        do {
            let snapshot = try await invitationsRef()
                .whereField("fromUserId", isEqualTo: userId)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            return snapshot.documents.compactMap { Invitation(document: $0) }
        } catch {
            AppLogger.invitation.error("fetchSentInvitations failed userId=\(userId): \(error)")
            throw error
        }
    }

    /// All invitations associated with a single progress, regardless of
    /// direction. Used by the owner-side "Invited Users" panel.
    func fetchInvitations(forProgress progressItemId: String) async throws -> [Invitation] {
        AppLogger.invitation.debug("fetchInvitations progressId=\(progressItemId)")
        do {
            let snapshot = try await invitationsRef()
                .whereField("progressItemId", isEqualTo: progressItemId)
                .order(by: "createdAt", descending: true)
                .getDocuments()
            return snapshot.documents.compactMap { Invitation(document: $0) }
        } catch {
            AppLogger.invitation.error("fetchInvitations failed progressId=\(progressItemId): \(error)")
            throw error
        }
    }

    // MARK: - Write

    func acceptInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("acceptInvitation id=\(invitationId)")
        do {
            let doc = try await invitationsRef().document(invitationId).getDocument()
            guard let invitation = Invitation(document: doc) else {
                AppLogger.invitation.error("acceptInvitation failed: invitation not found id=\(invitationId)")
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
            AppLogger.invitation.debug("acceptInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("acceptInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    func declineInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("declineInvitation id=\(invitationId)")
        do {
            try await invitationsRef().document(invitationId).updateData([
                "status": InvitationStatus.declined.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
            AppLogger.invitation.debug("declineInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("declineInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    /// Owner-side withdrawal of a pending invitation. Sets status to
    /// `.revoked` so history is preserved (use `deleteInvitation` if you
    /// actually want it gone from the collection).
    func revokeInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("revokeInvitation id=\(invitationId)")
        do {
            try await invitationsRef().document(invitationId).updateData([
                "status": InvitationStatus.revoked.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ])
            AppLogger.invitation.debug("revokeInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("revokeInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    /// Sends an invitation for `progressItemId` from `fromUserId` to
    /// `toUserId`. **Deduplicates** by reopening any existing row for the
    /// same (sender, recipient, progress) tuple instead of creating a new
    /// one — so resending after a decline/revoke flips the same doc back
    /// to `.pending` rather than producing parallel rows.
    ///
    /// Per-status behavior when an existing row is found:
    ///
    /// | Existing status    | What happens                                            |
    /// |--------------------|---------------------------------------------------------|
    /// | `.pending`         | No-op refresh — `updatedAt` + `progressItemTitle` only. |
    /// | `.declined`        | Reopen — status flips back to `.pending`.               |
    /// | `.revoked`         | Reopen — status flips back to `.pending`.               |
    /// | `.accepted`        | Throws — the recipient is already a collaborator.       |
    ///
    /// The query + write isn't transactional — two concurrent sends could
    /// both miss the existing row and create two new ones. Acceptable for
    /// the single-user-per-device case; a cleanup pass can dedupe later
    /// if it ever matters.
    func sendInvitation(
        from fromUserId: String,
        to toUserId: String,
        progressItemId: String,
        progressItemTitle: String
    ) async throws {
        AppLogger.invitation.debug("sendInvitation from=\(fromUserId) to=\(toUserId) progressId=\(progressItemId)")
        do {
            // Look up ANY existing row for the (sender, recipient, progress)
            // tuple — not just pending — so we can reopen declined/revoked
            // rows and reject accepted ones with a clearer error.
            let existingSnapshot = try await invitationsRef()
                .whereField("fromUserId", isEqualTo: fromUserId)
                .whereField("toUserId", isEqualTo: toUserId)
                .whereField("progressItemId", isEqualTo: progressItemId)
                .getDocuments()

            if let existing = existingSnapshot.documents.first {
                let currentStatus = existing.data()["status"] as? String

                // Already-accepted recipient is a collaborator — re-inviting
                // is a no-op semantically and probably indicates user
                // confusion. Surface a clear error.
                if currentStatus == InvitationStatus.accepted.rawValue {
                    AppLogger.invitation.error("sendInvitation rejected: already accepted id=\(existing.documentID)")
                    throw NSError(
                        domain: "InvitationError",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "This user has already accepted access to this progress."]
                    )
                }

                // pending / declined / revoked: flip back to .pending and
                // refresh the progress title (which may have been renamed
                // since the original invitation). Same doc ID = recipient's
                // listener sees an update on the existing row, not a new
                // arrival alongside the old.
                try await existing.reference.updateData([
                    "status": InvitationStatus.pending.rawValue,
                    "progressItemTitle": progressItemTitle,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
                AppLogger.invitation.debug("sendInvitation reopened id=\(existing.documentID) previousStatus=\(currentStatus ?? "?")")
                return
            }

            // Fresh send — no prior history for this tuple.
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
            AppLogger.invitation.debug("sendInvitation created id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("sendInvitation failed from=\(fromUserId) to=\(toUserId): \(error)")
            throw error
        }
    }

    /// Hard-deletes an invitation. Prefer `revokeInvitation` to preserve
    /// audit history.
    func deleteInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("deleteInvitation id=\(invitationId)")
        do {
            try await invitationsRef().document(invitationId).delete()
            AppLogger.invitation.debug("deleteInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("deleteInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    // MARK: - Listeners

    /// Real-time listener for invitations *received* by `userId`.
    /// `onChange` is invoked on whatever queue Firestore uses — callers on
    /// `@MainActor` must hop themselves.
    func setReceivedInvitationsListener(
        for userId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        AppLogger.invitation.debug("setReceivedInvitationsListener userId=\(userId)")
        let query = invitationsRef()
            .whereField("toUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.invitation.error("receivedInvitationsListener error userId=\(userId): \(error)")
                return
            }
            guard let snapshot else {
                AppLogger.invitation.error("receivedInvitationsListener nil snapshot userId=\(userId)")
                return
            }
            let invitations = snapshot.documents.compactMap { Invitation(document: $0) }
            AppLogger.invitation.debug("receivedInvitationsListener update userId=\(userId) count=\(invitations.count)")
            onChange(invitations)
        }
    }

    /// Real-time listener for invitations *sent* by `userId`.
    func setSentInvitationsListener(
        for userId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        AppLogger.invitation.debug("setSentInvitationsListener userId=\(userId)")
        let query = invitationsRef()
            .whereField("fromUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.invitation.error("sentInvitationsListener error userId=\(userId): \(error)")
                return
            }
            guard let snapshot else {
                AppLogger.invitation.error("sentInvitationsListener nil snapshot userId=\(userId)")
                return
            }
            let invitations = snapshot.documents.compactMap { Invitation(document: $0) }
            AppLogger.invitation.debug("sentInvitationsListener update userId=\(userId) count=\(invitations.count)")
            onChange(invitations)
        }
    }

    /// Real-time listener for all invitations attached to one progress
    /// (used by the owner-side "Invited Users" panel).
    func setProgressInvitationsListener(
        for progressItemId: String,
        onChange: @escaping ([Invitation]) -> Void
    ) -> ListenerRegistration {
        AppLogger.invitation.debug("setProgressInvitationsListener progressId=\(progressItemId)")
        let query = invitationsRef()
            .whereField("progressItemId", isEqualTo: progressItemId)
            .order(by: "createdAt", descending: true)
        return query.addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.invitation.error("progressInvitationsListener error progressId=\(progressItemId): \(error)")
                return
            }
            guard let snapshot else {
                AppLogger.invitation.error("progressInvitationsListener nil snapshot progressId=\(progressItemId)")
                return
            }
            let invitations = snapshot.documents.compactMap { Invitation(document: $0) }
            AppLogger.invitation.debug("progressInvitationsListener update progressId=\(progressItemId) count=\(invitations.count)")
            onChange(invitations)
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
