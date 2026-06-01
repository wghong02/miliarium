import UIKit
import FirebaseAuth
internal import os

/// SwiftUI apps don't have a direct `UIApplicationDelegate`, so we attach
/// this one via `@UIApplicationDelegateAdaptor` in `MiliariumApp`. Its only
/// job today is to receive the APNS callbacks for push notifications and
/// forward the token to `notificationService`.
final class MiliariumAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Firebase is already configured in `MiliariumApp.init` via the
        // `auth` state initializer; nothing extra needed here.
        true
    }

    /// Called by iOS after the user grants notification permission and
    /// `UIApplication.shared.registerForRemoteNotifications()` runs. The
    /// token is delivered as raw `Data` — we convert to lowercase hex so
    /// it round-trips cleanly as a Firestore doc ID and matches what
    /// APNS / Cloud Functions expect.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppLogger.notification.debug("APNS registration succeeded len=\(deviceToken.count)")

        // Hand the token to the service on the main actor. If a user is
        // already signed in, the service writes it to Firestore in the
        // same hop. Otherwise it just caches it for the sign-in flow.
        Task { @MainActor in
            notificationService.didReceiveAPNSToken(
                token,
                currentUserId: Auth.auth().currentUser?.uid
            )
        }
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
}
