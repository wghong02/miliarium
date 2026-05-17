import Foundation
import FirebaseFirestore

class InvitationService {
    private let db = Firestore.firestore()

    func fetchInvitations(for userId: String) async throws -> [Invitation] {
        let snapshot = try await db.collection("invitations")
            .whereField("toUserId", isEqualTo: userId)
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { Invitation(document: $0) }
    }

    func acceptInvitation(_ invitationId: String) async throws {
        // First fetch the invitation to get the toUserId and progressItemId
        let invitationDoc = try await db.collection("invitations").document(invitationId).getDocument()
        guard let invitation = Invitation(document: invitationDoc) else {
            throw NSError(domain: "InvitationError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Invitation not found"])
        }

        let invitationRef = db.collection("invitations").document(invitationId)
        let progressLinkRef = db.collection("users")
            .document(invitation.toUserId)
            .collection("progressLinks")
            .document(invitation.progressItemId)

        let batch = db.batch()

        // Update invitation status
        batch.updateData([
            "status": InvitationStatus.accepted.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ], forDocument: invitationRef)

        // Create progress link for the user
        batch.setData([
            "userId": invitation.toUserId,
            "progressItemId": invitation.progressItemId,
            "linkedAt": FieldValue.serverTimestamp()
        ], forDocument: progressLinkRef, merge: true)

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

    func declineInvitation(_ invitationId: String) async throws {
        let invitationRef = db.collection("invitations").document(invitationId)

        try await invitationRef.updateData([
            "status": InvitationStatus.declined.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func sendInvitation(
        from fromUserId: String,
        fromEmail: String,
        to toUserId: String,
        toEmail: String,
        progressItemId: String,
        progressItemTitle: String
    ) async throws {
        // Check if an invitation already exists for this combination
        let existingSnapshot = try await db.collection("invitations")
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
        let invitationRef = db.collection("invitations").document(invitationId)

        let data: [String: Any] = [
            "fromUserId": fromUserId,
            "fromUserEmail": fromEmail,
            "toUserId": toUserId,
            "toUserEmail": toEmail,
            "progressItemId": progressItemId,
            "progressItemTitle": progressItemTitle,
            "status": InvitationStatus.pending.rawValue,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]

        try await invitationRef.setData(data)
    }

    func deleteInvitation(_ invitationId: String) async throws {
        let invitationRef = db.collection("invitations").document(invitationId)
        try await invitationRef.delete()
    }
}

let invitationService = InvitationService()
