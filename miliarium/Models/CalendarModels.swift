import Foundation
import FirebaseFirestore

/// A single calendar event associated with a progress item.
struct CalendarEvent: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let progressItemId: String
    var timestamp: Date
    var title: String
    var description: String?
    var attachmentId: String?  // For future use
    
    enum CodingKeys: String, CodingKey {
        case id
        case progressItemId
        case timestamp
        case title
        case description
        case attachmentId
    }
    
    /// Initialize a new calendar event (typically before saving to Firestore)
    nonisolated init(
        id: String = UUID().uuidString,
        progressItemId: String,
        timestamp: Date,
        title: String,
        description: String? = nil,
        attachmentId: String? = nil
    ) {
        self.id = id
        self.progressItemId = progressItemId
        self.timestamp = timestamp
        self.title = title
        self.description = description
        self.attachmentId = attachmentId
    }
    
    /// Parse from Firestore document
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }
        
        guard let progressItemId = data["progressItemId"] as? String,
              let timestamp = (data["timestamp"] as? Timestamp)?.dateValue(),
              let title = data["title"] as? String else {
            return nil
        }
        
        self.init(
            id: document.documentID,
            progressItemId: progressItemId,
            timestamp: timestamp,
            title: title,
            description: data["description"] as? String,
            attachmentId: data["attachmentId"] as? String
        )
    }
    
    /// Convert to Firestore map for saving
    nonisolated func asFirestoreMap() -> [String: Any] {
        var map: [String: Any] = [
            "progressItemId": progressItemId,
            "timestamp": Timestamp(date: timestamp),
            "title": title
        ]
        
        if let description = description {
            map["description"] = description
        }
        
        if let attachmentId = attachmentId {
            map["attachmentId"] = attachmentId
        }
        
        return map
    }
    
    /// Get the date component (ignoring time) for calendar grouping
    nonisolated var dateOnly: Date {
        Foundation.Calendar.current.startOfDay(for: timestamp)
    }
    
    /// Format timestamp as HH:mm
    nonisolated var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    /// Format timestamp as full datetime
    nonisolated var fullDateTimeString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

/// Calendar associated with a progress item
struct Calendar: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let progressItemId: String
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id
        case progressItemId
        case createdAt
        case updatedAt
    }
    
    /// Initialize a new calendar
    nonisolated init(
        id: String = UUID().uuidString,
        progressItemId: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.progressItemId = progressItemId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    /// Parse from Firestore document
    nonisolated init?(document: DocumentSnapshot) {
        guard document.exists, let data = document.data() else { return nil }
        
        guard let progressItemId = data["progressItemId"] as? String,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue() else {
            return nil
        }
        
        self.init(
            id: document.documentID,
            progressItemId: progressItemId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
    
    /// Convert to Firestore map for saving
    nonisolated func asFirestoreMap() -> [String: Any] {
        [
            "progressItemId": progressItemId,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
    }
}

/// Helper to group events by date
struct DateEventGroup: Identifiable {
    let id: Date
    let date: Date
    let events: [CalendarEvent]
    
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}