import Foundation
import UIKit
import UserNotifications
import FirebaseFirestore
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
    private let db = Firestore.firestore()

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

    // MARK: - Firestore upsert / delete

    /// Upserts `currentToken` to `users/{userId}/deviceTokens/{token}`.
    /// Safe to call repeatedly — `createdAt` is preserved across re-syncs
    /// because we only include it on the first write.
    func syncTokenToFirestore(userId: String) async {
        guard let token = currentToken else {
            AppLogger.notification.debug("syncTokenToFirestore skipped: no cached token yet")
            return
        }
        let docRef = tokenDocRef(userId: userId, token: token)
        do {
            // Read first so we can preserve `createdAt` on subsequent writes.
            let snapshot = try await docRef.getDocument()
            var data: [String: Any] = [
                "token": token,
                "userId": userId,
                "platform": "ios",
                "appVersion": Self.appVersion,
                "osVersion": UIDevice.current.systemVersion,
                "lastSeenAt": Timestamp(date: Date()),
            ]
            if !snapshot.exists {
                data["createdAt"] = FieldValue.serverTimestamp()
            }
            try await docRef.setData(data, merge: true)
            AppLogger.notification.debug("syncTokenToFirestore succeeded userId=\(userId) tokenPrefix=\(token.prefix(8))")
        } catch {
            AppLogger.notification.error("syncTokenToFirestore failed userId=\(userId): \(error.localizedDescription)")
        }
    }

    /// Removes this device's token doc from the given user. Call on
    /// sign-out so the previous user no longer receives pushes meant for
    /// them from this device. The local `currentToken` is preserved so
    /// the next sign-in can re-attach it without waiting for FCM again.
    func removeTokenFromFirestore(userId: String) async {
        guard let token = currentToken else {
            AppLogger.notification.debug("removeTokenFromFirestore skipped: no cached token")
            return
        }
        await removeTokenFromFirestore(userId: userId, token: token)
    }

    /// Explicit-token variant used during FCM rotation to clean up the
    /// previous (now-dead) token doc without disturbing `currentToken`.
    func removeTokenFromFirestore(userId: String, token: String) async {
        do {
            try await tokenDocRef(userId: userId, token: token).delete()
            AppLogger.notification.debug("removeTokenFromFirestore succeeded userId=\(userId) tokenPrefix=\(token.prefix(8))")
        } catch {
            AppLogger.notification.error("removeTokenFromFirestore failed userId=\(userId): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func tokenDocRef(userId: String, token: String) -> DocumentReference {
        db.collection("users").document(userId)
            .collection("deviceTokens").document(token)
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

@MainActor let notificationService = NotificationService()
