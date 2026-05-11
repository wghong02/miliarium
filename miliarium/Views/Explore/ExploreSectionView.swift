import SwiftUI

struct ExploreSectionView: View {
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
