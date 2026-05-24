import SwiftUI
import FirebaseFirestore
import FirebaseAuth

struct InvitedUsersPanelView: View {
    let progressItemId: String
    let progressItemTitle: String

    @Environment(AuthViewModel.self) private var authVM
    @State private var invitedUsers: [InvitedUserInfo] = []
    @State private var userCache: [String: AppUser] = [:]
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
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(invitedUsers) { userInfo in
                            InvitedUserItemView(
                                userInfo: userInfo,
                                progressItemId: progressItemId,
                                displayName: displayString(for: userInfo.userId)
                            )
                        }
                    }
                }
                .frame(maxHeight: 260)
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
        listener = invitationService.setProgressInvitationsListener(
            for: progressItemId
        ) { invitations in
            // Listener fires off-MainActor; hop before mutating @State.
            Task { @MainActor in
                self.errorMessage = nil
                self.invitedUsers = invitations
                    .filter { $0.fromUserId == userId }
                    .map {
                        InvitedUserInfo(
                            userId: $0.toUserId,
                            status: $0.status,
                            invitationId: $0.id
                        )
                    }
                self.isLoading = false
                await self.cacheUsers(forIds: self.invitedUsers.map { $0.userId })
            }
        }
    }

    @MainActor
    private func refreshInvitedUsers() async {
        guard let userId = authVM.user?.uid else { return }
        do {
            let invitations = try await invitationService.fetchInvitations(
                forProgress: progressItemId
            )
            self.invitedUsers = invitations
                .filter { $0.fromUserId == userId }
                .map {
                    InvitedUserInfo(
                        userId: $0.toUserId,
                        status: $0.status,
                        invitationId: $0.id
                    )
                }
            await cacheUsers(forIds: self.invitedUsers.map { $0.userId })
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func displayString(for userId: String) -> String {
        userCache[userId]?.displayString ?? "Loading…"
    }

    private func cacheUsers(forIds ids: [String]) async {
        let missing = Array(Set(ids).subtracting(userCache.keys))
        guard !missing.isEmpty else { return }
        do {
            let users = try await userService.fetchUsers(ids: missing)
            for user in users {
                userCache[user.id] = user
            }
        } catch {
            // Best-effort enrichment; rows keep showing "Loading…".
        }
    }
}

struct InvitedUserInfo: Identifiable {
    let id = UUID()
    let userId: String
    let status: InvitationStatus
    let invitationId: String
}

struct InvitedUserItemView: View {
    let userInfo: InvitedUserInfo
    let progressItemId: String
    let displayName: String

    @State private var isRevoking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                statusBadge
            }

            if userInfo.status == .pending {
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
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color) = badgeStyle(for: userInfo.status)
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    private func badgeStyle(for status: InvitationStatus) -> (String, Color) {
        switch status {
        case .pending:  return ("Pending", .orange)
        case .accepted: return ("Accepted", .green)
        case .declined: return ("Declined", .red)
        case .revoked:  return ("Revoked", .gray)
        }
    }

    private func revokeInvitation() {
        isRevoking = true
        Task {
            do {
                try await invitationService.revokeInvitation(userInfo.invitationId)
            } catch {
                // Surface failures inline once we have a binding for it;
                // for now, just stop the spinner.
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
