import SwiftUI

/// One-time informational banner shown at the top of a tab the first time
/// the user visits it. Distinct from `TutorialBanner` — that one drives a
/// 3-step action machine on Home; this is a static blurb that explains
/// what a tab does. Persisted as a per-tab flag in `OnboardingState`.
///
/// Visually intentionally identical to `TutorialBanner` so users learn one
/// pattern: blue-tinted card with an icon, title, body, and dismiss `xmark`.
struct TabHintBanner: View {
    let icon: String
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .frame(width: 18)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss hint")
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    VStack(spacing: 16) {
        TabHintBanner(
            icon: "calendar",
            title: "Activities with a time",
            message: "Any activity with a date and time appears here. Tap a day to see what's scheduled.",
            onDismiss: {}
        )
        TabHintBanner(
            icon: "mappin.circle.fill",
            title: "Activities with a location",
            message: "Activities with a location show up as pins on the map.",
            onDismiss: {}
        )
        TabHintBanner(
            icon: "envelope.fill",
            title: "Invitations & collaboration",
            message: "Invitations from collaborators show up here.",
            onDismiss: {}
        )
    }
    .padding()
}
