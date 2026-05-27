import SwiftUI

/// Form for creating a new `ActivityCollection`. Pure metadata input — the
/// list of member activities is owned by `CollectionDetailView`, which is
/// opened by tapping a collection row on the Home tab.
struct CreateCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    var onCollectionCreated: () -> Void = {}

    @State private var name = ""
    @State private var notes = ""
    @State private var isFavorite = false
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
                    Toggle("Mark as favorite", isOn: $isFavorite)
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
                    isFavorite: isFavorite
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
/// favorite), a "Refresh stats" action, and delete (hidden for default).
///
/// Opened from the "Edit details" row inside `CollectionDetailView`. The
/// activity list itself is intentionally NOT shown here — that's the detail
/// view's job. Keeping the two concerns separate avoids holding two parallel
/// activity listeners against the same data.
struct EditCollectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let collection: ActivityCollection
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var isFavorite: Bool = false
    @State private var isUpdating = false
    @State private var isRefreshingStats = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    @State private var currentStats: ActivityCollectionStats = .empty
    @State private var lastStatsUpdate: Date?

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
                    Toggle("Mark as favorite", isOn: $isFavorite)
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

                Section {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Text("Delete")
                            .frame(maxWidth: .infinity)
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
                isFavorite = collection.isFavorite
                currentStats = collection.stats
                lastStatsUpdate = collection.statsUpdatedAt
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
                    isFavorite: isFavorite
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
}

// MARK: - Activity row (shared with CollectionDetailView)

struct ActivityMemberRow: View {
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
