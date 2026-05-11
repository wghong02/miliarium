import Foundation
import FirebaseFirestore

class InvitationService {
    private let db = Firestore.firestore()

    func fetchInvitations(for userId: String) async throws -> [Invitation] {
        let snapshot = try await db.collection("users")
            .document(userId)
            .collection("invitations")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { Invitation(document: $0) }
    }

    func acceptInvitation(_ invitationId: String, for userId: String) async throws {
        let invitationRef = db.collection("users")
            .document(userId)
            .collection("invitations")
            .document(invitationId)

        try await invitationRef.updateData([
            "status": InvitationStatus.accepted.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func declineInvitation(_ invitationId: String, for userId: String) async throws {
        let invitationRef = db.collection("users")
            .document(userId)
            .collection("invitations")
            .document(invitationId)

        try await invitationRef.updateData([
            "status": InvitationStatus.declined.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func sendInvitation(
        from fromUserId: String,
        fromEmail: String,
        to toUserId: String,
        progressItemId: String,
        progressItemTitle: String
    ) async throws {
        let invitation = Invitation(
            fromUserId: fromUserId,
            fromUserEmail: fromEmail,
            progressItemId: progressItemId,
            progressItemTitle: progressItemTitle,
            status: .pending
        )

        let invitationRef = db.collection("users")
            .document(toUserId)
            .collection("invitations")
            .document(invitation.id)

        try await invitationRef.setData(invitation.asFirestoreMap())
    }

    func deleteInvitation(_ invitationId: String, for userId: String) async throws {
        let invitationRef = db.collection("users")
            .document(userId)
            .collection("invitations")
            .document(invitationId)

        try await invitationRef.delete()
    }
}

let invitationService = InvitationService()
