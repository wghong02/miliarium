import Foundation
import OSLog
import FirebaseFirestore

/// Moderation primitives required for user-generated content (App Store Review
/// Guideline 1.2): reporting objectionable content and blocking abusive users.
///
/// - **Reports** are written to the top-level `reports` collection. They are
///   write-only from the client and reviewed out-of-band (console / admin
///   tooling).
/// - **Blocks** are stored per-user at `users/{uid}/blockedUsers/{blockedId}`.
///   The client filters content from blocked users locally (see
///   `InvitationViewModel`).
final class ModerationService {
    private let db = Firestore.firestore()

    private func blockedRef(for userId: String) -> CollectionReference {
        db.collection("users").document(userId).collection("blockedUsers")
    }

    // MARK: - Reporting

    /// Files a report about `reportedUserId`'s content. `context` identifies
    /// where it was reported from (e.g. `"invitation:<id>"`).
    func reportContent(
        reporterId: String,
        reportedUserId: String,
        context: String,
        details: String? = nil
    ) async throws {
        AppLogger.moderation.debug("reportContent reporter=\(reporterId) reported=\(reportedUserId) context=\(context)")
        struct Body: Encodable {
            let reportedUserId: String
            let context: String
            let details: String?
        }
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await BackendClient.shared.request("POST", "/reports", body: Body(
            reportedUserId: reportedUserId,
            context: context,
            details: (trimmedDetails?.isEmpty ?? true) ? nil : trimmedDetails
        ))
    }

    // MARK: - Blocking

    func blockUser(_ blockedUserId: String, by userId: String) async throws {
        AppLogger.moderation.debug("blockUser blocked=\(blockedUserId) by=\(userId)")
        try await BackendClient.shared.request("PUT", "/me/blocked-users/\(blockedUserId)")
    }

    func unblockUser(_ blockedUserId: String, by userId: String) async throws {
        AppLogger.moderation.debug("unblockUser blocked=\(blockedUserId) by=\(userId)")
        try await BackendClient.shared.request("DELETE", "/me/blocked-users/\(blockedUserId)")
    }

    func fetchBlockedUserIds(for userId: String) async throws -> [String] {
        let snapshot = try await blockedRef(for: userId).getDocuments()
        return snapshot.documents.map { $0.documentID }
    }

    /// Live listener for the set of user IDs this user has blocked. `onChange`
    /// fires on Firestore's queue — callers on `@MainActor` must hop.
    func setBlockedUsersListener(
        for userId: String,
        onChange: @escaping ([String]) -> Void
    ) -> ListenerRegistration {
        blockedRef(for: userId).addSnapshotListener { snapshot, error in
            if let error {
                AppLogger.moderation.error("blockedUsersListener error userId=\(userId): \(error.localizedDescription)")
                return
            }
            guard let snapshot else { return }
            onChange(snapshot.documents.map { $0.documentID })
        }
    }
}

let moderationService = ModerationService()
