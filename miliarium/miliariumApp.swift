import SwiftUI
import FirebaseCore

@main
struct MiliariumApp: App {
    /// `@State` defaults run before `init()`, so Firebase must be configured here—not only in `init()`.
    @State private var auth: AuthViewModel = {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        return AuthViewModel()
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
