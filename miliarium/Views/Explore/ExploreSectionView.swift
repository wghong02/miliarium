import SwiftUI

/// Outer wrapper for the Map tab. Handles the progress picker; the actual
/// map rendering lives in `MapView`. Mirrors the structure of
/// `CalendarSectionView` so the navigation pattern is consistent across tabs.
struct ExploreSectionView: View {
    @Environment(ProgressStore.self) private var progressStore

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
                    MapView(progressItemId: selectedId, progressTitle: selectedItem.title)
                } else {
                    ContentUnavailableView(
                        "Choose a progress",
                        systemImage: "chevron.down.circle",
                        description: Text("Select a progress from the picker above to view its map.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    progressPickerMenu
                }
            }
        }
    }

    private var progressPickerMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 4) {
                Text(menuTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var menuTitle: String {
        if let id = progressStore.selectedProgressId,
           let item = progressStore.progresses.first(where: { $0.id == id }) {
            return item.title
        }
        return "Select progress"
    }
}
