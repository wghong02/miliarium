import Foundation

/// Where the app's backend API lives. All client mutations go through the
/// `api` Cloud Function; reads/listeners still hit Firestore directly.
///
/// Pass the `-backend-emulator` launch argument to target a local
/// `firebase emulators:start` instance instead of the deployed function.
enum BackendConfig {
    private static let projectId = "miliarium-68373"
    private static let region = "us-central1"

    static var baseURL: URL {
        if ProcessInfo.processInfo.arguments.contains("-backend-emulator") {
            return URL(string: "http://127.0.0.1:5001/\(projectId)/\(region)/api")!
        }
        return URL(string: "https://\(region)-\(projectId).cloudfunctions.net/api")!
    }
}
