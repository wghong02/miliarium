import SwiftUI
import FirebaseFirestore

/// Outer wrapper for the Map tab. Owns the **collection filter** in the
/// top-left toolbar; defers progress switching to the Home tab (the
/// selected progress is shared app-wide via `ProgressStore`). The
/// collections list is also passed down to `MapView` so the per-pin
/// "add to collection" menu doesn't need to keep its own listener.
struct ExploreSectionView: View {
    @Environment(ProgressStore.self) private var progressStore
    @Environment(OnboardingState.self) private var onboardingState

    @State private var collections: [ActivityCollection] = []
    @State private var collectionsListener: ListenerRegistration?
    @State private var showMapHintSheet = false
    /// Collection + completed/past filters, shared with `MapView` and driven
    /// by the shared `CollectionFilterMenu` in the toolbar.
    @State private var filter = ActivityFilter()

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
                        filter: filter
                    )
                } else {
                    ContentUnavailableView(
                        "Choose a progress",
                        systemImage: "chevron.down.circle",
                        description: Text("Select a progress from the Home tab to view its map.")
                    )
                }
            }
            // Modal hint sheet — slides up on first map visit. The
            // `presentationBackgroundInteraction(.enabled)` keeps the map
            // tappable behind the sheet at the small detent.
            .sheet(isPresented: $showMapHintSheet, onDismiss: {
                onboardingState.markMapHintSeen()
            }) {
                MapHintSheet {
                    onboardingState.markMapHintSeen()
                    showMapHintSheet = false
                }
                .presentationDetents([.fraction(0.35), .medium])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.35)))
                .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CollectionFilterMenu(collections: collections, filter: $filter)
                }
            }
            .onAppear {
                if collectionsListener == nil,
                   let progressId = progressStore.selectedProgressId {
                    setUpCollectionsListener(progressId: progressId)
                }
                // Auto-present the modal hint on the first Map visit per
                // device (or after the user resets onboarding from
                // Profile). Re-appears do nothing because the flag is
                // flipped in the sheet's onDismiss.
                if !onboardingState.hasSeenMapHint {
                    showMapHintSheet = true
                }
            }
            .onDisappear {
                tearDownCollectionsListener()
            }
            .onChange(of: progressStore.selectedProgressId) { _, newId in
                tearDownCollectionsListener()
                collections = []
                // Switching progress resets all three filters to defaults.
                filter = ActivityFilter()
                if let newId {
                    setUpCollectionsListener(progressId: newId)
                }
            }
        }
    }

    // MARK: - Collections listener

    private func setUpCollectionsListener(progressId: String) {
        collectionsListener = activityCollectionService.setCollectionsListener(for: progressId) { fetched in
            Task { @MainActor in
                self.collections = fetched
                // If the selected collection was deleted, drop the collection
                // filter back to "All" (the toggles are left untouched).
                if let selected = self.filter.collectionId,
                   !fetched.contains(where: { $0.id == selected }) {
                    self.filter.collectionId = nil
                }
            }
        }
    }

    private func tearDownCollectionsListener() {
        collectionsListener?.remove()
        collectionsListener = nil
    }
}

// MARK: - Map hint sheet

/// Compact modal that explains the Map tab on first visit. Designed for a
/// `~0.35` detent — large enough for the icon, headline, body, and CTA;
/// small enough that the map remains visible (and interactive) behind it.
private struct MapHintSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            Text("Activities with a location")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Activities with a location show up as pins. Search the bar to drop a preview pin, or tap an existing pin to move it between collections, edit it, or delete it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onDismiss) {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}
