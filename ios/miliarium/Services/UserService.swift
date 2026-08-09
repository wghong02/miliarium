import Foundation
import OSLog
import FirebaseFirestore

/// CRUD + bulk fetch for `users/{userId}` documents.
class UserService {
    private let db = Firestore.firestore()

    private func usersRef() -> CollectionReference {
        db.collection("users")
    }

    // MARK: - Create / upsert
    //
    // The `users/{uid}` doc is created server-side by the `onAuthUserCreated`
    // auth trigger on signup (backend/accountCreation.ts) — the client no longer
    // upserts it.

    // MARK: - Read

    func fetchUser(id: String) async throws -> AppUser? {
        AppLogger.user.debug("fetchUser id=\(id)")
        do {
            let doc = try await usersRef().document(id).getDocument()
            return AppUser(document: doc)
        } catch {
            AppLogger.user.error("fetchUser failed id=\(id): \(error)")
            throw error
        }
    }

    /// Bulk fetch by user IDs. Reads each doc by ID in parallel rather than
    /// via a `whereField(documentID, in:)` query — a document-ID `in` query is
    /// a collection *list* operation, which security rules must keep locked to
    /// prevent enumeration of the `users` collection; by-ID `get`s don't.
    func fetchUsers(ids: [String]) async throws -> [AppUser] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [] }

        AppLogger.user.debug("fetchUsers count=\(uniqueIds.count)")
        let usersCollection = usersRef()
        do {
            return try await withThrowingTaskGroup(of: AppUser?.self) { group in
                for id in uniqueIds {
                    group.addTask {
                        let doc = try await usersCollection.document(id).getDocument()
                        return AppUser(document: doc)
                    }
                }
                var results: [AppUser] = []
                for try await user in group {
                    if let user { results.append(user) }
                }
                return results
            }
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
    // Account deletion no longer deletes the profile doc from the client. The
    // client deletes only the Auth account (AuthViewModel.deleteAccount); the
    // backend `onAuthUserDeleted` trigger removes `users/{uid}` server-side,
    // which fires the `onUserDeleted` cascade. See backend/accountDeletion.ts.
}

let userService = UserService()
