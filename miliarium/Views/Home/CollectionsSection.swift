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

    private var visibleCollections: [ActivityCollection] {
        let filtered = showOnlyFavorites
            ? collections.filter { $0.isFavorite }
            : collections
        // Favorites first, then default, then created order.
        return filtered.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()

            filterRow
                .padding(.horizontal)
                .padding(.vertical, 8)

            if visibleCollections.isEmpty {
                VStack(spacing: 8) {
                    Text(showOnlyFavorites ? "No favorite collections" : "No collections yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to create one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                List {
                    ForEach(visibleCollections) { collection in
                        CollectionRowView(
                            collection: collection,
                            progressItemId: progressItemId,
                            onDelete: {
                                Task { await deleteCollection(collection) }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .frame(
                    minHeight: min(CGFloat(visibleCollections.count) * 60, 240),
                    maxHeight: 240
                )
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
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
        print("[CollectionsSection] Setting up listener for progress: \(progressItemId)")
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
    var onDelete: () -> Void = {}

    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
            // Favorite / default indicator
            Image(systemName: leadingIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(leadingColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(collection.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if collection.isDefault {
                        Text("default")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)
                    }
                }
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
        .onTapGesture {
            isEditing = true
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !collection.isDefault {
                Button(role: .destructive, action: onDelete) {
                    Text("Delete")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            EditCollectionSheet(
                collection: collection,
                progressItemId: progressItemId
            ) {
                isEditing = false
            }
        }
    }

    private var leadingIcon: String {
        if collection.isFavorite { return "star.fill" }
        return "folder.fill"
    }

    private var leadingColor: Color {
        if collection.isFavorite { return .yellow }
        return .blue
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
