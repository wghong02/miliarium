import WidgetKit
import SwiftUI

/// Medium-size widget showing a SwiftUI `Map` of activities near the user
/// that haven't been marked complete. Reference point is the device's
/// last known GPS location, cached by the main app's `LocationService`.
struct NearbyMapWidget: Widget {
    /// Stable identifier — don't rename without updating any app-side
    /// `WidgetCenter.reloadTimelines(ofKind:)` callers.
    static let kind = "NearbyMapWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NearbyMapProvider()) { entry in
            NearbyMapEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Nearby activities")
        .description("Map of activities near you that aren't done yet.")
        .supportedFamilies([.systemMedium])
    }
}

#Preview(as: .systemMedium) {
    NearbyMapWidget()
} timeline: {
    NearbyMapEntry(date: .now, snapshot: NearbySnapshot(
        writtenAt: .now,
        centerLatitude: 37.7749,
        centerLongitude: -122.4194,
        items: [
            .init(id: "1", title: "Coffee meet", progressTitle: "Travel",
                  latitude: 37.7860, longitude: -122.4080, isCompleted: false),
            .init(id: "2", title: "Gym", progressTitle: "Health",
                  latitude: 37.7700, longitude: -122.4150, isCompleted: nil),
            .init(id: "3", title: "Bookstore", progressTitle: "Errands",
                  latitude: 37.7800, longitude: -122.4250, isCompleted: false),
        ]
    ))
}
