//
//  UpcomingActivitiesWidget.swift
//  MiliariumWidget
//
//  Created by Gilbert Hong on 5/27/26.
//

import WidgetKit
import SwiftUI

/// Static (non-configurable) widget that shows the next 3 upcoming
/// activities across every progress the user can access. Data is loaded by
/// `UpcomingProvider` from the App Group snapshot file written by the main
/// app's `WidgetSnapshotService`.
struct UpcomingActivitiesWidget: Widget {
    /// Stable identifier used by `WidgetCenter.reloadTimelines(ofKind:)`
    /// on the app side. Don't rename without updating the app.
    static let kind = "UpcomingActivitiesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UpcomingProvider()) { entry in
            UpcomingEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Upcoming activities")
        .description("Your next 3 upcoming activities across all progresses.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    UpcomingActivitiesWidget()
} timeline: {
    UpcomingEntry(date: .now, items: [
        .init(id: "1", title: "Doctor appointment", progressTitle: "Health",
              timestamp: Date().addingTimeInterval(3_600), hasLocation: true),
        .init(id: "2", title: "Pay rent", progressTitle: "Bills",
              timestamp: Date().addingTimeInterval(86_400), hasLocation: false),
        .init(id: "3", title: "Coffee with Alice", progressTitle: "Travel",
              timestamp: Date().addingTimeInterval(172_800), hasLocation: true),
    ])
    UpcomingEntry(date: .now, items: [])
}
