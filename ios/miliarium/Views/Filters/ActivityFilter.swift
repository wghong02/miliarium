import SwiftUI

/// The set of client-side filters applied to a progress's activities on the
/// Calendar and Map tabs. Bundling them into one value gives the filter menu,
/// the section views, and the two rendering views (`CalendarView`, `MapView`)
/// a single source of truth and a single predicate — so the calendar dots,
/// the daily rows, and the map pins can never disagree.
struct ActivityFilter: Equatable {
    /// When non-nil, only activities belonging to this collection pass.
    /// `nil` means "All collections".
    var collectionId: String?
    /// When `false`, activities marked complete (`isCompleted == true`) are
    /// hidden. Default off so both tabs open focused on outstanding work.
    var showCompleted: Bool = false
    /// When `false`, activities whose `timestamp` is before start-of-today
    /// are hidden. Untimed activities (no `timestamp`) are unaffected —
    /// `past` only applies to time-bound items. Default off.
    var showPast: Bool = false

    /// Returns `true` when `activity` passes every active clause. `hasLocation`
    /// is intentionally not checked here — the Map listener already filters to
    /// located activities before this runs. Callers pass `startOfToday`
    /// (computed once per render) so the day cutoff isn't recomputed per row.
    func matches(_ activity: Activity, startOfToday: Date) -> Bool {
        if let collectionId, !activity.collectionIds.contains(collectionId) {
            return false
        }
        if !showCompleted, activity.isCompleted == true {
            return false
        }
        if !showPast, let ts = activity.timestamp, ts < startOfToday {
            return false
        }
        return true
    }
}

/// The top-left toolbar filter menu shared by the Calendar and Map tabs: a
/// "Collection" picker section plus a "Show" section with Completed/Past
/// toggles. Binds directly to an `ActivityFilter` owned by the section view.
struct CollectionFilterMenu: View {
    let collections: [ActivityCollection]
    @Binding var filter: ActivityFilter

    var body: some View {
        Menu {
            Section("Collection") {
                pickerRow(label: "All collections", id: nil)
                ForEach(collections) { collection in
                    pickerRow(label: collection.name, id: collection.id)
                }
            }
            Section("Show") {
                Toggle("Completed", isOn: $filter.showCompleted)
                Toggle("Past", isOn: $filter.showPast)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel("Filter")
    }

    /// Renders one collection-picker row. When this row's `id` matches the
    /// current selection, the row uses a filled `checkmark.circle.fill` icon
    /// that picks up the menu's accent color (system blue) — the "colored
    /// emphasis" for the active selection.
    @ViewBuilder
    private func pickerRow(label: String, id: String?) -> some View {
        Button {
            filter.collectionId = id
        } label: {
            if filter.collectionId == id {
                Label(label, systemImage: "checkmark.circle.fill")
            } else {
                Text(label)
            }
        }
    }
}
