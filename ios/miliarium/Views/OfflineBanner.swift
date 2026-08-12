import SwiftUI

/// Slim bar shown at the top of the app while offline. Explains that the app
/// is read-only until the connection returns, since all writes go through the
/// backend and can't be made offline.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Offline — you can view existing activities, but changes can't be saved until you're back online.")
                .multilineTextAlignment(.center)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color.gray)
    }
}
