import SwiftUI
import FirebaseCore

/// Ensures `FirebaseApp.configure()` runs before previews touch `Auth.auth()`.
enum FirebasePreview {
    static func configureIfNeeded() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }
}

struct FirebasePreviewRoot<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        FirebasePreview.configureIfNeeded()
        self.content = content()
    }

    var body: some View { content }
}
