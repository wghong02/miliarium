import SwiftUI
import FirebaseFirestore

/// Outer wrapper for the Map tab. Owns the **collection filter** in the
/// top-left toolbar; defers progress switching to the Home tab (the
/// selected progress is shared app-wide via `ProgressStore`). The
/// collections list is also passed down to `MapView` so the per-pin
/// "add to collection" menu doesn't need to keep its own listener.
struct ExploreSectionView: View {
    @Environment(ProgressStore.self) private var progressStore

    @State private var collections: [ActivityCollection] = []
    @State private var collectionsListener: ListenerRegistration?
    @State private var selectedCollectionId: String?

    var body: some View {
        NavigationStack {
            Group {
                if progressStore.progresses.isEmpty {
                    ContentUnavailableView {
                        Label("No progress yet", systemImage: "map.fill")
                    } description: {
                        Text("Create a progress item in the Home tab to map your activities.")
                    }
                } else if let selectedId = progressStore.selectedProgressId,
                          let selectedItem = progressStore.progresses.first(where: { $0.id == selectedId }) {
                    MapView(
                        progressItemId: selectedId,
                        progressTitle: selectedItem.title,
                        collections: collections,
                        selectedCollectionId: selectedCollectionId
                    )
                } else {
                    ContentUnavailableView(
                        "Choose a progress",
                        systemImage: "chevron.down.circle",
                        description: Text("Select a progress from the Home tab to view its map.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    collectionFilterMenu
                }
            }
            .onAppear {
                if collectionsListener == nil,
                   let progressId = progressStore.selectedProgressId {
                    setUpCollectionsListener(progressId: progressId)
                }
            }
            .onDisappear {
                tearDownCollectionsListener()
            }
            .onChange(of: progressStore.selectedProgressId) { _, newId in
                tearDownCollectionsListener()
                collections = []
                selectedCollectionId = nil
                if let newId {
                    setUpCollectionsListener(progressId: newId)
                }
            }
        }
    }

    // MARK: - Filter menu

    private var collectionFilterMenu: some View {
        Menu {
            Button("All collections") { selectedCollectionId = nil }
            if !collections.isEmpty {
                Divider()
                ForEach(collections) { collection in
                    Button(collection.name) { selectedCollectionId = collection.id }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Filter by collection")
    }

    // MARK: - Collections listener

    private func setUpCollectionsListener(progressId: String) {
        collectionsListener = activityCollectionService.setCollectionsListener(for: progressId) { fetched in
            Task { @MainActor in
                self.collections = fetched
                if let selected = self.selectedCollectionId,
                   !fetched.contains(where: { $0.id == selected }) {
                    self.selectedCollectionId = nil
                }
            }
        }
    }

    private func tearDownCollectionsListener() {
        collectionsListener?.remove()
        collectionsListener = nil
    }
}
