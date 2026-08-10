import SwiftUI

/// Slim bar shown at the top of the app while offline.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("No internet connection")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.gray)
    }
}
