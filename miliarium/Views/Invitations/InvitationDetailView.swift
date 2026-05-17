import SwiftUI

struct InvitationDetailView: View {
    @Environment(InvitationViewModel.self) private var invitationVM
    @Environment(\.dismiss) private var dismiss

    let invitation: Invitation

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    Text("Collaboration Invitation")
                        .font(.headline)

                    Text(invitation.progressItemTitle)
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 12) {
                    InformationRow(label: "From", value: invitation.fromUserEmail)
                    Divider()
                    InformationRow(label: "Project", value: invitation.progressItemTitle)
                    Divider()
                    InformationRow(label: "Status", value: invitation.status.rawValue.capitalized)
                    Divider()
                    InformationRow(label: "Received", value: formatDate(invitation.createdAt))
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                if invitation.status == .pending {
                    VStack(spacing: 12) {
                        Button(action: acceptInvitation) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Accept Invitation")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                        }

                        Button(action: declineInvitation) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Decline Invitation")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func acceptInvitation() {
        Task {
            await invitationVM.acceptInvitation(invitation)
            dismiss()
        }
    }

    private func declineInvitation() {
        Task {
            await invitationVM.declineInvitation(invitation)
            dismiss()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct InformationRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }
}

#Preview {
    InvitationDetailView(
        invitation: Invitation(
            fromUserId: "user123",
            fromUserEmail: "friend@example.com",
            toUserId: "user456",
            toUserEmail: "otherfriend@example.com",
            progressItemId: "progress123",
            progressItemTitle: "Learn Swift",
            status: .pending
        )
    )
    .environment(InvitationViewModel())
}
