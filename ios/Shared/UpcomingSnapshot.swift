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
        /// Matches `Activity.id`.
        let id: String
        /// Owning progress id, for deep-linking a widget tap. Optional so older
        /// cached snapshots still decode.
        let progressItemId: String?
        let title: String
        let progressTitle: String
        let timestamp: Date
        let hasLocation: Bool

        init(
            id: String,
            progressItemId: String? = nil,
            title: String,
            progressTitle: String,
            timestamp: Date,
            hasLocation: Bool
        ) {
            self.id = id
            self.progressItemId = progressItemId
            self.title = title
            self.progressTitle = progressTitle
            self.timestamp = timestamp
            self.hasLocation = hasLocation
        }
    }
}
