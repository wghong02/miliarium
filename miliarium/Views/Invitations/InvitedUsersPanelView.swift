import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct InvitedUsersPanelView: View {
    let progressItemId: String
    let progressItemTitle: String

    @Environment(AuthViewModel.self) private var authVM
    @State private var invitedUsers: [InvitedUserInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invited Users")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button(action: {
                        Task {
                            await refreshInvitedUsers()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if invitedUsers.isEmpty {
                Text("No invitations sent yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(invitedUsers) { userInfo in
                        InvitedUserItemView(userInfo: userInfo, progressItemId: progressItemId)
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .onAppear {
            if !listenerInitialized {
                setUpListener()
                listenerInitialized = true
            }
        }
        .onDisappear {
            listener?.remove()
            listenerInitialized = false
        }
    }

    private func setUpListener() {
        guard let userId = authVM.user?.uid else { return }

        isLoading = true
        print("[InvitedUsersPanel] Setting up listener for progress: \(progressItemId)")

        let query = Firestore.firestore()
            .collection("invitations")
            .whereField("fromUserId", isEqualTo: userId)
            .whereField("progressItemId", isEqualTo: progressItemId)
            .order(by: "createdAt", descending: true)

        listener = query.addSnapshotListener { snapshot, error in
            Task { @MainActor in

                if let error {
                    print("[InvitedUsersPanel] Listener error: \(error.localizedDescription)")
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let snapshot else {
                    print("[InvitedUsersPanel] Snapshot is nil")
                    self.isLoading = false
                    return
                }

                print("[InvitedUsersPanel] Received \(snapshot.documents.count) invitations")
                self.errorMessage = nil

                var users: [InvitedUserInfo] = []
                for doc in snapshot.documents {
                    if let invitation = Invitation(document: doc) {
                        let userInfo = InvitedUserInfo(
                            userId: invitation.toUserId,
                            email: invitation.toUserEmail,
                            status: invitation.status,
                            invitationId: invitation.id
                        )
                        users.append(userInfo)
                    }
                }

                self.invitedUsers = users
                print("[InvitedUsersPanel] Loaded \(users.count) invited users")
                self.isLoading = false
            }
        }
    }

    @MainActor
    private func refreshInvitedUsers() async {
        guard let userId = authVM.user?.uid else { return }
        do {
            print("[InvitedUsersPanel] Manually refreshing invited users")
            let snapshot = try await Firestore.firestore()
                .collection("invitations")
                .whereField("fromUserId", isEqualTo: userId)
                .whereField("progressItemId", isEqualTo: progressItemId)
                .getDocuments()

            var users: [InvitedUserInfo] = []
            for doc in snapshot.documents {
                if let invitation = Invitation(document: doc) {
                    let userInfo = InvitedUserInfo(
                        userId: invitation.toUserId,
                        email: invitation.toUserEmail,
                        status: invitation.status,
                        invitationId: invitation.id
                    )
                    users.append(userInfo)
                }
            }

            self.invitedUsers = users
            print("[InvitedUsersPanel] Refreshed \(users.count) invited users")
        } catch {
            self.errorMessage = error.localizedDescription
            print("[InvitedUsersPanel] Refresh error: \(error.localizedDescription)")
        }
    }
}

struct InvitedUserInfo: Identifiable {
    let id = UUID()
    let userId: String
    let email: String
    let status: InvitationStatus
    let invitationId: String
}

struct InvitedUserItemView: View {
    let userInfo: InvitedUserInfo
    let progressItemId: String

    @State private var isRevoking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(userInfo.email)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                statusBadge
            }

            HStack(spacing: 8) {
                Button(role: .destructive) {
                    revokeInvitation()
                } label: {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Revoke")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isRevoking)
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch userInfo.status {
        case .pending:
            Text("Pending")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.2))
                .foregroundStyle(.orange)
                .cornerRadius(4)
        case .accepted:
            Text("Accepted")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.2))
                .foregroundStyle(.green)
                .cornerRadius(4)
        case .declined:
            Text("Declined")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.2))
                .foregroundStyle(.red)
                .cornerRadius(4)
        }
    }

    private func revokeInvitation() {
        isRevoking = true
        Task {
            do {
                try await invitationService.deleteInvitation(userInfo.invitationId)
                print("[InvitedUserItem] Revoked invitation: \(userInfo.invitationId)")
            } catch {
                print("[InvitedUserItem] Error revoking invitation: \(error.localizedDescription)")
            }
            await MainActor.run {
                isRevoking = false
            }
        }
    }
}

#Preview {
    InvitedUsersPanelView(
        progressItemId: "test123",
        progressItemTitle: "My Progress"
    )
    .environment(AuthViewModel())
}
