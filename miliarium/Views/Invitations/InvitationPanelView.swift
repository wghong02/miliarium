import SwiftUI

struct InvitationPanelView: View {
    @Environment(InvitationViewModel.self) private var invitationVM

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invitations")
                    .font(.headline)
                Spacer()
                if invitationVM.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button(action: {
                        Task {
                            await invitationVM.refreshInvitations()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if invitationVM.invitations.isEmpty {
                Text("No pending invitations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(invitationVM.invitations) { invitation in
                        InvitationItemView(invitation: invitation)
                    }
                }
            }

            if let error = invitationVM.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .onAppear {
            Task {
                await invitationVM.refreshInvitations()
            }
        }
    }
}

struct InvitationItemView: View {
    @Environment(InvitationViewModel.self) private var invitationVM
    let invitation: Invitation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(invitation.progressItemTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("From: \(invitation.fromUserEmail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            if invitation.status == .pending {
                HStack(spacing: 8) {
                    Button("Accept") {
                        Task {
                            await invitationVM.acceptInvitation(invitation)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button("Decline") {
                        Task {
                            await invitationVM.declineInvitation(invitation)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch invitation.status {
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
}

#Preview {
    InvitationPanelView()
        .environment(InvitationViewModel())
}
