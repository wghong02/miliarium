import Foundation
import OSLog

/// Per-task metadata, JSON-encoded into `URLSessionTask.taskDescription` so it
/// survives app suspension/relaunch.
struct UploadTaskInfo: Codable {
    enum Kind: String, Codable { case main, thumbnail }
    let kind: Kind
    let mediaId: String
    let progressItemId: String
    let activityId: String
    let storagePath: String
    let thumbnailStoragePath: String?
    let type: String            // "image" | "video"
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let tempFilePath: String     // this task's local file, to delete on completion
}

/// Owns a **background** `URLSession` that transfers media bytes to the signed
/// upload URLs — so uploads continue if the app is backgrounded or killed. The
/// small "commit" call (which writes the Firestore doc) is delegated to
/// `MediaCommitStore`, which persists pending commits and retries them on the
/// next foreground so nothing is lost.
final class BackgroundUploadManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploadManager()

    /// Set by the app delegate in `handleEventsForBackgroundURLSession`.
    var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "miliarium.bg.uploads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Force the session (and its delegate) to exist so queued background events
    /// are delivered. Call on launch and when handling background events.
    func activate() { _ = session }

    /// Enqueues the main (and best-effort thumbnail) uploads for one media item.
    func enqueue(
        mainURLString: String,
        mainFile: URL,
        mainContentType: String,
        thumbnailURLString: String?,
        thumbnailFile: URL?,
        info: UploadTaskInfo
    ) {
        // Thumbnail first — tiny, usually finishes before the main upload so the
        // commit can pick it up.
        if let thumbnailURLString,
           let thumbnailFile,
           let url = URL(string: thumbnailURLString) {
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: req, fromFile: thumbnailFile)
            let thumbInfo = UploadTaskInfo(
                kind: .thumbnail, mediaId: info.mediaId,
                progressItemId: info.progressItemId, activityId: info.activityId,
                storagePath: info.storagePath, thumbnailStoragePath: info.thumbnailStoragePath,
                type: info.type, width: info.width, height: info.height,
                durationSeconds: info.durationSeconds, tempFilePath: thumbnailFile.path
            )
            task.taskDescription = Self.encode(thumbInfo)
            task.resume()
        }

        guard let url = URL(string: mainURLString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(mainContentType, forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, fromFile: mainFile)
        task.taskDescription = Self.encode(info)
        task.resume()
    }

    // MARK: - URLSession delegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0,
              let info = Self.decode(task.taskDescription),
              info.kind == .main else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in uploadCenter.setProgress(mediaId: info.mediaId, fraction: fraction) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let info = Self.decode(task.taskDescription) else { return }
        try? FileManager.default.removeItem(atPath: info.tempFilePath)

        // Thumbnails are best-effort — no commit, no failure surfaced.
        guard info.kind == .main else { return }

        let http = task.response as? HTTPURLResponse
        let ok = error == nil && (http.map { (200..<300).contains($0.statusCode) } ?? false)
        if ok {
            Task { await MediaCommitStore.shared.commit(info) }
        } else {
            AppLogger.media.error("bg upload failed media=\(info.mediaId): \(error?.localizedDescription ?? "http \(http?.statusCode ?? -1)")")
            Task {
                await MediaCommitStore.shared.drop(mediaId: info.mediaId)
                await MainActor.run { uploadCenter.markFailed(mediaId: info.mediaId) }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    // MARK: - Coding

    private static func encode(_ info: UploadTaskInfo) -> String? {
        (try? JSONEncoder().encode(info)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private static func decode(_ string: String?) -> UploadTaskInfo? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UploadTaskInfo.self, from: data)
    }
}

/// Persists media commits that are waiting to be written after their bytes have
/// uploaded, and retries them (idempotently) until they land — so a commit lost
/// to app suspension is recovered on the next foreground.
actor MediaCommitStore {
    static let shared = MediaCommitStore()

    private let defaultsKey = "miliarium.pendingMediaCommits"

    private struct CommitBody: Encodable {
        let mediaId: String
        let storagePath: String
        let thumbnailStoragePath: String?
        let type: String
        let width: Int?
        let height: Int?
        let durationSeconds: Double?
    }

    private func load() -> [UploadTaskInfo] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([UploadTaskInfo].self, from: data) else { return [] }
        return list
    }
    private func save(_ list: [UploadTaskInfo]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }

    /// Records a media item as pending commit (called when it's enqueued).
    func register(_ info: UploadTaskInfo) {
        var list = load()
        list.removeAll { $0.mediaId == info.mediaId }
        list.append(info)
        save(list)
    }

    /// Drops a pending commit without committing (upload failed).
    func drop(mediaId: String) {
        save(load().filter { $0.mediaId != mediaId })
    }

    /// Commits one media doc through the backend. Removes it from the pending
    /// list on success or on a permanent (non-network) failure.
    func commit(_ info: UploadTaskInfo) async {
        do {
            try await BackendClient.shared.request(
                "POST",
                "/progress/\(info.progressItemId)/activities/\(info.activityId)/media",
                body: CommitBody(
                    mediaId: info.mediaId,
                    storagePath: info.storagePath,
                    thumbnailStoragePath: info.thumbnailStoragePath,
                    type: info.type,
                    width: info.width,
                    height: info.height,
                    durationSeconds: info.durationSeconds
                )
            )
            drop(mediaId: info.mediaId)
            await MainActor.run { uploadCenter.remove(mediaId: info.mediaId) }
        } catch let error as BackendError where error.code != "network" {
            // Permanent (e.g. the object never made it) — stop retrying.
            drop(mediaId: info.mediaId)
            await MainActor.run { uploadCenter.markFailed(mediaId: info.mediaId) }
        } catch {
            // Transient/network — keep it for the next reconcile.
        }
    }

    /// Retries all pending commits — call on app foreground/launch.
    func reconcile() async {
        for info in load() { await commit(info) }
    }
}
