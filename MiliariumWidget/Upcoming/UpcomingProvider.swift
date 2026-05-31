import WidgetKit
import Foundation

/// One snapshot of the widget content at a given moment.
struct UpcomingEntry: TimelineEntry {
    let date: Date
    let items: [UpcomingSnapshot.Item]
}

/// Reads from the App Group snapshot file (written by
/// `WidgetSnapshotService` in the main app) and emits a timeline whose
/// entries are scheduled at each activity's start time — so the widget
/// "rolls forward" automatically without burning extra refresh budget.
struct UpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: Date(), items: Self.placeholderItems)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        // The widget gallery preview must always show *something*. Outside
        // of preview, fall back to whatever's in the shared container.
        let items: [UpcomingSnapshot.Item]
        if context.isPreview {
            items = Self.placeholderItems
        } else {
            items = WidgetSnapshotStore.readUpcoming()?.items ?? []
        }
        completion(UpcomingEntry(date: Date(), items: items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.readUpcoming()
        let allItems = snapshot?.items ?? []
        let now = Date()

        // "Now" entry — shows all items still in the future.
        var entries: [UpcomingEntry] = [
            UpcomingEntry(date: now, items: allItems.filter { $0.timestamp > now })
        ]

        // One entry per future item. As each activity's timestamp passes,
        // the widget redraws with the remaining list — no extra refresh
        // budget consumed.
        for item in allItems where item.timestamp > now {
            entries.append(UpcomingEntry(
                date: item.timestamp,
                items: allItems.filter { $0.timestamp > item.timestamp }
            ))
        }

        // After the last entry, ask iOS to come back for a fresh snapshot.
        // The main app also forces an immediate reload via
        // `WidgetCenter.reloadAllTimelines()` whenever data changes, so
        // this is just the fallback path.
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    /// Used for the widget gallery and as a graceful default before the
    /// main app has populated the App Group container even once.
    private static let placeholderItems: [UpcomingSnapshot.Item] = [
        .init(
            id: "preview-1",
            title: "Doctor appointment",
            progressTitle: "Health",
            timestamp: Date().addingTimeInterval(3_600),
            hasLocation: true
        ),
        .init(
            id: "preview-2",
            title: "Pay rent",
            progressTitle: "Bills",
            timestamp: Date().addingTimeInterval(86_400),
            hasLocation: false
        ),
        .init(
            id: "preview-3",
            title: "Coffee with Alice",
            progressTitle: "Travel",
            timestamp: Date().addingTimeInterval(172_800),
            hasLocation: true
        )
    ]
}
