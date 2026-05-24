import SwiftUI
import FirebaseAuth

struct ProfileSectionView: View {
    @Environment(AuthViewModel.self) private var auth

    @State private var appUser: AppUser?
    @State private var name = ""
    @State private var initialName = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSavedConfirmation = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != initialName
    }

    /// Live preview of what other users see when this user appears in an
    /// invitation or shared list. Matches the fallback logic in
    /// `AppUser.displayString`.
    private var displayPreview: String {
        if !trimmedName.isEmpty { return trimmedName }
        if let email = auth.user?.email, !email.isEmpty { return email }
        return "Unknown user"
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                nameSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .navigationTitle("Profile")
            .task { await loadProfile() }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            if let uid = auth.user?.uid {
                LabeledContent("User ID") {
                    Text(uid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let email = auth.user?.email {
                LabeledContent("Email", value: email)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Long-press the user ID to copy it.")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Your name", text: $name)
                .textInputAutocapitalization(.words)
                .disabled(isLoading || isSaving)

            Button {
                Task { await saveName() }
            } label: {
                HStack {
                    if isSaving {
                        ProgressView()
                    } else if showSavedConfirmation {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Save")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!hasChanges || isSaving || isLoading)
        } header: {
            Text("Display name")
        } footer: {
            Text("Shown in invitations and shared collaborations. Currently displays as: \(displayPreview).")
        }
    }

    // MARK: - Actions

    private func loadProfile() async {
        guard let uid = auth.user?.uid else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let user = try await userService.fetchUser(id: uid)
            appUser = user
            let resolved = user?.name ?? ""
            name = resolved
            initialName = resolved
        } catch {
            errorMessage = "Couldn't load profile: \(error.localizedDescription)"
        }
    }

    private func saveName() async {
        guard let uid = auth.user?.uid else { return }
        let nameToSave: String? = trimmedName.isEmpty ? nil : trimmedName

        isSaving = true
        errorMessage = nil

        do {
            try await userService.updateName(userId: uid, name: nameToSave)
            initialName = trimmedName
            isSaving = false
            showSavedConfirmation = true
            // Auto-clear the "Saved" badge after a short delay.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                showSavedConfirmation = false
            }
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
