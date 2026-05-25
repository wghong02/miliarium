import SwiftUI
import FirebaseAuth

struct HomeSectionView: View {
    @Environment(ProgressStore.self) private var progressStore
    @Environment(InvitationViewModel.self) private var invitationVM
    @Environment(AuthViewModel.self) private var authVM

    @State private var showCreateProgress = false
    @State private var showDeleteConfirmation = false
    @State private var showSendInvitation = false
    @State private var showEditSummary = false
    @State private var progressToDelete: String?
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var currentUserId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
            }
            .onAppear {
                currentUserId = authVM.user?.uid
            }
            .onChange(of: authVM.user?.uid) { _, newValue in
                currentUserId = newValue
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
                if item.content.summary.isEmpty && item.content.body.isEmpty {
                    Text("No content yet. Edit this progress to add a summary or notes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                UpcomingEventsView(progressItemId: id)

                CollectionsSection(progressItemId: id)

                if progressStore.isOwner(of: item.id) {
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
