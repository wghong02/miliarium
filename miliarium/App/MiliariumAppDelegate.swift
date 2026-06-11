import UIKit
import FirebaseAuth
import FirebaseMessaging
internal import os

/// SwiftUI apps don't have a direct `UIApplicationDelegate`, so we attach
/// this one via `@UIApplicationDelegateAdaptor` in `MiliariumApp`. Its
/// jobs:
///   1. Receive the APNS device token from iOS and forward it to FCM.
///   2. Receive the FCM registration token from `MessagingDelegate` and
///      forward it to `notificationService` for Firestore persistence.
///
/// We store the **FCM** token (not the raw APNS hex) because the Cloud
/// Functions backend dispatches pushes through Firebase Cloud Messaging,
/// which requires its own registration tokens.
final class MiliariumAppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Firebase is already configured in `MiliariumApp.init` via the
        // `auth` state initializer. Become the FCM delegate so we receive
        // the registration token (and any subsequent rotations).
        Messaging.messaging().delegate = self
        return true
    }

    /// Called by iOS after `UIApplication.shared.registerForRemoteNotifications()`
    /// succeeds. We hand the raw APNS token to the FCM SDK, which
    /// exchanges it server-side for an FCM registration token and calls
    /// back via `messaging(_:didReceiveRegistrationToken:)`.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppLogger.notification.debug("APNS registration succeeded len=\(deviceToken.count)")
        Messaging.messaging().apnsToken = deviceToken
    }

    /// Called when APNS registration fails — usually a misconfigured
    /// provisioning profile, the simulator (no push support), or a
    /// network glitch. We log and move on; the app remains usable, just
    /// without push.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.notification.error("APNS registration failed: \(error.localizedDescription)")
    }

    // MARK: - MessagingDelegate

    /// Fires when FCM has minted (or rotated) a registration token for
    /// this install. `nil` means FCM is currently reissuing — we just
    /// wait for the next call. Tokens can change at any time (after
    /// reinstall, restore from backup, scheduled rotation), so this
    /// callback is the source of truth — never cache a token elsewhere
    /// and assume it's still valid.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else {
            AppLogger.notification.debug("didReceiveRegistrationToken got nil — FCM reissuing")
            return
        }
        AppLogger.notification.debug("didReceiveRegistrationToken len=\(fcmToken.count)")
        Task { @MainActor in
            notificationService.didReceiveFCMToken(
                fcmToken,
                currentUserId: Auth.auth().currentUser?.uid
            )
        }
    }
}
