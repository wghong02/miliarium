import Foundation
import Observation

/// Routes a tapped push notification to the right place in the app.
///
/// The push payloads carry a `type` (and, for activities, a `progressItemId`)
/// in their `data` dictionary — see the backend's pushNotifications.ts. The
/// app delegate's `UNUserNotificationCenterDelegate` extracts those primitives
/// on tap and calls `handle(type:progressItemId:)`; the UI (`MainTabView`)
/// observes `pending` and navigates, then clears it.
@Observable
@MainActor
final class NotificationRouter {
    enum Destination: Equatable {
        /// Show the invitations surface (Home tab).
        case invitations
        /// Open a specific progress.
        case progress(String)
        /// Present the weekly Memories recap.
        case weeklyRecap
    }

    /// Set when a notification is tapped; consumed and cleared by the UI.
    var pending: Destination?

    /// Called from the notification delegate with primitives already extracted
    /// off the `userInfo` dictionary (so nothing non-Sendable crosses actors).
    func handle(type: String?, progressItemId: String?) {
        guard let type else { return }
        switch type {
        case "invitation":
            pending = .invitations
        case "activity":
            if let progressItemId, !progressItemId.isEmpty {
                pending = .progress(progressItemId)
            }
        case "weekly_recap":
            pending = .weeklyRecap
        default:
            break
        }
    }
}

@MainActor let notificationRouter = NotificationRouter()
