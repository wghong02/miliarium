import Foundation
import OSLog
import CoreLocation
import FirebaseFirestore
import WidgetKit

/// Owns every snapshot file the home-screen widgets read.
///
/// Maintains one `activityService.setActivitiesListener` per accessible
/// progress (fanned out across every progress the user can see). On any
/// listener fire it rebuilds **both** snapshot files (`UpcomingSnapshot`
/// and `NearbySnapshot`), writes them to the App Group container, and
/// calls `WidgetCenter.reloadAllTimelines()` so every installed widget
/// picks up the change promptly.
///
/// Lifecycle is driven from `MiliariumApp`:
/// - `.onChange(of: progressStore.progresses.map(\.id))` → `update(progresses:)`
/// - sign-out → `stop()`
///
/// `MapView` also calls `rebuildSnapshots()` after a fresh location read,
/// so the nearby snapshot's reference point updates even when no activity
/// data has changed.
///
/// **App target only** (widgets just read via `WidgetSnapshotStore`).
@MainActor
final class WidgetSnapshotService {
    private struct ProgressContext {
        let title: String
        let listener: ListenerRegistration
        var activities: [Activity] = []
    }

    private var contexts: [String: ProgressContext] = [:]

    /// Max items shipped to the nearby widget. Keeps the snapshot small
    /// and avoids overcrowding the medium widget's map.
    private static let nearbyItemLimit = 10

    /// Re-syncs the per-progress listeners to match `progresses`. Adds new
    /// listeners, tears down ones for progresses the user lost access to,
    /// and updates cached titles for renamed progresses. Idempotent — safe
    /// to call on every ProgressStore change.
    func update(progresses: [ProgressItem]) {
        let newIds = Set(progresses.map { $0.id })

        // Tear down listeners for progresses no longer accessible.
        for (id, ctx) in contexts where !newIds.contains(id) {
            ctx.listener.remove()
            contexts.removeValue(forKey: id)
        }

        // Update titles for existing contexts; add new ones.
        for progress in progresses {
            if let existing = contexts[progress.id] {
                if existing.title != progress.title {
                    contexts[progress.id] = ProgressContext(
                        title: progress.title,
                        listener: existing.listener,
                        activities: existing.activities
                    )
                }
                continue
            }

            let progressId = progress.id
            let listener = activityService.setActivitiesListener(for: progressId) { [weak self] fetched in
                Task { @MainActor in
                    self?.contexts[progressId]?.activities = fetched
                    self?.rebuildSnapshots()
                }
            }
            contexts[progress.id] = ProgressContext(
                title: progress.title,
                listener: listener
            )
        }

        // If we lost all progresses (or never had any), still write empty
        // snapshots so the widgets render their empty states.
        rebuildSnapshots()
    }

    /// Stops all listeners and clears every snapshot. Call on sign-out.
    func stop() {
        for (_, ctx) in contexts {
            ctx.listener.remove()
        }
        contexts.removeAll()
        WidgetSnapshotStore.writeUpcoming(UpcomingSnapshot(writtenAt: Date(), items: []))
        WidgetSnapshotStore.writeNearby(NearbySnapshot(
            writtenAt: Date(),
            centerLatitude: nil,
            centerLongitude: nil,
            items: []
        ))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Forces a snapshot rebuild without changing the progress listener
    /// set. Call when something the snapshots depend on changes outside
    /// of Firestore — e.g. the user's device location was just refreshed.
    func rebuildSnapshots() {
        rebuildUpcomingSnapshot()
        rebuildNearbySnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Snapshot builders

    private func rebuildUpcomingSnapshot() {
        let now = Date()
        let items = contexts
            .flatMap { (_, ctx) -> [UpcomingSnapshot.Item] in
                ctx.activities.compactMap { activity in
                    guard let ts = activity.timestamp, ts > now else { return nil }
                    return UpcomingSnapshot.Item(
                        id: activity.id,
                        title: activity.title,
                        progressTitle: ctx.title,
                        timestamp: ts,
                        hasLocation: activity.hasLocation
                    )
                }
            }
            .sorted { $0.timestamp < $1.timestamp }
            .prefix(3)

        WidgetSnapshotStore.writeUpcoming(UpcomingSnapshot(
            writtenAt: now,
            items: Array(items)
        ))
    }

    private func rebuildNearbySnapshot() {
        let center = locationService.lastKnownCoordinate

        let allLocatedIncomplete: [(activity: Activity, progressTitle: String)] = contexts
            .flatMap { (_, ctx) -> [(Activity, String)] in
                ctx.activities.compactMap { activity in
                    // Must have a location, and must not be marked done.
                    // (`isCompleted == nil` and `isCompleted == false` both pass.)
                    guard activity.hasLocation,
                          activity.isCompleted != true else { return nil }
                    return (activity, ctx.title)
                }
            }

        let items: [NearbySnapshot.Item]
        if let center {
            let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            items = allLocatedIncomplete
                .map { (activity, progressTitle) -> (Activity, String, Double) in
                    let aLoc = CLLocation(
                        latitude: activity.latitude ?? 0,
                        longitude: activity.longitude ?? 0
                    )
                    return (activity, progressTitle, centerLoc.distance(from: aLoc))
                }
                .sorted { $0.2 < $1.2 }
                .prefix(Self.nearbyItemLimit)
                .map { (activity, progressTitle, _) in
                    NearbySnapshot.Item(
                        id: activity.id,
                        title: activity.title,
                        progressTitle: progressTitle,
                        latitude: activity.latitude ?? 0,
                        longitude: activity.longitude ?? 0,
                        isCompleted: activity.isCompleted
                    )
                }
        } else {
            // No reference point — the widget will render its empty state.
            items = []
        }

        WidgetSnapshotStore.writeNearby(NearbySnapshot(
            writtenAt: Date(),
            centerLatitude: center?.latitude,
            centerLongitude: center?.longitude,
            items: items
        ))
    }
}

@MainActor let widgetSnapshotService = WidgetSnapshotService()
