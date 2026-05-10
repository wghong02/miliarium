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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(progressStore)
                .onAppear {
                    progressStore.updateUserId(auth.user?.uid)
                }
                .onChange(of: auth.user?.uid) { _, newValue in
                    progressStore.updateUserId(newValue)
                }
        }
    }
}
