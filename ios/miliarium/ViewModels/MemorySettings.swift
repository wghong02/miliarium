import Foundation
import Observation

/// User preferences for the weekly **Memories** recap, persisted in
/// `UserDefaults`. A weekly local notification fires at `(weekday, hour,
/// minute)` — default **Sunday 8 PM** — and the recap also auto-presents on
/// app launch when it's due. `lastSeenRecapDate` gates the auto-present so the
/// same week's recap isn't shown twice.
@Observable
@MainActor
final class MemorySettings {
    private static let enabledKey = "miliarium.memories.enabled"
    private static let weekdayKey = "miliarium.memories.weekday" // 1=Sun ... 7=Sat
    private static let hourKey = "miliarium.memories.hour"
    private static let minuteKey = "miliarium.memories.minute"
    private static let lastSeenKey = "miliarium.memories.lastSeenRecap"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    /// `Calendar` weekday: 1 = Sunday ... 7 = Saturday.
    var weekday: Int {
        didSet { UserDefaults.standard.set(weekday, forKey: Self.weekdayKey) }
    }
    var hour: Int {
        didSet { UserDefaults.standard.set(hour, forKey: Self.hourKey) }
    }
    var minute: Int {
        didSet { UserDefaults.standard.set(minute, forKey: Self.minuteKey) }
    }
    private var lastSeenRecapDate: Date? {
        didSet {
            UserDefaults.standard.set(lastSeenRecapDate, forKey: Self.lastSeenKey)
        }
    }

    init() {
        let d = UserDefaults.standard
        // Defaults: enabled, Sunday (1) at 20:00.
        self.isEnabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        self.weekday = d.object(forKey: Self.weekdayKey) as? Int ?? 1
        self.hour = d.object(forKey: Self.hourKey) as? Int ?? 20
        self.minute = d.object(forKey: Self.minuteKey) as? Int ?? 0
        self.lastSeenRecapDate = d.object(forKey: Self.lastSeenKey) as? Date
    }

    /// Changes to this string mean the notification needs rescheduling.
    var scheduleSignature: String { "\(isEnabled)-\(weekday)-\(hour)-\(minute)" }

    /// Trigger components for the repeating weekly notification.
    var notificationComponents: DateComponents {
        DateComponents(hour: hour, minute: minute, weekday: weekday)
    }

    /// The `Date`/`Time` binding helper for the settings picker (today's date at
    /// the configured hour/minute).
    var timeAsDate: Date {
        Foundation.Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) ?? Date()
    }
    func setTime(from date: Date) {
        let c = Foundation.Calendar.current.dateComponents([.hour, .minute], from: date)
        hour = c.hour ?? hour
        minute = c.minute ?? minute
    }

    /// The most recent scheduled occurrence at or before `now`, if any.
    private func lastScheduledOccurrence(before now: Date) -> Date? {
        Foundation.Calendar.current.nextDate(
            after: now,
            matching: notificationComponents,
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    /// True when the recap should auto-present: enabled, the scheduled time has
    /// passed this week, and we haven't shown it since that occurrence.
    func isRecapDue(now: Date = Date()) -> Bool {
        guard isEnabled, let occurrence = lastScheduledOccurrence(before: now) else {
            return false
        }
        if let seen = lastSeenRecapDate, seen >= occurrence { return false }
        return true
    }

    func markRecapSeen(now: Date = Date()) {
        lastSeenRecapDate = now
    }
}
