import SwiftUI
import FirebaseAuth

struct HomeSectionView: View {
    @Environment(ProgressStore.self) private var progressStore
    @Environment(InvitationViewModel.self) private var invitationVM
    @Environment(AuthViewModel.self) private var authVM
    @Environment(OnboardingState.self) private var onboardingState

    @State private var showCreateProgress = false
    @State private var showDeleteConfirmation = false
    @State private var showSendInvitation = false
    @State private var showEditSummary = false
    @State private var showAddActivity = false
    @State private var progressToDelete: String?
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var currentUserId: String?

    /// The current onboarding step, recomputed on every render from the
    /// live counts the `OnboardingState` listeners maintain.
    private var tutorialStep: TutorialStep {
        onboardingState.currentStep(progressCount: progressStore.progresses.count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Tutorial banner sits above everything else so it's
                    // visible during the empty-progresses state too — that's
                    // when the "create your first progress" step needs to
                    // surface most.
                    //
                    // No `.transition` and no `.animation(value:)` here:
                    // both can cause a flash on tab switches when SwiftUI
                    // re-evaluates the view tree. The banner appears /
                    // disappears instantly when state actually changes
                    // (dismiss, step auto-advance), which is acceptable for
                    // a one-time tutorial cue.
                    if tutorialStep != .done {
                        TutorialBanner(step: tutorialStep) {
                            onboardingState.dismissTutorial()
                        }
                    }

                    Group {
                        if progressStore.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if progressStore.progresses.isEmpty {
                            ContentUnavailableView {
                                Label("No progress yet", systemImage: "chart.line.uptrend.xyaxis")
                            } description: {
                                Text("Open the Progress menu above or tap below to create one.")
                            } actions: {
                                Button("Create progress") {
                                    showCreateProgress = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            homeContent
                        }
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    progressMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only meaningful when a progress is selected — without
                    // one we have no `progressItemId` to hand the sheet.
                    if let id = progressStore.selectedProgressId,
                       progressStore.progresses.contains(where: { $0.id == id }) {
                        Button(action: { showAddActivity = true }) {
                            Image(systemName: "doc.badge.plus")
                        }
                        .accessibilityLabel("Add activity")
                    }
                }
            }
            .onAppear {
                currentUserId = authVM.user?.uid
                onboardingState.updateForActiveProgress(progressStore.selectedProgressId)
                // If ProgressStore has already completed its initial load
                // by the time this view appears (e.g. user re-navigated to
                // Home after the data was fetched), mark initialized now
                // so the tutorial banner's gate evaluates correctly on the
                // very first render.
                if !progressStore.isLoading && authVM.user != nil {
                    onboardingState.markProgressesInitialized()
                }
            }
            .onChange(of: authVM.user?.uid) { _, newValue in
                currentUserId = newValue
            }
            .onChange(of: progressStore.selectedProgressId) { _, newId in
                // Re-target the onboarding listeners at the new progress
                // so step detection (collectionCount / activityCount)
                // reflects whichever progress is currently selected.
                onboardingState.updateForActiveProgress(newId)
            }
            // Watch ProgressStore loading state so the tutorial banner
            // doesn't flash during the brief window when `progresses` is
            // still its default empty array. We only mark initialized
            // when loading completes — at that point we've definitively
            // heard back from Firestore, even if the user has zero
            // progresses (in which case showing step 1 is correct).
            .onChange(of: progressStore.isLoading) { oldValue, newValue in
                if oldValue == true && newValue == false {
                    onboardingState.markProgressesInitialized()
                }
            }
            .sheet(isPresented: $showCreateProgress) {
                CreateProgressSheet { title in
                    await progressStore.createProgress(title: title)
                }
            }
            .sheet(isPresented: $showSendInvitation) {
                if let id = progressStore.selectedProgressId,
                   let item = progressStore.progresses.first(where: { $0.id == id }),
                   let userId = currentUserId {
                    SendInvitationSheet(
                        progressItemId: id,
                        progressItemTitle: item.title,
                        currentUserId: userId
                    )
                }
            }
            .sheet(isPresented: $showEditSummary) {
                if let id = progressStore.selectedProgressId,
                   let item = progressStore.progresses.first(where: { $0.id == id }) {
                    EditSummarySheet(
                        progressId: id,
                        initialSummary: item.content.summary
                    ) {
                        showEditSummary = false
                    }
                }
            }
            .sheet(isPresented: $showAddActivity) {
                // Matches the Map tab's "+" button: no pre-filled fields.
                // The Collections section's own "+" menu is unchanged and
                // remains an alternate entry point for the same sheet.
                if let id = progressStore.selectedProgressId {
                    CreateActivitySheet(progressItemId: id)
                }
            }
            .confirmationDialog(
                "Delete Progress?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteSelectedProgress()
                }
                Button("Cancel", role: .cancel) {
                    progressToDelete = nil
                }
            } message: {
                Text("This action cannot be undone. The progress item and all associated data will be permanently deleted.")
            }
            .alert("Delete Failed", isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { deleteErrorMessage = nil }
            } message: {
                Text(deleteErrorMessage ?? "")
            }
        }
    }

