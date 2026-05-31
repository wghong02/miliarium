import Foundation
import OSLog

/// Reads and writes per-widget snapshot files to the shared App Group
/// container. Each widget has its own JSON file so writes don't trample
/// each other and a stale read of one snapshot doesn't impact another.
///
/// **Target membership: app + widget extension.**
///
/// ⚠️ The `appGroupId` must exactly match the App Groups capability
/// configured on *both* targets in Signing & Capabilities.
enum WidgetSnapshotStore {
    static let appGroupId = "group.miliarium.shared"

    private static let upcomingFilename = "upcoming-snapshot.json"
    private static let nearbyFilename = "nearby-snapshot.json"

    private static let log = Logger(
        subsystem: "miliarium.miliarium",
        category: "WidgetSnapshot"
    )

    private static func fileURL(named name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(name)
    }

    // MARK: - Upcoming

    static func writeUpcoming(_ snapshot: UpcomingSnapshot) {
        write(snapshot, to: upcomingFilename, label: "upcoming")
    }

    static func readUpcoming() -> UpcomingSnapshot? {
        read(UpcomingSnapshot.self, from: upcomingFilename, label: "upcoming")
    }

    // MARK: - Nearby

    static func writeNearby(_ snapshot: NearbySnapshot) {
        write(snapshot, to: nearbyFilename, label: "nearby")
    }

    static func readNearby() -> NearbySnapshot? {
        read(NearbySnapshot.self, from: nearbyFilename, label: "nearby")
    }

    // MARK: - Internals

    private static func write<T: Encodable>(_ value: T, to filename: String, label: String) {
        guard let url = fileURL(named: filename) else {
            log.error("\(label): App Group container unavailable — check capability for both targets")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            log.debug("\(label): wrote snapshot bytes=\(data.count)")
        } catch {
            log.error("\(label): snapshot write failed: \(error.localizedDescription)")
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from filename: String, label: String) -> T? {
        guard let url = fileURL(named: filename) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            log.error("\(label): snapshot read failed: \(error.localizedDescription)")
            return nil
        }
    }
}
