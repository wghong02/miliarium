import Foundation
import FirebaseFirestore

/// Nested payload stored under the `content` map on each `progressItems` document.
struct ProgressContent: Hashable, Sendable, Codable {
    var summary: String
    var body: String

    /// Value-type initializer; not tied to UI (used from Firestore parsing off the main actor).
    nonisolated init(summary: String = "", body: String = "") {
        self.summary = summary
        self.body = body
    }

    nonisolated func asFirestoreMap() -> [String: Any] {
        ["summary": summary, "body": body]
    }

    nonisolated static func fromFirestore(_ value: Any?) -> ProgressContent {
        guard let map = value as? [String: Any] else {
            return ProgressContent()
        }
        return ProgressContent(
            summary: map["summary"] as? String ?? "",
            body: map["body"] as? String ?? ""
        )
    }
}

struct ProgressItem: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var content: ProgressContent

    nonisolated init(id: String, title: String, content: ProgressContent) {
        self.id = id
        self.title = title
        self.content = content
    }

    /// Parsing-only initializer; safe from background tasks (not tied to UI actor).
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }
        let title = data["title"] as? String ?? "Untitled"
        let content = ProgressContent.fromFirestore(data["content"])
        self.init(id: document.documentID, title: title, content: content)
    }
}
