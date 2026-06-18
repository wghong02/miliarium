import SwiftUI
import FirebaseFirestore

/// Outer wrapper for the Calendar tab. Owns the **collection filter** in
/// the top-left toolbar; defers progress switching to the Home tab (the
/// selected progress is shared app-wide via `ProgressStore`).
struct CalendarSectionView: View {
    @Environment(ProgressStore.self) private var progressStore
    @Environment(OnboardingState.self) private var onboardingState

    @State private var collections: [ActivityCollection] = []
    @State private var collectionsListener: ListenerRegistration?
    @State private var selectedCollectionId: String?
    /// When `false`, activities with `isCompleted == true` are hidden
    /// from both the month-grid dots and the daily list. Default off
    /// so the calendar opens focused on outstanding work.
    @State private var showCompleted = false
    /// When `false`, activities whose timestamp is before start-of-today
    /// are hidden. Default off so the calendar opens looking forward.
    @State private var showPast = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !onboardingState.hasSeenCalendarHint {
                    TabHintBanner(
                        icon: "calendar",
                        title: "Activities with a time",
                        message: "Any activity with a date and time appears here as a dot on its day. Tap a day to see what's scheduled, or use + to add a new activity for the selected day."
                    ) {
                        withAnimation { onboardingState.markCalendarHintSeen() }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }

                Group {
                    if progressStore.progresses.isEmpty {
                        ContentUnavailableView {
                            Label("No progress yet", systemImage: "calendar")
                        } description: {
                            Text("Create a progress item in the Home tab to get started with the calendar.")
                        }
                    } else if let selectedId = progressStore.selectedProgressId,
                              let selectedItem = progressStore.progresses.first(where: { $0.id == selectedId }) {
                        CalendarView(
                            progressItemId: selectedId,
                            progressTitle: selectedItem.title,
                            selectedCollectionId: selectedCollectionId,
                            showCompleted: showCompleted,
                            showPast: showPast
                        )
                    } else {
                        ContentUnavailableView(
                            "Choose a progress",
                            systemImage: "chevron.down.circle",
                            description: Text("Select a progress from the Home tab to view its calendar.")
                        )
                    }
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
            Divider()
            Toggle("Completed", isOn: $showCompleted)
            Toggle("Past", isOn: $showPast)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Filter")
    }

    // MARK: - Collections listener

    private func setUpCollectionsListener(progressId: String) {
        collectionsListener = activityCollectionService.setCollectionsListener(for: progressId) { fetched in
            Task { @MainActor in
                self.collections = fetched
                // If the active filter points at a collection that no
                // longer exists (e.g. it was deleted), drop back to "All".
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
