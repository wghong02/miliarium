import Foundation
import Observation
import FirebaseFirestore

@Observable
@MainActor
final class InvitationViewModel {
    private(set) var invitations: [Invitation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    nonisolated(unsafe) private var userId: String?
    nonisolated(unsafe) private var listener: ListenerRegistration?

    @MainActor
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
        userId = id
        print("[InvitationVM] Setting up listener for user: \(id)")

        // Set up real-time listener
        let query = Firestore.firestore()
            .collection("invitations")
            .whereField("toUserId", isEqualTo: id)
            .order(by: "createdAt", descending: true)

        listener = query.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    print("[InvitationVM] Listener error: \(error.localizedDescription)")
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let snapshot else {
                    print("[InvitationVM] Snapshot is nil")
                    self.isLoading = false
                    return
                }

                print("[InvitationVM] Received \(snapshot.documents.count) invitations from listener")
                self.errorMessage = nil
                self.invitations = snapshot.documents.compactMap { doc in
                    if let invitation = Invitation(document: doc) {
                        print("[InvitationVM] Successfully parsed invitation: \(doc.documentID)")
                        return invitation
                    } else {
                        print("[InvitationVM] Failed to parse invitation: \(doc.documentID)")
                        print("[InvitationVM] Document data: \(doc.data())")
                        return nil
                    }
                }
                print("[InvitationVM] Loaded \(self.invitations.count) invitations successfully")
                self.isLoading = false
            }
        }

        // Also do an initial fetch to ensure data loads quickly
        Task {
            do {
                print("[InvitationVM] Performing initial fetch for user: \(id)")
                let freshInvitations = try await invitationService.fetchInvitations(for: id)
                await MainActor.run {
                    self.invitations = freshInvitations
                    self.errorMessage = nil
                    print("[InvitationVM] Initial fetch loaded \(freshInvitations.count) invitations")
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    print("[InvitationVM] Initial fetch error: \(error.localizedDescription)")
                    self.isLoading = false
                }
            }
        }
    }

    func acceptInvitation(_ invitation: Invitation) async {
        do {
            try await invitationService.acceptInvitation(invitation.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInvitation(_ invitation: Invitation) async {
        do {
            try await invitationService.declineInvitation(invitation.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func refreshInvitations() async {
        guard let userId else { return }
        do {
            print("[InvitationVM] Manually refreshing invitations")
            let freshInvitations = try await invitationService.fetchInvitations(for: userId)
            self.invitations = freshInvitations
            print("[InvitationVM] Refreshed \(freshInvitations.count) invitations")
        } catch {
            self.errorMessage = error.localizedDescription
            print("[InvitationVM] Refresh error: \(error.localizedDescription)")
        }
    }

    deinit {
        listener?.remove()
    }
}
