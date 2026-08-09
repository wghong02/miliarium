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
            // The backend verifies the caller is the recipient, flips the
            // status, and creates their progressLink.
            try await BackendClient.shared.request("POST", "/invitations/\(invitationId)/accept")
            AppLogger.invitation.debug("acceptInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("acceptInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    func declineInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("declineInvitation id=\(invitationId)")
        do {
            try await BackendClient.shared.request("POST", "/invitations/\(invitationId)/decline")
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
            try await BackendClient.shared.request("POST", "/invitations/\(invitationId)/revoke")
            AppLogger.invitation.debug("revokeInvitation succeeded id=\(invitationId)")
        } catch {
            AppLogger.invitation.error("revokeInvitation failed id=\(invitationId): \(error)")
            throw error
        }
    }

    /// Sends an invitation for `progressItemId` to the user with `toEmail`.
    /// The backend resolves the email to a user (with admin privileges, so the
    /// client never queries `users` by email), then **deduplicates** by
    /// reopening any existing row for the same (sender, recipient, progress)
    /// tuple rather than creating a parallel one. Reopening a `declined`/
    /// `revoked` row flips it back to `.pending`; an already-`accepted` row
    /// yields a clear error.
    func sendInvitation(
        from fromUserId: String,
        toEmail: String,
        progressItemId: String,
        progressItemTitle: String
    ) async throws {
        AppLogger.invitation.debug("sendInvitation from=\(fromUserId) toEmail=\(toEmail) progressId=\(progressItemId)")
        struct Body: Encodable {
            let progressItemId: String
            let progressItemTitle: String
            let toEmail: String
        }
        do {
            try await BackendClient.shared.request(
                "POST", "/invitations",
                body: Body(
                    progressItemId: progressItemId,
                    progressItemTitle: progressItemTitle,
                    toEmail: toEmail
                )
            )
            AppLogger.invitation.debug("sendInvitation succeeded toEmail=\(toEmail)")
        } catch {
            AppLogger.invitation.error("sendInvitation failed toEmail=\(toEmail): \(error)")
            throw error
        }
    }

    /// Hard-deletes an invitation. Prefer `revokeInvitation` to preserve
    /// audit history.
    func deleteInvitation(_ invitationId: String) async throws {
        AppLogger.invitation.debug("deleteInvitation id=\(invitationId)")
        do {
            try await BackendClient.shared.request("DELETE", "/invitations/\(invitationId)")
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

}

let invitationService = InvitationService()
