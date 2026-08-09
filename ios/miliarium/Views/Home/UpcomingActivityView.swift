import SwiftUI
import FirebaseFirestore

/// Home-tab section listing every timed activity scheduled in the future
/// (capped at 20, scrollable), sorted soonest-first. Visually matches the
/// "Sharing" section pattern: leading `Divider`, section header with icon,
/// then content — no card background.
struct UpcomingActivityView: View {
    let progressItemId: String

    @State private var allTimedActivities: [Activity] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var editingActivity: Activity?

    /// Soonest-first; only activities whose `timestamp` is strictly in the
    /// future. Capped at 20 — anything past that is in the Calendar tab.
    private var upcoming: [Activity] {
        let now = Date()
        return allTimedActivities
            .filter { ($0.timestamp ?? .distantPast) > now }
            .sorted { ($0.timestamp ?? .distantFuture) < ($1.timestamp ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.top, 4)

            HStack(spacing: 8) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.blue)
                Text("Upcoming activities")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if upcoming.isEmpty {
                Text("No upcoming activities")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(upcoming.prefix(20)) { activity in
                            UpcomingActivityRow(activity: activity) {
                                editingActivity = activity
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .sheet(item: $editingActivity) { activity in
            EditActivitySheet(
                activity: activity,
                progressItemId: progressItemId
            ) {
                editingActivity = nil
            }
        }
        .onAppear {
            if !listenerInitialized {
                setUpListener()
                listenerInitialized = true
            }
        }
        .onDisappear {
            listener?.remove()
            listenerInitialized = false
        }
        .onChange(of: progressItemId) { _, _ in
            listener?.remove()
            listenerInitialized = false
            allTimedActivities = []
            setUpListener()
            listenerInitialized = true
        }
    }

    private func setUpListener() {
        isLoading = true
        // Listen to ALL activities under this progress, then filter timed
        // ones in memory. This keeps the listener in lock-step with edits
        // that toggle the time dimension on/off.
        listener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.allTimedActivities = fetched.filter { $0.hasTime }
            self.isLoading = false
            self.errorMessage = nil
        }
    }
}

private struct UpcomingActivityRow: View {
    let activity: Activity
    var onTap: () -> Void

    private var dateTimeString: String {
        guard let ts = activity.timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: ts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text(dateTimeString)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if activity.hasLocation {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let notes = activity.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        // Subtle gray so rows stand out against the now-cardless parent.
        .background(Color(.systemGray6))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

#Preview {
    UpcomingActivityView(progressItemId: "test123")
}
