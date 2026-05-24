import Foundation
import FirebaseFirestore

/// App-level user profile stored at `users/{userId}`.
///
/// Named `AppUser` to avoid collision with `FirebaseAuth.User`, which the
/// auth layer uses. The `userId` field intentionally mirrors the document
/// ID so the doc remains self-contained when read out of context (and so
/// `whereField("userId", isEqualTo: ...)` queries are possible — the more
/// idiomatic `FieldPath.documentID()` works too, but the explicit field is
/// friendlier for analytics / exports).
struct AppUser: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let userId: String
    var email: String?
    /// Optional human-friendly name the user can set themselves. Starts as
    /// `nil` on signup; views fall back to `email` when not set.
    var name: String?
    var createdAt: Date
    var updatedAt: Date

    nonisolated init(
        id: String,
        userId: String? = nil,
        email: String? = nil,
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        // Default the explicit `userId` field to the document ID so callers
        // don't have to remember to pass both.
        self.userId = userId ?? id
        self.email = email
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }
        guard let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() else {
            return nil
        }
        // Tolerate older docs missing `updatedAt` / `userId`. Accept either
        // the canonical `name` field or the legacy `displayName` snapshot.
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt
        let name = (data["name"] as? String) ?? (data["displayName"] as? String)
        self.init(
            id: document.documentID,
            userId: data["userId"] as? String ?? document.documentID,
            email: data["email"] as? String,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    nonisolated func asFirestoreMap() -> [String: Any] {
        var map: [String: Any] = [
            "userId": userId,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
        if let email, !email.isEmpty {
            map["email"] = email
        }
        if let name, !name.isEmpty {
            map["name"] = name
        }
        return map
    }

    /// Preferred string to show in UI: name when non-empty, otherwise the
    /// email, otherwise a placeholder. Centralized so every view stays
    /// consistent.
    nonisolated var displayString: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let email, !email.isEmpty {
            return email
        }
        return "Unknown user"
    }
}
