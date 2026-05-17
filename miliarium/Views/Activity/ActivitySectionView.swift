import SwiftUI

struct ActivitySectionView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InvitationPanelView()
                }
                .padding(.horizontal)
            }
            .navigationTitle("Activity")
        }
    }
}
