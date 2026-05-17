import Foundation
import FirebaseFirestore

enum InvitationStatus: String, Sendable, Codable {
    case pending
    case accepted
    case declined
}

struct Invitation: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let fromUserId: String
    let fromUserEmail: String
    let toUserId: String
    let toUserEmail: String
    let progressItemId: String
    let progressItemTitle: String
    var status: InvitationStatus
    let createdAt: Date

    nonisolated init(
        id: String = UUID().uuidString,
        fromUserId: String,
        fromUserEmail: String,
        toUserId: String,
        toUserEmail: String,
        progressItemId: String,
        progressItemTitle: String,
        status: InvitationStatus = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fromUserId = fromUserId
        self.fromUserEmail = fromUserEmail
        self.toUserId = toUserId
        self.toUserEmail = toUserEmail
        self.progressItemId = progressItemId
        self.progressItemTitle = progressItemTitle
        self.status = status
        self.createdAt = createdAt
    }

    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let fromUserId = data["fromUserId"] as? String,
              let fromUserEmail = data["fromUserEmail"] as? String,
              let toUserId = data["toUserId"] as? String,
              let toUserEmail = data["toUserEmail"] as? String,
              let progressItemId = data["progressItemId"] as? String,
              let progressItemTitle = data["progressItemTitle"] as? String,
              let statusString = data["status"] as? String,
              let status = InvitationStatus(rawValue: statusString),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        self.init(
            id: document.documentID,
            fromUserId: fromUserId,
            fromUserEmail: fromUserEmail,
            toUserId: toUserId,
            toUserEmail: toUserEmail,
            progressItemId: progressItemId,
            progressItemTitle: progressItemTitle,
            status: status,
            createdAt: createdAt
        )
    }

    nonisolated func asFirestoreMap() -> [String: Any] {
        [
            "fromUserId": fromUserId,
            "fromUserEmail": fromUserEmail,
            "toUserId": toUserId,
            "toUserEmail": toUserEmail,
            "progressItemId": progressItemId,
            "progressItemTitle": progressItemTitle,
            "status": status.rawValue,
            "createdAt": Timestamp(date: createdAt)
        ]
    }
}
