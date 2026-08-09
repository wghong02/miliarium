import SwiftUI
import FirebaseFirestore

/// Sheet that opens from the "All activities" row at the top of the home
/// tab's collections list. Shows every activity for the progress regardless
/// of collection membership — including activities that belong to zero
/// collections.
///
/// This is a **virtual** view: there is no Firestore document backing it.
/// The list is materialised in-memory from the activities listener, sorted
/// newest first.
///
/// **Differences vs. `CollectionDetailView`**
/// - No "Edit details" row (nothing to edit — "All" isn't a real collection).
/// - No swipe-to-remove (membership is implicit — every activity is in All).
/// - Empty state copy is tuned for a brand-new progress.
struct AllActivitiesView: View {
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var activities: [Activity] = []
    @State private var activitiesListener: ListenerRegistration?
    @State private var editingActivity: Activity?
    @State private var showCreateActivity = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// Newest first.
    private var sortedActivities: [Activity] {
        activities.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && activities.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activities.isEmpty {
                    ContentUnavailableView {
                        Label("No activities yet", systemImage: "tray")
                    } description: {
                        Text("Tap + to add your first activity.")
                    }
                } else {
                    activityList
                }
            }
            .navigationTitle("All activities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateActivity = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add activity")
                }
            }
            .onAppear { setUpListener() }
            .onDisappear { tearDownListener() }
            .sheet(isPresented: $showCreateActivity) {
                CreateActivitySheet(progressItemId: progressItemId)
            }
            .sheet(item: $editingActivity) { activity in
                EditActivitySheet(
                    activity: activity,
                    progressItemId: progressItemId
                ) {
                    editingActivity = nil
                }
            }
        }
    }

    // MARK: - List

    private var activityList: some View {
        List {
            Section {
                ForEach(sortedActivities) { activity in
                    ActivityMemberRow(activity: activity)
                        .contentShape(Rectangle())
                        .onTapGesture { editingActivity = activity }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deleteActivity(activity) }
                            } label: {
                                Text("Delete")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Activities")
                    Spacer()
                    Text("\(sortedActivities.count)")
                        .font(.caption)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Tap a row to edit. Swipe left to delete.")
                    .font(.caption2)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Listener

    private func setUpListener() {
        isLoading = true
        activitiesListener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.activities = fetched
            self.isLoading = false
        }
    }

    private func tearDownListener() {
        activitiesListener?.remove()
        activitiesListener = nil
    }

    // MARK: - Actions

    /// Permanently deletes the activity from the progress (and from every
    /// collection it belonged to, in one atomic batch). The activities
    /// listener refreshes the list automatically.
    private func deleteActivity(_ activity: Activity) async {
        do {
            try await activityService.deleteActivity(activity, progressItemId: progressItemId)
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }
}
