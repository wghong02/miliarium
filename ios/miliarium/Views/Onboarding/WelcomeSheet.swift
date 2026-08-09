import SwiftUI

/// Three-page paginated welcome shown once on first launch. Dismissing via
/// "Get started", "Skip", or swipe-down all count as "seen" — the sheet
/// never reappears on the same device.
struct WelcomeSheet: View {
    /// Called when the user dismisses by any means. The caller is
    /// responsible for marking welcome as seen and toggling the sheet
    /// binding to false.
    var onDismiss: () -> Void

    @State private var pageIndex = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "sparkles",
            title: "Welcome to Miliarium",
            body: "A place to track the things you do — goals, trips, habits — and keep them organized."
        ),
        OnboardingPage(
            icon: "chart.line.uptrend.xyaxis",
            title: "Start with a Progress",
            body: "A Progress is a big goal or theme — like “Travel 2026” or “Marathon training”. You can have several at once and switch between them from the top-left menu."
        ),
        OnboardingPage(
            icon: "tray.full.fill",
            title: "Activities & Collections",
            body: "Activities are the things you do (visit a museum, run 5 miles, finish a chapter). Collections let you group activities however you like — by city, by type, by week."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    PageContent(page: page).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            ctaButton
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled(false) // swipe-down dismisses (caller marks seen)
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            if pageIndex < pages.count - 1 {
                Button("Skip") { onDismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        // Pushed down further so it clears the sheet's drag indicator and
        // doesn't crowd the rounded corner of the modal.
        .padding(.top, 32)
        .frame(height: 52)
    }

    private var ctaButton: some View {
        Button {
            if pageIndex == pages.count - 1 {
                onDismiss()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pageIndex += 1
                }
            }
        } label: {
            Text(pageIndex == pages.count - 1 ? "Get started" : "Next")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.bottom, 20)
    }
}

private struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
}

private struct PageContent: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: page.icon)
                .font(.system(size: 72))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
            Text(page.title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}

#Preview {
    WelcomeSheet(onDismiss: {})
}
