import SwiftUI
import FirebaseAuth

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        TabView {
            HomeSectionView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            ExploreSectionView()
                .tabItem {
                    Label("Explore", systemImage: "map.fill")
                }

            ActivitySectionView()
                .tabItem {
                    Label("Activity", systemImage: "chart.line.uptrend.xyaxis")
                }

            ProfileSectionView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
        }
    }
}

// MARK: - Sections

private struct HomeSectionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Home",
                systemImage: "house.fill",
                description: Text("Your dashboard will live here.")
            )
            .navigationTitle("Home")
        }
    }
}

private struct ExploreSectionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Explore",
                systemImage: "map.fill",
                description: Text("Browse and discover content here.")
            )
            .navigationTitle("Explore")
        }
    }
}

private struct ActivitySectionView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Activity",
                systemImage: "chart.line.uptrend.xyaxis",
                description: Text("History and progress will appear here.")
            )
            .navigationTitle("Activity")
        }
    }
}

private struct ProfileSectionView: View {
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

#Preview {
    FirebasePreviewRoot {
        MainTabView()
            .environment(AuthViewModel())
    }
}
