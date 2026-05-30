import Foundation
import OSLog

/// Reads and writes `UpcomingSnapshot` to the shared App Group container.
/// Both the main app (writer) and the widget extension (reader) hit this
/// same JSON file.
///
/// **Target membership: app + widget extension.**
///
/// ⚠️ The `appGroupId` must exactly match the App Groups capability
/// configured on *both* targets in Signing & Capabilities. If you change
/// the group ID here, change it in both targets' entitlements too.
enum WidgetSnapshotStore {
    static let appGroupId = "group.miliarium.shared"

    private static let filename = "upcoming-snapshot.json"

    private static let log = Logger(
        subsystem: "miliarium.miliarium",
        category: "WidgetSnapshot"
    )

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(filename)
    }

    static func write(_ snapshot: UpcomingSnapshot) {
        guard let url = fileURL else {
            log.error("App Group container unavailable — check capability for both targets")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            log.debug("wrote snapshot items=\(snapshot.items.count) bytes=\(data.count)")
        } catch {
            log.error("snapshot write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> UpcomingSnapshot? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UpcomingSnapshot.self, from: data)
        } catch {
            log.error("snapshot read failed: \(error.localizedDescription)")
            return nil
        }
    }
}
