import SwiftUI
import FirebaseFirestore

/// Minimal form for creating a new `ActivityCollection`. Step 1 of the UI
/// redesign — listing of member activities lives in a separate detail view
/// that we'll wire up alongside the activity create/edit sheet.
struct CreateCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    var onCollectionCreated: () -> Void = {}

    @State private var name = ""
    @State private var notes = ""
    @State private var isFavourite = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Details") {
                    TextField("Collection name", text: $name)
                        .textInputAutocapitalization(.sentences)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...4)
                }

                Section {
                    Toggle("Mark as favourite", isOn: $isFavourite)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: createCollection) {
                        if isCreating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Create Collection")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(trimmedName.isEmpty || isCreating)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func createCollection() {
        guard !trimmedName.isEmpty else { return }
        isCreating = true
        errorMessage = nil

        Task {
            do {
                _ = try await activityCollectionService.createCollection(
                    progressItemId: progressItemId,
                    name: trimmedName,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFavourite: isFavourite,
                    isDefault: false
                )

                await MainActor.run {
                    isCreating = false
                    onCollectionCreated()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Editable sheet for an existing collection. Shows metadata (name, notes,
/// favourite), a "Refresh stats" action, and delete (hidden for default).
struct EditCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let collection: ActivityCollection
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var isFavourite: Bool = false
    @State private var isUpdating = false
    @State private var isRefreshingStats = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var currentStats: ActivityCollectionStats = .empty
    @State private var lastStatsUpdate: Date?

    // Activity listing
    @State private var allActivities: [Activity] = []
    @State private var memberActivityIds: Set<String> = []
    @State private var activitiesListener: ListenerRegistration?
    @State private var activitiesListenerInitialized = false
    @State private var editingActivity: Activity?

    private var memberActivities: [Activity] {
        allActivities
            .filter { memberActivityIds.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection Details") {
                    TextField("Collection name", text: $name)
                        .textInputAutocapitalization(.sentences)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(2...4)
                }

                Section {
                    Toggle("Mark as favourite", isOn: $isFavourite)
                }

                Section("Stats") {
                    LabeledContent("Total") { Text("\(currentStats.total)") }
                    LabeledContent("Completed") { Text("\(currentStats.completedCount)") }
                    LabeledContent("With time") { Text("\(currentStats.timeCount)") }
                    LabeledContent("With location") { Text("\(currentStats.locationCount)") }
                    if let firstAt = currentStats.firstAt {
                        LabeledContent("First") { Text(firstAt.formatted(date: .abbreviated, time: .omitted)) }
                    }
                    if let lastAt = currentStats.lastAt {
                        LabeledContent("Last") { Text(lastAt.formatted(date: .abbreviated, time: .omitted)) }
                    }
                    LabeledContent("Updated") {
                        Text(lastStatsUpdate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    }

                    Button(action: refreshStats) {
                        HStack {
                            if isRefreshingStats {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh stats")
                        }
                    }
                    .disabled(isRefreshingStats)
                }

                activitiesSection

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: updateCollection) {
                        if isUpdating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Update Collection")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(trimmedName.isEmpty || isUpdating)
                }

                if !collection.isDefault {
                    Section {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Text("Delete")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle("Edit Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = collection.name
                notes = collection.notes ?? ""
                isFavourite = collection.isFavourite
                currentStats = collection.stats
                lastStatsUpdate = collection.statsUpdatedAt
                memberActivityIds = Set(collection.activityIds)
                if !activitiesListenerInitialized {
                    setUpActivitiesListener()
                    activitiesListenerInitialized = true
                }
            }
            .onDisappear {
                activitiesListener?.remove()
                activitiesListenerInitialized = false
            }
            .sheet(item: $editingActivity) { activity in
                EditActivitySheet(
                    activity: activity,
                    progressItemId: progressItemId
                ) {
                    editingActivity = nil
                    Task { await refreshMembership() }
                }
            }
            .alert("Delete Collection?", isPresented: $showDeleteAlert) {
                Button("Cancel") {
                    showDeleteAlert = false
                }
                Button("Delete", role: .cancel) {
                    Task { await deleteCollection() }
                }
            } message: {
                Text("Activities in this collection won't be deleted, but they'll lose their membership in it.")
            }
        }
    }

    private func updateCollection() {
        guard !trimmedName.isEmpty else { return }
        isUpdating = true
        errorMessage = nil

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesParam: String?? = cleanedNotes.isEmpty ? .some(nil) : .some(cleanedNotes)

        Task {
            do {
                try await activityCollectionService.updateCollection(
                    collection,
                    progressItemId: progressItemId,
                    name: trimmedName,
                    notes: notesParam,
                    isFavourite: isFavourite
                )
                await MainActor.run {
                    isUpdating = false
                    onDismiss()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isUpdating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshStats() {
        isRefreshingStats = true
        errorMessage = nil

        Task {
            do {
                let updated = try await activityCollectionService.refreshStats(
                    for: collection,
                    progressItemId: progressItemId
                )
                await MainActor.run {
                    currentStats = updated.stats
                    lastStatsUpdate = updated.statsUpdatedAt
                    isRefreshingStats = false
                }
            } catch {
                await MainActor.run {
                    isRefreshingStats = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteCollection() async {
        do {
            try await activityCollectionService.deleteCollection(collection, progressItemId: progressItemId)
            await MainActor.run {
                onDismiss()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Activities

    @ViewBuilder
    private var activitiesSection: some View {
        Section {
            if memberActivities.isEmpty {
                Text("No activities in this collection yet.")
                    .font(.caption)
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
                Text("\(memberActivities.count)")
                    .font(.caption)
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !memberActivities.isEmpty {
                Text("Swipe a row to remove it from this collection (the activity itself isn't deleted).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setUpActivitiesListener() {
        activitiesListener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.allActivities = fetched
        }
    }

    /// Re-reads the collection doc to refresh `memberActivityIds` after an
    /// edit in the activity sheet may have changed the activity's collection
    /// membership.
    private func refreshMembership() async {
        do {
            if let fresh = try await activityCollectionService
                .fetchCollection(id: collection.id, for: progressItemId) {
                await MainActor.run {
                    memberActivityIds = Set(fresh.activityIds)
                }
            }
        } catch {
            // Best-effort refresh — keep the local set if the fetch fails.
        }
    }

    private func removeFromCollection(_ activity: Activity) async {
        do {
            try await activityService.removeActivity(
                activity.id,
                fromCollection: collection.id,
                progressItemId: progressItemId
            )
            await MainActor.run {
                memberActivityIds.remove(activity.id)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Activity row used inside EditCollectionSheet

private struct ActivityMemberRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let notes = activity.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            dimensionIcons
        }
    }

    private var dimensionIcons: some View {
        HStack(spacing: 6) {
            if activity.hasTime {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.blue)
            }
            if activity.hasLocation {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.red)
            }
            if let completed = activity.isCompleted {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(completed ? .green : .gray)
            }
        }
        .font(.caption)
    }
}

#Preview {
    CreateCollectionSheet(progressItemId: "test123")
}
