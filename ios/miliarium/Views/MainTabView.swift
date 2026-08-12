import SwiftUI

struct MainTabView: View {
    @Environment(NotificationRouter.self) private var router
    @Environment(ProgressStore.self) private var progressStore
    @Environment(MemorySettings.self) private var memorySettings

    /// Home is tag 0; a tapped notification routes here (invitations live on
    /// Home, and an activity push opens the relevant progress on Home).
    @State private var selection = 0
    @State private var showMemories = false

    var body: some View {
        TabView(selection: $selection) {
            HomeSectionView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            CalendarSectionView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(1)

            ExploreSectionView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(2)

            ActivitySectionView()
                .tabItem {
                    Label("Activity", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(3)

            ProfileSectionView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
                }
                .tag(4)
        }
        .onChange(of: router.pending) { _, destination in
            guard let destination else { return }
            switch destination {
            case .invitations:
                selection = 0
            case .progress(let progressItemId):
                selection = 0
                progressStore.selectProgress(id: progressItemId)
            case .weeklyRecap:
                showMemories = true
            }
            // Consume the routing request so it doesn't re-fire.
            router.pending = nil
        }
        // Auto-present the weekly recap on launch when it's due.
        .onAppear {
            if memorySettings.isRecapDue() { showMemories = true }
        }
        .sheet(isPresented: $showMemories, onDismiss: { memorySettings.markRecapSeen() }) {
            MemoriesView()
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        MainTabView()
            .environment(AuthViewModel())
            .environment(ProgressStore())
            .environment(NotificationRouter())
            .environment(MemorySettings())
    }
}
