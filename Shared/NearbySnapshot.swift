import Foundation

/// JSON written by the main app and read by the `NearbyMapWidget`. Holds:
/// - The reference point used to compute "nearby" (the user's last known
///   device location), if available.
/// - Up to 10 located, not-yet-completed activities, sorted by distance
///   from that reference point.
///
/// "Not yet completed" means `isCompleted != true` — activities that don't
/// track completion at all (`isCompleted == nil`) are included alongside
/// those marked pending (`isCompleted == false`). Only activities flagged
/// as done are excluded.
///
/// If the reference point is `nil` (e.g. the user hasn't opened the Map
/// tab since installing the app), `items` is empty and the widget renders
/// an "open the app" empty state.
///
/// **Target membership: app + widget extension.**
struct NearbySnapshot: Codable, Sendable {
    let writtenAt: Date
    let centerLatitude: Double?
    let centerLongitude: Double?
    let items: [Item]

    /// Convenience flag for the widget's empty-state branching — true when
    /// the snapshot has nothing to render *and* no reference point either.
    var hasCenter: Bool { centerLatitude != nil && centerLongitude != nil }

    struct Item: Codable, Identifiable, Sendable, Hashable {
        let id: String
        let title: String
        let progressTitle: String
        let latitude: Double
        let longitude: Double
        /// `nil` = no completion tracking, `false` = pending, `true` = done.
        /// `true` items are excluded by the writer so this is always `nil`
        /// or `false` in practice; the field is preserved for future use.
        let isCompleted: Bool?
    }
}
