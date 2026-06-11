import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct MiliariumApp: App {
    /// `@State` defaults run before `init()`, so Firebase must be configured here—not only in `init()`.
    @State private var auth: AuthViewModel = {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        return AuthViewModel()
    }()

    @State private var progressStore = ProgressStore()
    @State private var invitationVM = InvitationViewModel()
    @State private var onboardingState = OnboardingState()

    /// Bridges UIKit's `UIApplicationDelegate` callbacks (APNS token
    /// delivery, registration failures) into the SwiftUI lifecycle so
    /// `NotificationService` can persist the token.
    @UIApplicationDelegateAdaptor(MiliariumAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(progressStore)
                .environment(invitationVM)
                .environment(onboardingState)
                .onAppear {
                    progressStore.updateUserId(auth.user?.uid)
                    invitationVM.setUserId(auth.user?.uid)
                    // App launched into a signed-in state (Firebase
                    // restored the session) — request push permission and
                    // sync any cached APNS token. No-op if the user is
                    // signed out (the permission dialog should only appear
                    // after sign-in for a coherent UX).
                    if let uid = auth.user?.uid {
                        Task {
                            await notificationService.requestPermission()
                            await notificationService.syncTokenToFirestore(userId: uid)
                        }
                    }
                }
                .onChange(of: auth.user?.uid) { oldValue, newValue in
                    progressStore.updateUserId(newValue)
                    invitationVM.setUserId(newValue)
                    if newValue == nil {
                        widgetSnapshotService.stop()
                        // Sign-out: drop this device's token from the user
                        // we're leaving so they stop receiving pushes here.
                        if let oldValue {
                            Task { await notificationService.removeTokenFromFirestore(userId: oldValue) }
                        }
                    } else if let newValue {
                        // Sign-in: surface the permission prompt (no-op if
                        // already decided) and sync any cached APNS token.
                        Task {
                            await notificationService.requestPermission()
                            await notificationService.syncTokenToFirestore(userId: newValue)
                        }
                    }
                }
                // Re-sync the widget's per-progress listeners whenever the
                // accessible-progresses set changes. Map to IDs so SwiftUI
                // can compare arrays for equality.
                .onChange(of: progressStore.progresses.map(\.id)) { _, _ in
                    widgetSnapshotService.update(progresses: progressStore.progresses)
                }
        }
    }
}
