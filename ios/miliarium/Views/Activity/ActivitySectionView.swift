import SwiftUI

struct ActivitySectionView: View {
    @Environment(OnboardingState.self) private var onboardingState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !onboardingState.hasSeenActivityHint {
                        TabHintBanner(
                            icon: "envelope.fill",
                            title: "Invitations & collaboration",
                            message: "Invitations from people who want to share their progress with you appear here. Accept to start collaborating, decline to dismiss. Future notification types will surface here too."
                        ) {
                            withAnimation { onboardingState.markActivityHintSeen() }
                        }
                    }

                    InvitationPanelView()
                }
                .padding(.horizontal)
            }
            .navigationTitle("Activity")
        }
    }
}
