import SwiftUI
import FirebaseAuth

struct ProfileSectionView: View {
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let email = auth.user?.email {
                        LabeledContent("Signed in as", value: email)
                    } else {
                        Text("Signed in")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}
