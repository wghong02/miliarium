import Foundation
import OSLog

/// Reads + edits `users/{userId}` profiles, all via the backend API.
class UserService {

    // MARK: - Create / upsert

    /// Idempotently ensures the caller's `users/{uid}` profile doc exists, via
    /// the backend (`POST /me/ensure`). Called on sign-in. Replaces the old
    /// client-side upsert / auth-creation trigger.
    func ensureProfile() async throws {
        AppLogger.user.debug("ensureProfile")
        try await BackendClient.shared.request("POST", "/me/ensure")
    }

    // MARK: - Read

    func fetchUser(id: String) async throws -> AppUser? {
        AppLogger.user.debug("fetchUser id=\(id)")
        do {
            return try await BackendClient.shared.send("GET", "/users/\(id)")
        } catch {
            AppLogger.user.error("fetchUser failed id=\(id): \(error)")
            throw error
        }
    }

    /// Bulk fetch by user IDs (backend resolves them; no client `users` query).
    func fetchUsers(ids: [String]) async throws -> [AppUser] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [] }

        AppLogger.user.debug("fetchUsers count=\(uniqueIds.count)")
        struct Response: Decodable { let users: [AppUser] }
        do {
            let idsParam = uniqueIds.joined(separator: ",")
            let response: Response = try await BackendClient.shared.send(
                "GET", "/users?ids=\(idsParam)"
            )
            return response.users
        } catch {
            AppLogger.user.error("fetchUsers failed: \(error)")
            throw error
        }
    }

    /// Convenience for resolving a `userId -> display string` map (name when
    /// set, email otherwise) for a set of IDs.
    func fetchDisplayStringsByUserId(ids: [String]) async throws -> [String: String] {
        AppLogger.user.debug("fetchDisplayStringsByUserId count=\(ids.count)")
        do {
            let users = try await fetchUsers(ids: ids)
            return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0.displayString) })
        } catch {
            AppLogger.user.error("fetchDisplayStringsByUserId failed: \(error)")
            throw error
        }
    }

    // MARK: - Update

    /// Sets or clears the user's display name via the backend (`PATCH /me`).
    /// A `nil`/blank name clears it. `userId` is implied by the auth token and
    /// kept only for call-site compatibility.
    func updateName(userId: String, name: String?) async throws {
        AppLogger.user.debug("updateName userId=\(userId) name=\(name ?? "<cleared>")")
        struct Body: Encodable { let name: String? }
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty ?? true) ? nil : cleaned
        do {
            try await BackendClient.shared.request("PATCH", "/me", body: Body(name: value))
            AppLogger.user.debug("updateName succeeded userId=\(userId)")
        } catch {
            AppLogger.user.error("updateName failed userId=\(userId): \(error)")
            throw error
        }
    }

    // MARK: - Delete
    //
    // Account deletion is server-side: AuthViewModel.deleteAccount calls
    // `DELETE /me/account`, which deletes the Auth account (admin) then the
    // `users/{uid}` doc, firing the `onUserDeleted` cascade. See
    // backend/api/users.ts and backend/cascadeDeletes.ts.
}

let userService = UserService()
