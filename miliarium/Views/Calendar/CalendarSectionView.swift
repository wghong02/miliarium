import SwiftUI

struct CalendarSectionView: View {
    @Environment(ProgressStore.self) private var progressStore

    var body: some View {
        NavigationStack {
            Group {
                if progressStore.progresses.isEmpty {
                    ContentUnavailableView {
                        Label("No progress yet", systemImage: "calendar")
                    } description: {
                        Text("Create a progress item in the Home tab to get started with the calendar.")
                    }
                } else if let selectedId = progressStore.selectedProgressId,
                          let selectedItem = progressStore.progresses.first(where: { $0.id == selectedId }) {
                    CalendarView(progressItemId: selectedId, progressTitle: selectedItem.title)
                } else {
                    ContentUnavailableView(
                        "Choose a progress",
                        systemImage: "chevron.down.circle",
                        description: Text("Select a progress from the picker above to view its calendar.")
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
