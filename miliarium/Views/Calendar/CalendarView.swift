import SwiftUI
import Foundation
import FirebaseFirestore

/// Month calendar that visualizes activities with a `timestamp`. Sourced
/// from the unified `progressItems/{id}/activities` collection — the legacy
/// `calendars/{id}/events` reader has been retired.
///
/// Tapping `+` opens `CreateActivitySheet` pre-filled with the selected
/// date and the time dimension enabled. Tapping an activity row opens
/// `EditActivitySheet`.
struct CalendarView: View {
    let progressItemId: String
    let progressTitle: String

    @State private var currentDate = Date()
    @State private var selectedDate: Date?
    @State private var allTimedActivities: [Activity] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false

    @State private var showAddActivity = false
    @State private var editingActivity: Activity?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                calendarHeader
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .border(Color(.separator), width: 1)

                monthCalendarGrid
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                Divider()

                if let selectedDate {
                    dailyActivitiesList(for: selectedDate)
                } else {
                    ContentUnavailableView(
                        "Select a date",
                        systemImage: "calendar",
                        description: Text("Tap a date on the calendar to view activities.")
                    )
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showAddActivity = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddActivity) {
                CreateActivitySheet(
                    progressItemId: progressItemId,
                    initialTimestamp: prefilledTimestampForCreate
                )
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
                if selectedDate == nil { selectedDate = currentDate }
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
            .overlay(alignment: .top) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial)
                        .cornerRadius(6)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Header

    private var calendarHeader: some View {
        HStack(spacing: 12) {
            Button(action: previousMonth) {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(monthYearString)
                    .font(.subheadline.weight(.semibold))
                Text(progressTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: nextMonth) {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
        }
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentDate)
    }

    // MARK: - Month grid

    private var monthCalendarGrid: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = daysInMonthGrid
            let totalWeeks = (days.count + 6) / 7

            ForEach(0..<totalWeeks, id: \.self) { weekIndex in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { dayOffset in
                        let dayIndex = weekIndex * 7 + dayOffset
                        if dayIndex < days.count {
                            dayCell(for: days[dayIndex])
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(for day: Date?) -> some View {
        VStack(spacing: 1) {
            if let day {
                Text("\(Foundation.Calendar.current.component(.day, from: day))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isSelectedDate(day) ? .white : .primary)

                if hasActivitiesOnDate(day) {
                    Circle()
                        .fill(isSelectedDate(day) ? Color.white.opacity(0.5) : Color.blue)
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            Group {
                if let day, isSelectedDate(day) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue)
                } else if let day, isCurrentDate(day) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.blue, lineWidth: 1)
                } else {
                    Color.clear
                }
            }
        )
        .onTapGesture {
            if let day { selectedDate = day }
        }
    }

    private var daysInMonthGrid: [Date?] {
        let calendar = Foundation.Calendar.current
        let monthComponents = calendar.dateComponents([.year, .month], from: currentDate)

        guard let firstDayOfMonth = calendar.date(from: monthComponents) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstDayOfMonth) - 1
        let numberOfDaysInMonth = calendar.range(of: .day, in: .month, for: currentDate)?.count ?? 0

        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in 1...numberOfDaysInMonth {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) {
                days.append(date)
            }
        }
        return days
    }

    // MARK: - Daily activities list

    private func dailyActivitiesList(for date: Date) -> some View {
        let dateActivities = allTimedActivities
            .filter { activity in
                guard let ts = activity.timestamp else { return false }
                return Foundation.Calendar.current.isDate(ts, inSameDayAs: date)
            }
            .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDate(date))
                        .font(.headline)
                    Text("\(dateActivities.count) \(dateActivities.count == 1 ? "activity" : "activities")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))

            if dateActivities.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No activities",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Tap + to add one.")
                )
                Spacer()
            } else {
                List {
                    ForEach(dateActivities) { activity in
                        CalendarActivityRow(activity: activity)
                            .contentShape(Rectangle())
                            .onTapGesture { editingActivity = activity }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await deleteActivity(activity) }
                                } label: {
                                    Text("Delete")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var prefilledTimestampForCreate: Date {
        // Honor the selected day, default to the current time of day.
        let selected = selectedDate ?? Date()
        let cal = Foundation.Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        return cal.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: selected
        ) ?? selected
    }

    private func isSelectedDate(_ date: Date) -> Bool {
        guard let selectedDate else { return false }
        return Foundation.Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }

    private func isCurrentDate(_ date: Date) -> Bool {
        Foundation.Calendar.current.isDate(date, inSameDayAs: Date())
    }

    private func hasActivitiesOnDate(_ date: Date) -> Bool {
        allTimedActivities.contains { activity in
            guard let ts = activity.timestamp else { return false }
            return Foundation.Calendar.current.isDate(ts, inSameDayAs: date)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }

    private func previousMonth() {
        currentDate = Foundation.Calendar.current.date(byAdding: .month, value: -1, to: currentDate) ?? currentDate
    }

    private func nextMonth() {
        currentDate = Foundation.Calendar.current.date(byAdding: .month, value: 1, to: currentDate) ?? currentDate
    }

    // MARK: - Data

    private func setUpListener() {
        isLoading = true
        listener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.allTimedActivities = fetched.filter { $0.hasTime }
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func deleteActivity(_ activity: Activity) async {
        do {
            try await activityService.deleteActivity(activity, progressItemId: progressItemId)
            // Listener will refresh allTimedActivities automatically.
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Daily row

private struct CalendarActivityRow: View {
    let activity: Activity

    private var timeString: String {
        guard let ts = activity.timestamp else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: ts)
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
                        Text(timeString)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if activity.hasLocation {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                    }
                    if let completed = activity.isCompleted {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(completed ? .green : .gray)
                    }
                }
                .font(.caption)
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
    }
}
