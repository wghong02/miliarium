import SwiftUI

struct SendInvitationSheet: View {
    @Environment(InvitationViewModel.self) private var invitationVM
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    let progressItemTitle: String
    let currentUserId: String

    @State private var recipientEmail = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email address", text: $recipientEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disabled(isLoading)
                        .onChange(of: recipientEmail) { _, newValue in
                            if newValue.count > TextLimits.name {
                                recipientEmail = String(newValue.prefix(TextLimits.name))
                            }
                        }
                } header: {
                    HStack {
                        Text("Recipient")
                        Spacer()
                        CharacterCounter(
                            count: recipientEmail.count,
                            limit: TextLimits.name
                        )
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let success = successMessage {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(success)
                                .foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                }

                Section {
                    Button("Send Invitation") {
                        sendInvitation()
                    }
                    .disabled(recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Send Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func sendInvitation() {
        let trimmed = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        Task {
            do {
                // The backend resolves the email to a user (admin-side, so the
                // client never queries `users` by email) and sends the invite.
                try await invitationService.sendInvitation(
                    from: currentUserId,
                    toEmail: trimmed,
                    progressItemId: progressItemId,
                    progressItemTitle: progressItemTitle
                )

                await MainActor.run {
                    isLoading = false
                    successMessage = "Invitation sent to \(trimmed)"
                    recipientEmail = ""

                    // Close after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                // `sendInvitation` reopens any prior row for this recipient
                // (declined/revoked → pending) and throws a ready-to-show
                // message only for the already-accepted case, so surface the
                // error text directly.
                let errMsg = error.localizedDescription
                await MainActor.run {
                    isLoading = false
                    errorMessage = errMsg
                }
            }
        }
    }

}

#Preview {
    SendInvitationSheet(
        progressItemId: "test123",
        progressItemTitle: "My Progress",
        currentUserId: "user123"
    )
    .environment(InvitationViewModel())
}
