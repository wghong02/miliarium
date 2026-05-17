import SwiftUI
import FirebaseFirestore

struct SendInvitationSheet: View {
    @Environment(InvitationViewModel.self) private var invitationVM
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    let progressItemTitle: String
    let currentUserId: String
    let currentUserEmail: String

    @State private var recipientEmail = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("Email address", text: $recipientEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .disabled(isLoading)
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
                print("Looking up user with email: \(trimmed)")
                // Look up the recipient user by email
                let recipientUserId = try await lookupUserByEmail(trimmed)
                print("Found recipient user ID: \(recipientUserId)")

                // Send the invitation
                print("Sending invitation to \(recipientUserId) for progress \(progressItemId)")
                try await invitationService.sendInvitation(
                    from: currentUserId,
                    fromEmail: currentUserEmail,
                    to: recipientUserId,
                    toEmail: trimmed,
                    progressItemId: progressItemId,
                    progressItemTitle: progressItemTitle
                )
                print("Invitation sent successfully")

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
                let errMsg = error.localizedDescription
                print("Error sending invitation: \(errMsg)")
                print("Full error: \(error)")
                await MainActor.run {
                    isLoading = false
                    // Provide user-friendly error message
                    if errMsg.contains("already exists") {
                        errorMessage = "You already sent an invitation to this user for this progress."
                    } else {
                        errorMessage = errMsg
                    }
                }
            }
        }
    }

    private func lookupUserByEmail(_ email: String) async throws -> String {
        let db = Firestore.firestore()
        let snapshot = try await db.collection("users")
            .whereField("email", isEqualTo: email)
            .limit(to: 1)
            .getDocuments()

        guard let document = snapshot.documents.first else {
            throw NSError(domain: "UserNotFound", code: 404, userInfo: [NSLocalizedDescriptionKey: "User with email \(email) not found"])
        }

        return document.documentID
    }
}

#Preview {
    SendInvitationSheet(
        progressItemId: "test123",
        progressItemTitle: "My Progress",
        currentUserId: "user123",
        currentUserEmail: "user@example.com"
    )
    .environment(InvitationViewModel())
}
