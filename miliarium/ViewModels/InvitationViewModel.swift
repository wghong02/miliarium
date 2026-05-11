import Foundation
import Observation
import FirebaseFirestore

@Observable
@MainActor
final class InvitationViewModel {
    private(set) var invitations: [Invitation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var userId: String?
    private var listener: ListenerRegistration?

    func setUserId(_ id: String?) {
        listener?.remove()
        listener = nil
        userId = id
        invitations = []
        errorMessage = nil

        guard let id else {
            isLoading = false
            return
        }

        isLoading = true
        let query = Firestore.firestore()
            .collection("users")
            .document(id)
            .collection("invitations")
            .order(by: "createdAt", descending: true)

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
                self.invitations = snapshot.documents.compactMap { Invitation(document: $0) }
                self.isLoading = false
            }
        }
    }

    func acceptInvitation(_ invitation: Invitation) async {
        guard let userId else { return }
        do {
            try await invitationService.acceptInvitation(invitation.id, for: userId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInvitation(_ invitation: Invitation) async {
        guard let userId else { return }
        do {
            try await invitationService.declineInvitation(invitation.id, for: userId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        listener?.remove()
    }
}
