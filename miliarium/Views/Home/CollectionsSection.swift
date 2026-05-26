import SwiftUI
import FirebaseFirestore

/// Home-tab section that lists all `ActivityCollection`s for the selected
/// progress item, with a `+` menu (add activity / add collection) and
/// swipe-to-delete on non-default rows. Listener resets on `progressItemId`
/// change so collections stay scoped to the active progress.
struct CollectionsSection: View {
    let progressItemId: String

    @State private var collections: [ActivityCollection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var showCreateCollection = false
    @State private var showCreateActivity = false
    @State private var showOnlyFavorites = false
    /// The collection whose detail sheet is currently open. Hoisted here so
    /// SwiftUI only manages one sheet per view tree branch (sheets inside
    /// ForEach/List rows are unreliable).
    @State private var detailCollection: ActivityCollection?
    /// Drives the "All activities" virtual-view sheet — a synthetic row at
    /// the top of the list shows every activity for the progress regardless
    /// of collection membership.
    @State private var showAllActivities = false

    private var visibleCollections: [ActivityCollection] {
        let filtered = showOnlyFavorites
            ? collections.filter { $0.isFavorite }
            : collections
        // Favorites first, then created order.
        return filtered.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Approximate min-height for the list so it doesn't snap to zero when
    /// empty. Counts the synthetic "All activities" row plus either the
    /// empty-state row or each visible collection row, then caps at the
    /// outer `maxHeight`.
    private var rowsHeightEstimate: CGFloat {
        let allRow: CGFloat = showOnlyFavorites ? 0 : 60
        let bodyRows: CGFloat = visibleCollections.isEmpty
            ? 60
            : CGFloat(visibleCollections.count) * 60
        return min(allRow + bodyRows, 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()

            filterRow
                .padding(.horizontal)
                .padding(.vertical, 8)

            List {
                if !showOnlyFavorites {
                    AllActivitiesRowView(onTap: { showAllActivities = true })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if visibleCollections.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text(showOnlyFavorites ? "No favorite collections" : "No collections yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Tap + to create one")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(visibleCollections) { collection in
                        CollectionRowView(
                            collection: collection,
                            progressItemId: progressItemId,
                            onTap: { detailCollection = collection },
                            onDelete: {
                                Task { await deleteCollection(collection) }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .frame(
                minHeight: rowsHeightEstimate,
                maxHeight: 280
            )

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
        }
        .sheet(item: $detailCollection) { collection in
            CollectionDetailView(
                collection: collection,
                progressItemId: progressItemId
            ) {
                detailCollection = nil
            }
        }
        .sheet(isPresented: $showAllActivities) {
            AllActivitiesView(progressItemId: progressItemId) {
                showAllActivities = false
            }
        }
        .sheet(isPresented: $showCreateCollection) {
            CreateCollectionSheet(progressItemId: progressItemId) {
                Task { await refreshCollections() }
            }
        }
        .sheet(isPresented: $showCreateActivity) {
            CreateActivitySheet(progressItemId: progressItemId) {
                Task { await refreshCollections() }
            }
        }
        .onAppear {
            if !listenerInitialized {
                setUpListener()
                listenerInitialized = true
            }
        }
        .onDisappear {
            listener?.remove()
            listenerInitialized = false
        }
        .onChange(of: progressItemId) { _, _ in
            listener?.remove()
            listenerInitialized = false
            collections = []
            setUpListener()
            listenerInitialized = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Collections")
                .font(.headline)
            Spacer()
            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Menu {
                    Button {
                        showCreateActivity = true
                    } label: {
                        Label("Add activity", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showCreateCollection = true
                    } label: {
                        Label("Add collection", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.headline)
                }
                .foregroundStyle(.blue)
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            FilterButton(
                label: "All",
                isSelected: !showOnlyFavorites,
                action: { showOnlyFavorites = false }
            )
            FilterButton(
                label: "Favorites",
                isSelected: showOnlyFavorites,
                action: { showOnlyFavorites = true }
            )
            Spacer()
        }
        .font(.caption)
    }

    // MARK: - Data

    private func setUpListener() {
        isLoading = true
        listener = activityCollectionService.setCollectionsListener(for: progressItemId) { fetched in
            self.collections = fetched
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func refreshCollections() async {
        isLoading = true
        do {
            let fresh = try await activityCollectionService.fetchCollections(for: progressItemId)
            await MainActor.run {
                self.collections = fresh
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func deleteCollection(_ collection: ActivityCollection) async {
        do {
            try await activityCollectionService.deleteCollection(collection, progressItemId: progressItemId)
            await refreshCollections()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

struct CollectionRowView: View {
    let collection: ActivityCollection
    let progressItemId: String
    var onTap: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var isTogglingFavorite = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: collection.isFavorite ? "star.fill" : "star")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(collection.isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(isTogglingFavorite)

            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(statsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.systemBackground).opacity(0.5))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Text("Delete")
            }
        }
    }

    private func toggleFavorite() async {
        isTogglingFavorite = true
        defer { isTogglingFavorite = false }
        try? await activityCollectionService.updateCollection(
            collection,
            progressItemId: progressItemId,
            isFavorite: !collection.isFavorite
        )
    }

    private var statsLine: String {
        let total = collection.stats.total
        let activityWord = total == 1 ? "activity" : "activities"
        var pieces: [String] = ["\(total) \(activityWord)"]

        if collection.stats.locationCount > 0 {
            pieces.append("\(collection.stats.locationCount) with location")
        }
        if let lastAt = collection.stats.lastAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            pieces.append("last \(formatter.localizedString(for: lastAt, relativeTo: Date()))")
        }
        if collection.statsUpdatedAt == nil && total == 0 {
            pieces = ["Tap to add activities"]
        }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - All activities row

/// Synthetic row pinned to the top of the collections list. Tapping it
/// opens `AllActivitiesView`, which lists every activity for the progress
/// regardless of collection membership. Not backed by a Firestore doc.
private struct AllActivitiesRowView: View {
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("All activities")
                    .font(.subheadline.weight(.semibold))
                Text("Every activity in this progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.systemBackground).opacity(0.5))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - FilterButton

/// Pill-style filter chip used across the home tab sections.
struct FilterButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(4)
        }
    }
}
