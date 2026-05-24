import Foundation
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
    private(set) var invitations: [Invitation] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Cache of resolved sender/recipient profiles, keyed by `userId`.
    /// Used by views to render "name or email" without per-row queries.
    private(set) var userCache: [String: AppUser] = [:]

    private var userId: String?
    private let listenerManager = ListenerManager()

    @MainActor
    func setUserId(_ id: String?) {
        listenerManager.removeListener()
        userId = id
        invitations = []
        userCache = [:]
        errorMessage = nil

        guard let id else {
            isLoading = false
            return
        }

        isLoading = true

        // Service-owned listener; the initial snapshot Firestore delivers
        // populates `invitations`, so no separate "initial fetch" is needed.
        let listener = invitationService.setReceivedInvitationsListener(for: id) { [weak self] invitations in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.invitations = invitations
                self.errorMessage = nil
                self.isLoading = false
                // Resolve sender profiles for display.
                await self.cacheUsers(forIds: invitations.map { $0.fromUserId })
            }
        }
        listenerManager.setListener(listener)
    }

    func acceptInvitation(_ invitation: Invitation) async {
        do {
            try await invitationService.acceptInvitation(invitation.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInvitation(_ invitation: Invitation) async {
        do {
            try await invitationService.declineInvitation(invitation.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func refreshInvitations() async {
        guard let userId else { return }
        do {
            invitations = try await invitationService.fetchReceivedInvitations(for: userId)
            errorMessage = nil
            await cacheUsers(forIds: invitations.map { $0.fromUserId })
        } catch {
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
        do {
            let users = try await userService.fetchUsers(ids: missing)
            for user in users {
                userCache[user.id] = user
            }
        } catch {
            // Best-effort enrichment; do not surface to the UI.
        }
    }
}
