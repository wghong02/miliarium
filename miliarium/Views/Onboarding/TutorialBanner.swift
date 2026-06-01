import SwiftUI

/// Compact, dismissible banner shown at the top of the Home tab while the
/// onboarding tutorial is in progress. The step is computed upstream by
/// `OnboardingState.currentStep(progressCount:)` — this view is purely
/// presentational.
///
/// Two interactions:
/// - **Implicit advance**: the parent recomputes the step when the user
///   completes the relevant action; this view just redraws.
/// - **Explicit dismiss**: tapping the `xmark` calls `onDismiss`, which
///   the parent uses to set `OnboardingState.hasDismissedTutorial = true`.
struct TutorialBanner: View {
    let step: TutorialStep
    let onDismiss: () -> Void

    var body: some View {
        if let ordinal = step.ordinal {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: step.icon)
                        .foregroundStyle(.blue)
                        .frame(width: 18)
                    Text("Step \(ordinal) of \(TutorialStep.totalSteps)")
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
                    .accessibilityLabel("Dismiss tutorial")
                }
                Text(step.instruction)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        TutorialBanner(step: .createProgress, onDismiss: {})
        TutorialBanner(step: .createCollection, onDismiss: {})
        TutorialBanner(step: .createActivity, onDismiss: {})
        TutorialBanner(step: .done, onDismiss: {}) // renders nothing
            .border(Color.gray)
    }
    .padding()
}
