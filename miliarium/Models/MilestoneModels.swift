import Foundation
import FirebaseFirestore

enum MilestoneType: String, Sendable, Codable {
    case count
    case achievement
    case timeline
}

struct Milestone: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var name: String
    let type: MilestoneType
    var createdAt: Date
    var updatedAt: Date

    // Type-specific fields
    var counter: Int?          // For count type
    var completed: Bool?       // For achievement type
    var targetDate: Date?      // For timeline type

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case createdAt
        case updatedAt
        case counter
        case completed
        case targetDate
    }

    // MARK: - Initializers

    nonisolated init(
        id: String = UUID().uuidString,
        name: String,
        type: MilestoneType,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        counter: Int? = nil,
        completed: Bool? = nil,
        targetDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.counter = counter
        self.completed = completed
        self.targetDate = targetDate
    }

    /// Parse from Firestore document
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }

        guard let name = data["name"] as? String,
              let typeString = data["type"] as? String,
              let type = MilestoneType(rawValue: typeString),
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }

        self.init(
            id: document.documentID,
            name: name,
            type: type,
            createdAt: createdAt,
            updatedAt: updatedAt,
            counter: data["counter"] as? Int,
            completed: data["completed"] as? Bool,
            targetDate: (data["targetDate"] as? Timestamp)?.dateValue()
        )
    }

    /// Convert to Firestore map for saving
    nonisolated func asFirestoreMap() -> [String: Any] {
        var map: [String: Any] = [
            "name": name,
            "type": type.rawValue,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]

        if let counter = counter {
            map["counter"] = counter
        }
        if let completed = completed {
            map["completed"] = completed
        }
        if let targetDate = targetDate {
            map["targetDate"] = Timestamp(date: targetDate)
        }

        return map
    }

    // MARK: - Progress helpers

    nonisolated var progressDisplay: String {
        switch type {
        case .count:
            return "\(counter ?? 0)"
        case .achievement:
            return completed ?? false ? "✓ Completed" : "○ Pending"
        case .timeline:
            if let date = targetDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return formatter.string(from: date)
            }
            return "No date set"
        }
    }

    nonisolated var isCompleted: Bool {
        switch type {
        case .count:
            return false // Count milestones don't have a completion state
        case .achievement:
            return completed ?? false
        case .timeline:
            return targetDate.map { $0 < Date() } ?? false
        }
    }
}
