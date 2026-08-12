import Foundation
import UIKit
import Observation

/// Live, in-flight media uploads, for the grid to show placeholders with
/// progress while the background session transfers bytes. Completed uploads
/// leave the center (the media listener then shows the committed item).
@Observable
@MainActor
final class UploadCenter {
    struct PendingUpload: Identifiable {
        let id: String          // mediaId
        let activityId: String
        var fraction: Double
        var failed: Bool
        let preview: UIImage?   // local thumbnail for the placeholder
    }

    private(set) var uploads: [PendingUpload] = []

    func add(mediaId: String, activityId: String, preview: UIImage?) {
        uploads.removeAll { $0.id == mediaId }
        uploads.append(PendingUpload(id: mediaId, activityId: activityId,
                                     fraction: 0, failed: false, preview: preview))
    }

    func setProgress(mediaId: String, fraction: Double) {
        if let i = uploads.firstIndex(where: { $0.id == mediaId }) {
            uploads[i].fraction = min(1, fraction)
        }
    }

    func markFailed(mediaId: String) {
        if let i = uploads.firstIndex(where: { $0.id == mediaId }) {
            uploads[i].failed = true
        }
    }

    func remove(mediaId: String) {
        uploads.removeAll { $0.id == mediaId }
    }

    func uploads(forActivity activityId: String) -> [PendingUpload] {
        uploads.filter { $0.activityId == activityId }
    }
}

@MainActor let uploadCenter = UploadCenter()
