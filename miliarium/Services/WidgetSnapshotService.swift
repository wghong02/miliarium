import Foundation
import OSLog
import FirebaseFirestore
import WidgetKit

/// Owns the "next 3 upcoming activities across all progresses" snapshot
/// that the home-screen widget reads.
///
/// Maintains one `activityService.setActivitiesListener` per accessible
/// progress (mirrors what `UpcomingActivityView` does for one progress,
/// but fanned out across all of them). On any listener fire it rebuilds
/// the snapshot, writes it to the App Group container, and calls
/// `WidgetCenter.reloadAllTimelines()` so the widget refreshes promptly.
///
/// Lifecycle is driven from `MiliariumApp`:
/// - `.onChange(of: progressStore.progresses.map(\.id))` → `update(progresses:)`
/// - sign-out → `stop()`
///
/// **App target only** (the widget extension just reads via `WidgetSnapshotStore`).
@MainActor
final class WidgetSnapshotService {
    private struct ProgressContext {
        let title: String
        let listener: ListenerRegistration
        var activities: [Activity] = []
    }

    private var contexts: [String: ProgressContext] = [:]

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
                    self?.rebuildSnapshot()
                }
            }
            contexts[progress.id] = ProgressContext(
                title: progress.title,
                listener: listener
            )
        }

        // If we lost all progresses (or never had any), still write an
        // empty snapshot so the widget renders the "Nothing scheduled" state.
        rebuildSnapshot()
    }

    /// Stops all listeners and clears the snapshot. Call on sign-out.
    func stop() {
        for (_, ctx) in contexts {
            ctx.listener.remove()
        }
        contexts.removeAll()
        WidgetSnapshotStore.write(UpcomingSnapshot(writtenAt: Date(), items: []))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func rebuildSnapshot() {
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

        let snapshot = UpcomingSnapshot(writtenAt: now, items: Array(items))
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor let widgetSnapshotService = WidgetSnapshotService()
