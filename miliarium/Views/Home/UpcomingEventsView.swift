import SwiftUI
import FirebaseFirestore

/// Home-tab section showing the next 5 activities that have a `timestamp` in
/// the future, sourced from the unified `activities` subcollection. Replaces
/// the legacy `calendars/{id}/events` reader.
struct UpcomingEventsView: View {
    let progressItemId: String

    @State private var allTimedActivities: [Activity] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var editingActivity: Activity?

    private var upcoming: [Activity] {
        let now = Date()
        return allTimedActivities
            .filter { ($0.timestamp ?? .distantPast) > now }
            .sorted { ($0.timestamp ?? .distantFuture) < ($1.timestamp ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming Events")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if upcoming.isEmpty {
                Text("No upcoming events")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(upcoming.prefix(5)) { activity in
                        UpcomingActivityRow(activity: activity) {
                            editingActivity = activity
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
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
        .background(Color(.systemBackground))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

#Preview {
    UpcomingEventsView(progressItemId: "test123")
}
