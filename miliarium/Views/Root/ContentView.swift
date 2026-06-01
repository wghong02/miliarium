import SwiftUI
import FirebaseAuth

struct ContentView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(OnboardingState.self) private var onboardingState

    /// Drives the `WelcomeSheet`. Synced from `onboardingState.hasSeenWelcome`
    /// via `.onChange` so that flipping the persisted flag (which happens
    /// inside the dismiss callback) doesn't fight the sheet's own dismissal
    /// animation.
    @State private var showWelcome = false

    var body: some View {
        Group {
            if auth.user != nil {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .onAppear { evaluateWelcome() }
        .onChange(of: auth.user?.uid) { _, _ in evaluateWelcome() }
        // Re-present the welcome sheet when the user resets onboarding
        // from the Profile tab (`hasSeenWelcome` flips back to false).
        .onChange(of: onboardingState.hasSeenWelcome) { _, newValue in
            if !newValue { evaluateWelcome() }
        }
        .sheet(isPresented: $showWelcome, onDismiss: {
            // Swipe-down dismiss path: still mark welcome as seen so the
            // sheet doesn't pop up again on the next launch.
            onboardingState.markWelcomeSeen()
        }) {
            WelcomeSheet(onDismiss: {
                onboardingState.markWelcomeSeen()
                showWelcome = false
            })
        }
    }

    private func evaluateWelcome() {
        // Only present to authenticated users who haven't seen the sheet
        // yet. Signed-out users see the login screen; previously onboarded
        // users skip straight to the tab view.
        if auth.user != nil && !onboardingState.hasSeenWelcome {
            showWelcome = true
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        ContentView()
            .environment(AuthViewModel())
            .environment(OnboardingState())
    }
}
