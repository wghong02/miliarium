import SwiftUI
import FirebaseFirestore

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
                // Look up the recipient by email — the only thing we need
                // from the user collection is their `userId`. Display
                // strings are resolved live elsewhere.
                let recipientUserId = try await lookupUserByEmail(trimmed)

                try await invitationService.sendInvitation(
                    from: currentUserId,
                    to: recipientUserId,
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
                let errMsg = error.localizedDescription
                await MainActor.run {
                    isLoading = false
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
        currentUserId: "user123"
    )
    .environment(InvitationViewModel())
}
