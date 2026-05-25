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

    /// Idempotent: creates the user doc if missing, otherwise backfills any
    /// missing fields (`userId`, `email`). Safe to call on every sign-in.
    func ensureUserExists(userId: String, email: String?) async throws {
        AppLogger.user.debug("ensureUserExists userId=\(userId)")
        do {
            let ref = usersRef().document(userId)
            let doc = try await ref.getDocument()

            if !doc.exists {
                AppLogger.user.debug("ensureUserExists: creating new user doc userId=\(userId)")
                let user = AppUser(id: userId, email: email)
                try await ref.setData(user.asFirestoreMap())
                return
            }

            // Backfill any missing fields without overwriting existing values.
            let data = doc.data() ?? [:]
            var updates: [String: Any] = [:]

            if data["userId"] as? String != userId {
                updates["userId"] = userId
            }
            if let email,
               !email.isEmpty,
               (data["email"] as? String) != email {
                updates["email"] = email
            }

            if !updates.isEmpty {
                AppLogger.user.debug("ensureUserExists: backfilling fields \(updates.keys.joined(separator: ",")) userId=\(userId)")
                updates["updatedAt"] = Timestamp(date: Date())
                try await ref.updateData(updates)
            }
        } catch {
            AppLogger.user.error("ensureUserExists failed userId=\(userId): \(error)")
            throw error
        }
    }

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

    /// Bulk fetch by user IDs. Chunks into 30-item batches to honor
    /// Firestore's `in` query limit.
    func fetchUsers(ids: [String]) async throws -> [AppUser] {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return [] }

        AppLogger.user.debug("fetchUsers count=\(uniqueIds.count)")
        do {
            var results: [AppUser] = []
            var index = 0
            while index < uniqueIds.count {
                let end = min(index + 30, uniqueIds.count)
                let chunk = Array(uniqueIds[index..<end])
                let snapshot = try await usersRef()
                    .whereField(FieldPath.documentID(), in: chunk)
                    .getDocuments()
                results.append(contentsOf: snapshot.documents.compactMap { AppUser(document: $0) })
                index = end
            }
            return results
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

    /// Sets or clears the user's display name.
    func updateName(userId: String, name: String?) async throws {
        AppLogger.user.debug("updateName userId=\(userId) name=\(name ?? "<cleared>")")
        do {
            var updates: [String: Any] = [
                "updatedAt": Timestamp(date: Date())
            ]
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updates["name"] = name
            } else {
                updates["name"] = FieldValue.delete()
            }
            try await usersRef().document(userId).updateData(updates)
            AppLogger.user.debug("updateName succeeded userId=\(userId)")
        } catch {
            AppLogger.user.error("updateName failed userId=\(userId): \(error)")
            throw error
        }
    }
}

let userService = UserService()
