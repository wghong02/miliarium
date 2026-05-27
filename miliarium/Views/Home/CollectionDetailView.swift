import SwiftUI
import FirebaseFirestore

/// Sheet that opens when the user taps a collection row.
///
/// Primary purpose: browse and manage the activities in the collection.
/// The top section is a single tappable "Edit details" row that opens
/// `EditCollectionSheet` for metadata changes (name, notes, favourite, stats,
/// delete). Keeping the two concerns separate means this sheet stays focused
/// on activities.
///
/// **Two real-time listeners**
/// - Activities listener: all activities for the progress item, filtered
///   in-memory to members of this collection.
/// - Collection listener: tracks the collection document so the title and
///   `activityIds` stay in sync without a manual refresh (e.g. after a
///   remove-from-collection on the Map tab).
struct CollectionDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let collection: ActivityCollection
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var currentCollection: ActivityCollection
    @State private var allActivities: [Activity] = []
    @State private var activitiesListener: ListenerRegistration?
    @State private var collectionListener: ListenerRegistration?
    @State private var editingActivity: Activity?
    @State private var showCreateActivity = false
    @State private var showEditCollection = false
    @State private var errorMessage: String?
    @State private var isLoadingActivities = true

    init(
        collection: ActivityCollection,
        progressItemId: String,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.collection = collection
        self.progressItemId = progressItemId
        self.onDismiss = onDismiss
        _currentCollection = State(initialValue: collection)
    }

    /// Activities that belong to this collection, newest first.
    private var memberActivities: [Activity] {
        let memberIds = Set(currentCollection.activityIds)
        return allActivities
            .filter { memberIds.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                editDetailsSection
                activitiesSection
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(currentCollection.name)
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
            .onAppear { setUpListeners() }
            .onDisappear { tearDownListeners() }
            .sheet(isPresented: $showEditCollection) {
                EditCollectionSheet(
                    collection: currentCollection,
                    progressItemId: progressItemId
                ) {
                    showEditCollection = false
                }
            }
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

    // MARK: - Sections

    /// A single tappable row that opens `EditCollectionSheet`.
    private var editDetailsSection: some View {
        Section {
            Button {
                showEditCollection = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit details")
                            .foregroundStyle(.primary)
                        if let notes = currentCollection.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var activitiesSection: some View {
        Section {
            if isLoadingActivities {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if memberActivities.isEmpty {
                Text("No activities in this collection yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(memberActivities) { activity in
                    ActivityMemberRow(activity: activity)
                        .contentShape(Rectangle())
                        .onTapGesture { editingActivity = activity }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await removeFromCollection(activity) }
                            } label: {
                                Text("Remove")
                            }
                        }
                }
            }
        } header: {
            HStack {
                Text("Activities")
                Spacer()
                if !isLoadingActivities {
                    Text("\(memberActivities.count)")
                        .font(.caption)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !memberActivities.isEmpty {
                Text("Swipe left on a row to remove it from this collection — the activity itself isn't deleted.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Listeners

    private func setUpListeners() {
        isLoadingActivities = true

        activitiesListener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.allActivities = fetched
            self.isLoadingActivities = false
        }

        // Keeps activityIds and the displayed name in sync automatically.
        collectionListener = activityCollectionService.setCollectionListener(
            id: collection.id,
            progressItemId: progressItemId
        ) { updated in
            if let updated {
                self.currentCollection = updated
            }
        }
    }

    private func tearDownListeners() {
        activitiesListener?.remove()
        activitiesListener = nil
        collectionListener?.remove()
        collectionListener = nil
    }

    // MARK: - Actions

    private func removeFromCollection(_ activity: Activity) async {
        do {
            try await activityService.removeActivity(
                activity.id,
                fromCollection: currentCollection.id,
                progressItemId: progressItemId
            )
            // The collection listener fires when activityIds changes,
            // causing memberActivities to recompute automatically.
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}
