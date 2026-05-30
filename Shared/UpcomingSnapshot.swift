import Foundation

/// JSON written by the main app to the shared App Group container and read
/// by the widget extension. Compact by design — the small widget shows up
/// to 3 items, so we never serialize more than that.
///
/// **Target membership: app + widget extension.**
struct UpcomingSnapshot: Codable, Sendable {
    let writtenAt: Date
    let items: [Item]

    struct Item: Codable, Identifiable, Sendable, Hashable {
        /// Matches `Activity.id` so future deep links can navigate to the
        /// edit sheet by tapping a widget row.
        let id: String
        let title: String
        let progressTitle: String
        let timestamp: Date
        let hasLocation: Bool
    }
}
