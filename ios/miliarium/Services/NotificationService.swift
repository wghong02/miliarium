import Foundation
import UIKit
import UserNotifications
import FirebaseMessaging
internal import os

/// Manages push-notification permission, FCM-token capture, and Firestore
/// persistence of the per-device token.
///
/// **Why FCM tokens, not raw APNS tokens** — the Cloud Functions backend
/// dispatches pushes through Firebase Cloud Messaging, which requires its
/// own registration tokens. The APNS token is exchanged by the FCM SDK on
/// the client; we never store the raw APNS hex.
///
/// **High-level flow**
/// 1. App calls `requestPermission()` (typically right after sign-in).
/// 2. If granted, the service triggers
///    `UIApplication.registerForRemoteNotifications()`.
/// 3. iOS hands the APNS token to `MiliariumAppDelegate`, which forwards it
///    to FCM. FCM then calls back via `MessagingDelegate`, which routes
///    into `didReceiveFCMToken(_:currentUserId:)`.
/// 4. If a user is signed in, the service upserts the token to
///    `users/{uid}/deviceTokens/{token}` in Firestore.
/// 5. On sign-out, `removeTokenFromFirestore(userId:)` deletes the doc.
///
/// **Storage shape** — one doc per token under each user so multiple
/// devices per account are naturally supported:
///
///     users/{uid}/deviceTokens/{fcmToken}
///       token, userId, platform, appVersion, osVersion,
///       createdAt (server, first write only), lastSeenAt (every sync)
@MainActor
final class NotificationService {
    /// Most recent FCM registration token. `nil` before FCM has delivered
    /// one (typical at first launch before APNS exchange completes).
    private(set) var currentToken: String?

    // MARK: - Permission

