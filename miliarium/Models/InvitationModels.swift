import Foundation
import FirebaseFirestore

enum InvitationStatus: String, Sendable, Codable {
    case pending
    case accepted
    case declined
    /// Owner-side withdrawal of a pending invitation. Distinct from
    /// `declined` (recipient-side rejection) so the audit trail is clear.
    case revoked
}

/// An invitation references the sender and recipient by `userId` only.
/// Display strings (name / email) are resolved live from `AppUser` docs so
/// they stay current when the user updates their profile.
struct Invitation: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let fromUserId: String
    let toUserId: String
    let progressItemId: String
    let progressItemTitle: String
    var status: InvitationStatus
    let createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: String = UUID().uuidString,
        fromUserId: String,
        toUserId: String,
        progressItemId: String,
        progressItemTitle: String,
        status: InvitationStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fromUserId = fromUserId
        self.toUserId = toUserId
        self.progressItemId = progressItemId
        self.progressItemTitle = progressItemTitle
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let fromUserId = data["fromUserId"] as? String,
              let toUserId = data["toUserId"] as? String,
              let progressItemId = data["progressItemId"] as? String,
              let progressItemTitle = data["progressItemTitle"] as? String,
              let statusString = data["status"] as? String,
              let status = InvitationStatus(rawValue: statusString),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        self.init(
            id: document.documentID,
            fromUserId: fromUserId,
            toUserId: toUserId,
            progressItemId: progressItemId,
            progressItemTitle: progressItemTitle,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    nonisolated func asFirestoreMap() -> [String: Any] {
        [
            "fromUserId": fromUserId,
            "toUserId": toUserId,
            "progressItemId": progressItemId,
            "progressItemTitle": progressItemTitle,
            "status": status.rawValue,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
    }
}
