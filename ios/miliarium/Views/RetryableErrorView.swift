import SwiftUI

/// Reusable full-area error state with a retry button, for screens whose data
/// is loaded by a one-shot fetch (which can fail with no automatic recovery).
struct RetryableErrorView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Couldn't load")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                retry()
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