    /// Prompts the system permission dialog (no-op if already decided)
    /// and, if granted, kicks off APNS registration. Returns the granted
    /// status — callers usually don't need to act on it because the token
    /// path runs through the delegate either way.
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            AppLogger.notification.debug("requestAuthorization granted=\(granted)")
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            AppLogger.notification.error("requestAuthorization failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Badge

    /// Resets the app-icon badge (the red number) to zero. Called when the
    /// app comes to the foreground so the count clears once the user has
    /// opened the app. Uses the modern `setBadgeCount` API; the older
    /// `UIApplication.applicationIconBadgeNumber` setter is deprecated.
    func clearBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
            AppLogger.notification.debug("clearBadge succeeded")
        } catch {
            AppLogger.notification.error("clearBadge failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FCM callback path

    /// Called from `MiliariumAppDelegate`'s `MessagingDelegate` conformance
    /// whenever FCM mints (or rotates) a registration token for this
    /// install. Caches the token; if a user is signed in, syncs to
    /// Firestore immediately. If no user is signed in yet, the token sits
    /// in `currentToken` until `syncTokenToFirestore(userId:)` is called
    /// by the auth flow.
    func didReceiveFCMToken(_ token: String, currentUserId: String?) {
        let previous = currentToken
        currentToken = token
        AppLogger.notification.debug("didReceiveFCMToken len=\(token.count) signedIn=\(currentUserId != nil)")
        guard let currentUserId else { return }
        Task {
            // If FCM rotated the token, delete the stale doc first so we
            // don't leave dead tokens in Firestore racking up failed sends.
            if let previous, previous != token {
                await removeTokenFromFirestore(userId: currentUserId, token: previous)
            }
            await syncTokenToFirestore(userId: currentUserId)
        }
    }

    // MARK: - Token sync (via backend)

    /// Upserts `currentToken` through the backend (`PUT /me/device-tokens`).
    /// The server preserves `createdAt` and stamps `lastSeenAt`. `userId` is
    /// implied by the auth token and kept only for call-site compatibility.
    func syncTokenToFirestore(userId: String) async {
        guard let token = currentToken else {
            AppLogger.notification.debug("syncTokenToFirestore skipped: no cached token yet")
            return
        }
        struct Body: Encodable {
            let token: String
            let appVersion: String
            let osVersion: String
        }
        do {
            try await BackendClient.shared.request(
                "PUT", "/me/device-tokens",
                body: Body(
                    token: token,
                    appVersion: Self.appVersion,
                    osVersion: UIDevice.current.systemVersion
                )
            )
            AppLogger.notification.debug("syncToken succeeded tokenPrefix=\(token.prefix(8))")
        } catch {
            AppLogger.notification.error("syncToken failed: \(error.localizedDescription)")
        }
    }

    /// Removes this device's token via the backend. Call on sign-out so the
    /// previous user no longer receives pushes from this device. `currentToken`
    /// is preserved so the next sign-in can re-attach it.
    func removeTokenFromFirestore(userId: String) async {
        guard let token = currentToken else {
            AppLogger.notification.debug("removeToken skipped: no cached token")
            return
        }
        await removeTokenFromFirestore(userId: userId, token: token)
    }

    /// Explicit-token variant used during FCM rotation to clean up the previous
    /// (now-dead) token without disturbing `currentToken`.
    func removeTokenFromFirestore(userId: String, token: String) async {
        struct Body: Encodable { let token: String }
        do {
            try await BackendClient.shared.request(
                "POST", "/me/device-tokens/remove", body: Body(token: token)
            )
            AppLogger.notification.debug("removeToken succeeded tokenPrefix=\(token.prefix(8))")
        } catch {
            AppLogger.notification.error("removeToken failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Activity reminders (local notifications)

    private func reminderId(_ activityId: String) -> String {
        "activity-reminder-\(activityId)"
    }

    /// Cancels then (re)schedules a local reminder for an activity. A no-op /
    /// cancel when there's no reminder set or the fire time is already past.
    /// Called after an activity is created or edited.
    func syncReminder(
        activityId: String,
        title: String,
        timestamp: Date?,
        reminderMinutesBefore: Int?
    ) async {
        cancelReminder(activityId: activityId)
        guard let minutes = reminderMinutesBefore, let start = timestamp else { return }
        let fireDate = start.addingTimeInterval(-Double(minutes) * 60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = trimmed.isEmpty ? "Upcoming activity" : trimmed
        content.body = Self.reminderBody(minutesBefore: minutes)
        content.sound = .default

        let comps = Foundation.Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminderId(activityId), content: content, trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            AppLogger.notification.debug("scheduled reminder activity=\(activityId) fire=\(fireDate)")
        } catch {
            AppLogger.notification.error("scheduleReminder failed: \(error.localizedDescription)")
        }
    }

    /// Removes any pending reminder for the given activity (on delete).
    func cancelReminder(activityId: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderId(activityId)])
    }

    /// (Re)schedules the repeating weekly "Memories" recap notification, or
    /// cancels it when disabled. Call on launch and whenever the schedule
    /// changes.
    func scheduleWeeklyRecap(enabled: Bool, components: DateComponents) async {
        let id = "weekly-recap"
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your week in review"
        content.body = "See what you got up to this past week."
        content.sound = .default
        content.userInfo = ["type": "weekly_recap"]

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await center.add(request)
            AppLogger.notification.debug("scheduled weekly recap \(components.weekday ?? -1) \(components.hour ?? -1):\(components.minute ?? -1)")
        } catch {
            AppLogger.notification.error("scheduleWeeklyRecap failed: \(error.localizedDescription)")
        }
    }

    private static func reminderBody(minutesBefore: Int) -> String {
        switch minutesBefore {
        case 0: return "Starting now."
        case 1..<60: return "Starts in \(minutesBefore) minutes."
        case 60: return "Starts in 1 hour."
        case 61..<1440: return "Starts in \(minutesBefore / 60) hours."
        case 1440: return "Starts in 1 day."
        default: return "Starts in \(minutesBefore / 1440) days."
        }
    }

    // MARK: - Helpers

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

@MainActor let notificationService = NotificationService()
