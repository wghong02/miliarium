import Foundation
import OSLog
import Observation
import FirebaseFirestore

/// Non-MainActor wrapper so the listener can be removed from `deinit`
/// (which is `nonisolated`) without crossing actor boundaries.
private final class ListenerManager {
    var listener: ListenerRegistration?

    func setListener(_ newListener: ListenerRegistration?) {
        listener?.remove()
        listener = newListener
    }

    func removeListener() {
        listener?.remove()
        listener = nil
    }

    deinit {
        removeListener()
    }
}

@Observable
@MainActor
final class InvitationViewModel {
    /// Invitations shown to the UI: received invitations with any from a
    /// blocked sender filtered out (Guideline 1.2).
    private(set) var invitations: [Invitation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Cache of resolved sender/recipient profiles, keyed by `userId`.
    /// Used by views to render "name or email" without per-row queries.
    private(set) var userCache: [String: AppUser] = [:]

    /// Set of user IDs this user has blocked. Kept live so newly-blocked
    /// senders disappear from the list immediately.
    private(set) var blockedUserIds: Set<String> = []

    /// Unfiltered received invitations; `invitations` is derived from this by
    /// removing blocked senders.
    private var allReceived: [Invitation] = []

    private var userId: String?
    private let listenerManager = ListenerManager()
    private let blockedListenerManager = ListenerManager()

    @MainActor
    func setUserId(_ id: String?) {
        listenerManager.removeListener()
        blockedListenerManager.removeListener()
        userId = id
        invitations = []
        allReceived = []
        blockedUserIds = []
        userCache = [:]
        errorMessage = nil

        guard let id else {
            isLoading = false
            AppLogger.invitationVM.debug("setUserId: cleared (signed out)")
            return
        }

        AppLogger.invitationVM.debug("setUserId userId=\(id)")
        isLoading = true

        // Service-owned listener; the initial snapshot Firestore delivers
        // populates `invitations`, so no separate "initial fetch" is needed.
        let listener = invitationService.setReceivedInvitationsListener(for: id) { [weak self] invitations in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.allReceived = invitations
                self.applyBlockFilter()
                self.errorMessage = nil
                self.isLoading = false
                // Resolve sender profiles for display.
                await self.cacheUsers(forIds: invitations.map { $0.fromUserId })
            }
        }
        listenerManager.setListener(listener)

        // Keep the blocked-user set live so filtering reacts immediately.
        let blockedListener = moderationService.setBlockedUsersListener(for: id) { [weak self] ids in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.blockedUserIds = Set(ids)
                self.applyBlockFilter()
            }
        }
        blockedListenerManager.setListener(blockedListener)
    }

    private func applyBlockFilter() {
        invitations = allReceived.filter { !blockedUserIds.contains($0.fromUserId) }
    }

    // MARK: - Moderation (Guideline 1.2)

    /// Reports the sender of an invitation for objectionable content/abuse.
    func reportSender(of invitation: Invitation) async {
        guard let userId else { return }
        do {
            try await moderationService.reportContent(
                reporterId: userId,
                reportedUserId: invitation.fromUserId,
                context: "invitation:\(invitation.id)"
            )
            errorMessage = nil
        } catch {
            AppLogger.invitationVM.error("reportSender failed id=\(invitation.id): \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Blocks the sender of an invitation; they immediately disappear from the
    /// list and can't be seen again until unblocked (from Profile).
    func blockSender(of invitation: Invitation) async {
        guard let userId else { return }
        do {
            try await moderationService.blockUser(invitation.fromUserId, by: userId)
            errorMessage = nil
        } catch {
            AppLogger.invitationVM.error("blockSender failed id=\(invitation.id): \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Returns `true` when the invitation was accepted; `false` (with
    /// `errorMessage` set) when it failed — e.g. the progress is already full.
    @discardableResult
    func acceptInvitation(_ invitation: Invitation) async -> Bool {
        AppLogger.invitationVM.debug("acceptInvitation id=\(invitation.id)")
        do {
            try await invitationService.acceptInvitation(invitation.id)
            errorMessage = nil
            return true
        } catch {
            AppLogger.invitationVM.error("acceptInvitation failed id=\(invitation.id): \(error)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func declineInvitation(_ invitation: Invitation) async {
        AppLogger.invitationVM.debug("declineInvitation id=\(invitation.id)")
        do {
            try await invitationService.declineInvitation(invitation.id)
            errorMessage = nil
        } catch {
            AppLogger.invitationVM.error("declineInvitation failed id=\(invitation.id): \(error)")
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func refreshInvitations() async {
        guard let userId else { return }
        AppLogger.invitationVM.debug("refreshInvitations userId=\(userId)")
        do {
            allReceived = try await invitationService.fetchReceivedInvitations(for: userId)
            applyBlockFilter()
            errorMessage = nil
            await cacheUsers(forIds: allReceived.map { $0.fromUserId })
        } catch {
            AppLogger.invitationVM.error("refreshInvitations failed userId=\(userId): \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// View helper: returns the best display string for an invitation's
    /// sender (or any other user id). Falls back to "Loading…" while the
    /// profile is being fetched.
    func displayString(for userId: String) -> String {
        userCache[userId]?.displayString ?? "Loading…"
    }

    /// Fetches any `AppUser` profiles not already in the cache and stores
    /// them. Silent on failure — the UI will keep showing the placeholder.
    private func cacheUsers(forIds ids: [String]) async {
        let missing = Array(Set(ids).subtracting(userCache.keys))
        guard !missing.isEmpty else { return }
        AppLogger.invitationVM.debug("cacheUsers fetching \(missing.count) uncached profiles")
        do {
            let users = try await userService.fetchUsers(ids: missing)
            for user in users {
                userCache[user.id] = user
            }
        } catch {
            // Best-effort enrichment; do not surface to the UI.
            AppLogger.invitationVM.error("cacheUsers failed: \(error)")
        }
    }
}