    private var progressMenu: some View {
        Menu {
            if progressStore.progresses.isEmpty {
                Button("Create progress…") {
                    showCreateProgress = true
                }
            } else {
                Picker(
                    "Progress",
                    selection: Binding(
                        get: { progressStore.selectedProgressId },
                        set: { progressStore.selectProgress(id: $0) }
                    )
                ) {
                    ForEach(progressStore.progresses) { item in
                        Text(item.title).tag(Optional.some(item.id))
                    }
                }
                Divider()
                Button("Create progress…") {
                    showCreateProgress = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.fill")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Choose progress")
    }

    @ViewBuilder
    private var homeContent: some View {
        if let id = progressStore.selectedProgressId,
           let item = progressStore.progresses.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))

                    Spacer()

                    if progressStore.isOwner(of: item.id) {
                        Button(action: { showEditSummary = true }) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !item.content.summary.isEmpty {
                    Text(item.content.summary)
                        .font(.body)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
                if !item.content.body.isEmpty {
                    Text(item.content.body)
                        .font(.body)
                }

                Spacer()

                UpcomingActivityView(progressItemId: id)

                // Collections spans the full screen width — cancels the
                // parent ScrollView's `.padding(.horizontal)` so the section
                // (divider, rows, swipe actions) reaches edge-to-edge. The
                // section's own internal `header`/`filterRow` padding still
                // keeps text inset from the edges.
                CollectionsSection(progressItemId: id)

                if progressStore.isOwner(of: item.id) {
                    sharingSection

                    deleteProgressSection(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView(
                "Choose a progress",
                systemImage: "chevron.down.circle",
                description: Text("Pick one from the menu above.")
            )
        }
    }

    @ViewBuilder
    private var invitedUsersPanel: some View {
        if let id = progressStore.selectedProgressId,
           let item = progressStore.progresses.first(where: { $0.id == id }),
           progressStore.isOwner(of: id) {
            InvitedUsersPanelView(progressItemId: id, progressItemTitle: item.title)
        }
    }

    /// Owner-only "Sharing" group: section header + Send Invitation button +
    /// invited users panel. The leading `Divider` + section title separate
    /// this block from the Collections section above.
    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.top, 4)

            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.blue)
                Text("Sharing")
                    .font(.headline)
                Spacer()
            }

            Button {
                showSendInvitation = true
            } label: {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("Send Invitation")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            invitedUsersPanel
        }
    }

    /// Owner-only Delete Progress button, separated from the Sharing block
    /// above by just a divider (no header — the trash icon + red tint say
    /// enough on their own).
    @ViewBuilder
    private func deleteProgressSection(item: ProgressItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.top, 4)

            Button(role: .destructive) {
                progressToDelete = item.id
                showDeleteConfirmation = true
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .tint(.red)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text("Delete Progress")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isDeleting)
        }
    }

    private func deleteSelectedProgress() {
        guard let progressId = progressToDelete else { return }

        isDeleting = true
        deleteErrorMessage = nil

        Task {
            let success = await progressStore.deleteProgress(progressId: progressId)

            await MainActor.run {
                isDeleting = false
                if success {
                    progressToDelete = nil
                } else {
                    deleteErrorMessage = progressStore.errorMessage ?? "Couldn't delete progress. Please try again."
                }
            }
        }
    }
}
