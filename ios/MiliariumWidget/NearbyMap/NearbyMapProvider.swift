import WidgetKit
import Foundation

/// One snapshot of the nearby-map widget content at a given moment.
struct NearbyMapEntry: TimelineEntry {
    let date: Date
    let snapshot: NearbySnapshot
}

/// Reads from the App Group `NearbySnapshot` file (written by
/// `WidgetSnapshotService` on the main app). The timeline only needs one
/// entry — the map content is static and isn't time-keyed like the
/// upcoming-activities widget. The main app forces an immediate refresh
/// via `WidgetCenter.reloadAllTimelines()` whenever data changes.
struct NearbyMapProvider: TimelineProvider {
    func placeholder(in context: Context) -> NearbyMapEntry {
        NearbyMapEntry(date: Date(), snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (NearbyMapEntry) -> Void) {
        let snap: NearbySnapshot
        if context.isPreview {
            snap = Self.placeholderSnapshot
        } else {
            snap = WidgetSnapshotStore.readNearby() ?? Self.emptySnapshot
        }
        completion(NearbyMapEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyMapEntry>) -> Void) {
        let snap = WidgetSnapshotStore.readNearby() ?? Self.emptySnapshot
        let entry = NearbyMapEntry(date: Date(), snapshot: snap)
        completion(Timeline(entries: [entry], policy: .atEnd))
    }

    /// Used when no snapshot exists yet (e.g. fresh install before the
    /// main app has ever populated the App Group container).
    private static let emptySnapshot = NearbySnapshot(
        writtenAt: Date(),
        centerLatitude: nil,
        centerLongitude: nil,
        items: []
    )

    /// Shown in the widget gallery and as a graceful default before the
    /// app has written real data.
    private static let placeholderSnapshot = NearbySnapshot(
        writtenAt: Date(),
        centerLatitude: 37.7749,
        centerLongitude: -122.4194,
        items: [
            .init(id: "preview-1", title: "Coffee meet", progressTitle: "Travel",
                  latitude: 37.7860, longitude: -122.4080, isCompleted: false),
            .init(id: "preview-2", title: "Gym", progressTitle: "Health",
                  latitude: 37.7700, longitude: -122.4150, isCompleted: nil),
            .init(id: "preview-3", title: "Bookstore", progressTitle: "Errands",
                  latitude: 37.7800, longitude: -122.4250, isCompleted: false),
        ]
    )
}
