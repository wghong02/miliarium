import SwiftUI
import UserNotifications

/// Inline note shown near notification-dependent controls (activity reminders,
/// the weekly recap) when notifications are turned off, with a shortcut to
/// Settings. Renders nothing when notifications are authorized.
struct NotificationsDisabledNote: View {
    @State private var status: UNAuthorizationStatus = .authorized

    var body: some View {
        Group {
            if status == .denied || status == .notDetermined {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notifications are off — turn them on to receive this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open Settings", destination: url)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .task { status = await notificationService.authorizationStatus() }
    }
}
