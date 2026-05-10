import SwiftUI

struct ContentView: View {
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        Group {
            if auth.user != nil {
                MainTabView()
            } else {
                LoginView()
            }
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        ContentView()
            .environment(AuthViewModel())
    }
}
