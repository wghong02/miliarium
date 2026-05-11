import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeSectionView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            CalendarSectionView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
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

#Preview {
    FirebasePreviewRoot {
        MainTabView()
            .environment(AuthViewModel())
            .environment(ProgressStore())
    }
}
