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
                    Text("From: \(invitationVM.displayString(for: invitation.fromUserId))")
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
        let (label, color) = badgeStyle(for: invitation.status)
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
}

#Preview {
    InvitationPanelView()
        .environment(InvitationViewModel())
}
