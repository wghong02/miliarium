import SwiftUI

struct ActivitySectionView: View {
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
