import Foundation
import Network
import Observation

/// App-wide network reachability. Drives the offline banner and lets the backend
/// client give a clearer "you're offline" message. Reads still work offline via
/// Firestore's listener cache; writes (which go through the backend) don't.
@Observable
@MainActor
final class NetworkMonitor {
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "miliarium.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}

@MainActor let networkMonitor = NetworkMonitor()
