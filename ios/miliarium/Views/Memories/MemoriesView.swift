import SwiftUI

/// One activity in the weekly recap, tagged with which progress it belongs to.
private struct MemoryItem: Identifiable {
    let id: String
    let activity: Activity
    let progressTitle: String
    let date: Date
}

/// Activities that happened on a single day.
private struct MemoryDayGroup: Identifiable {
    let day: Date
    var id: Date { day }
    let items: [MemoryItem]
}

/// The weekly "Memories" recap: a scrollable summary of everything that
/// happened across the user's progresses in the past 7 days, grouped by day.
/// Presented automatically on launch when due, from the weekly notification,
/// and manually from Profile.
struct MemoriesView: View {
    @Environment(ProgressStore.self) private var progressStore
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var groups: [MemoryDayGroup] = []

    private let now = Date()
    private var weekStart: Date {
        Foundation.Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Gathering your week…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    RetryableErrorView(message: "We couldn't load your week.") {
                        Task { await load() }
                    }
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "A quiet week",
                        systemImage: "sparkles",
                        description: Text("Nothing logged in the past 7 days. New memories will show up here.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(Self.dayTitle(group.day))
                                        .font(.headline)
                                    ForEach(group.items) { item in
                                        MemoryRow(item: item)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("This week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        let count = groups.reduce(0) { $0 + $1.items.count }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Your week in review")
                .font(.title2.bold())
            Text("\(count) \(count == 1 ? "thing" : "things") across \(Self.rangeText(weekStart, now)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        let progresses = progressStore.progresses
        let start = weekStart
        let end = now

        var items: [MemoryItem] = []
        var anyFailed = false
        await withTaskGroup(of: (items: [MemoryItem], failed: Bool).self) { group in
            for progress in progresses {
                let pid = progress.id
                let ptitle = progress.title
                group.addTask {
                    do {
                        let activities = try await activityService.fetchActivities(for: pid)
                        let mapped = activities.compactMap { activity -> MemoryItem? in
                            let date = activity.timestamp ?? activity.createdAt
                            guard date >= start, date <= end else { return nil }
                            return MemoryItem(
                                id: "\(pid)-\(activity.id)",
                                activity: activity,
                                progressTitle: ptitle,
                                date: date
                            )
                        }
                        return (mapped, false)
                    } catch {
                        return ([], true)
                    }
                }
            }
            for await result in group {
                items.append(contentsOf: result.items)
                if result.failed { anyFailed = true }
            }
        }

        // Only surface a full error state when we got nothing AND something
        // failed; partial results are shown as-is.
        if items.isEmpty && anyFailed {
            loadFailed = true
            isLoading = false
            return
        }

        let cal = Foundation.Calendar.current
        let grouped = Dictionary(grouping: items) { cal.startOfDay(for: $0.date) }
        groups = grouped.keys.sorted(by: >).map { day in
            MemoryDayGroup(day: day, items: grouped[day]!.sorted { $0.date > $1.date })
        }
        isLoading = false
    }

    // MARK: - Formatting

    private static func dayTitle(_ day: Date) -> String {
        let cal = Foundation.Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        return fmt.string(from: day)
    }

    private static func rangeText(_ start: Date, _ end: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }
}

private struct MemoryRow: View {
    let item: MemoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.activity.title)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(item.progressTitle)
                    if let time = timeText {
                        Text("·")
                        Text(time)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let notes = item.activity.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        if item.activity.isCompleted == true { return "checkmark.circle.fill" }
        if item.activity.hasLocation { return "mappin.circle.fill" }
        return "sparkle"
    }

    private var timeText: String? {
        guard let ts = item.activity.timestamp, !item.activity.isAllDay else { return nil }
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return fmt.string(from: ts)
    }
}
