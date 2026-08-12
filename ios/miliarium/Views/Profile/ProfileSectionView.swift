import SwiftUI
import FirebaseAuth

struct ProfileSectionView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(OnboardingState.self) private var onboardingState
    @Environment(MemorySettings.self) private var memorySettings

    @State private var appUser: AppUser?
    @State private var name = ""
    @State private var initialName = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showSavedConfirmation = false
    @State private var showDeleteAccount = false
    @State private var deletePassword = ""
    @State private var isDeletingAccount = false
    @State private var blockedUsers: [AppUser] = []
    @State private var blockedUserIds: [String] = []
    @State private var showMemories = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != initialName
    }

    var body: some View {
        NavigationStack {
            List {
                accountSection
                nameSection
                memoriesSection
                helpSection
                legalSection
                blockedSection
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
                deleteAccountSection
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showMemories) {
                MemoriesView()
            }
            .task {
                await loadProfile()
                await loadBlockedUsers()
            }
            .alert("Delete account?", isPresented: $showDeleteAccount) {
                SecureField("Password", text: $deletePassword)
                    .textContentType(.password)
                Button("Cancel", role: .cancel) { deletePassword = "" }
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("This permanently deletes your account and can't be undone. Enter your password to confirm.")
            }
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
            HStack {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                    .disabled(isLoading || isSaving)
                    .onChange(of: name) { _, newValue in
                        // Enforce the cap silently as the user types;
                        // truncate any excess (e.g. from paste).
                        if newValue.count > TextLimits.name {
                            name = String(newValue.prefix(TextLimits.name))
                        }
                    }

                Button {
                    Task { await saveName() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else if showSavedConfirmation {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!hasChanges || isSaving || isLoading)
            }
        } header: {
            HStack {
                Text("Display name")
                Spacer()
                CharacterCounter(count: name.count, limit: TextLimits.name)
            }
        }
    }

    private var helpSection: some View {
        Section {
            Button {
                onboardingState.resetOnboarding()
            } label: {
                HStack {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.blue)
                    Text("Show tutorial again")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Help")
        } footer: {
            Text("Resets the welcome sheet and the per-tab hint banners so they appear again.")
        }
    }

    private var memoriesSection: some View {
        Section {
            Toggle("Weekly recap", isOn: Binding(
                get: { memorySettings.isEnabled },
                set: { memorySettings.isEnabled = $0 }
            ))
            if memorySettings.isEnabled {
                Picker("Day", selection: Binding(
                    get: { memorySettings.weekday },
                    set: { memorySettings.weekday = $0 }
                )) {
                    ForEach(1...7, id: \.self) { w in
                        Text(Foundation.Calendar.current.weekdaySymbols[w - 1]).tag(w)
                    }
                }
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { memorySettings.timeAsDate },
                        set: { memorySettings.setTime(from: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                NotificationsDisabledNote()
            }
            Button {
                showMemories = true
            } label: {
                Label("View this week's memories", systemImage: "sparkles")
            }
        } header: {
            Text("Memories")
        } footer: {
            Text("A weekly summary of the past 7 days, with a notification at the set time. It also appears automatically the first time you open the app after then.")
        }
    }

    private var legalSection: some View {
        Section {
            Link(destination: Legal.termsURL) {
                Label("Terms of Use", systemImage: "doc.text")
            }
            Link(destination: Legal.privacyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            if let supportURL = URL(string: "mailto:\(Legal.supportEmail)") {
                Link(destination: supportURL) {
                    Label("Contact support", systemImage: "envelope")
                }
            }
        } header: {
            Text("Legal & Support")
        } footer: {
            Text("Miliarium has zero tolerance for objectionable content or abusive behavior. Report content or block a user from the invitation they sent you.")
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        if !blockedUserIds.isEmpty {
            Section {
                ForEach(blockedUserIds, id: \.self) { id in
                    HStack {
                        Text(blockedDisplayName(for: id))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Unblock") {
                            Task { await unblock(id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Blocked users")
            } footer: {
                Text("You won't see invitations or content from blocked users.")
            }
        }
    }

    private var deleteAccountSection: some View {
        Section {
            Button(role: .destructive) {
                deletePassword = ""
                showDeleteAccount = true
            } label: {
                if isDeletingAccount {
                    ProgressView()
                } else {
                    Text("Delete account")
                }
            }
            .disabled(isDeletingAccount)
        } footer: {
            Text("Permanently deletes your account and profile. This can't be undone.")
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

    private func loadBlockedUsers() async {
        guard let uid = auth.user?.uid else { return }
        do {
            let ids = try await moderationService.fetchBlockedUserIds(for: uid)
            blockedUserIds = ids
            blockedUsers = ids.isEmpty ? [] : (try? await userService.fetchUsers(ids: ids)) ?? []
        } catch {
            // Best-effort; the section just stays empty on failure.
        }
    }

    private func unblock(_ id: String) async {
        guard let uid = auth.user?.uid else { return }
        do {
            try await moderationService.unblockUser(id, by: uid)
            await loadBlockedUsers()
        } catch {
            errorMessage = "Couldn't unblock: \(error.localizedDescription)"
        }
    }

    private func blockedDisplayName(for id: String) -> String {
        blockedUsers.first(where: { $0.id == id })?.displayString ?? id
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

    private func deleteAccount() async {
        guard !deletePassword.isEmpty else {
            errorMessage = "Enter your password to delete your account."
            return
        }
        isDeletingAccount = true
        errorMessage = nil
        let ok = await auth.deleteAccount(password: deletePassword)
        deletePassword = ""
        isDeletingAccount = false
        // On success the auth-state listener sets `user` to nil and the auth
        // gate returns to the login screen, so this view goes away. On
        // failure, surface the reason inline.
        if !ok {
            errorMessage = auth.errorMessage ?? "Couldn't delete your account."
        }
    }
}
