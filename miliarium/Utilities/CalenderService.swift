import Foundation
import FirebaseFirestore
import OSLog

/// Service for managing calendars and calendar events in Firestore
class CalendarService {
    private let db = Firestore.firestore()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.miliarium", category: "CalendarService")
    
    // MARK: - Calendar Operations
    
    func createCalendar(progressItemId: String) async throws -> Calendar {
        let calendar = Calendar(progressItemId: progressItemId)
        let calendarRef = db.collection("calendars").document(calendar.id)
        
        try await calendarRef.setData(calendar.asFirestoreMap())
        return calendar
    }
    
    func fetchCalendar(for progressItemId: String) async throws -> Calendar? {
        let snapshot = try await db.collection("calendars")
            .whereField("progressItemId", isEqualTo: progressItemId)
            .limit(to: 1)
            .getDocuments()
        
        return snapshot.documents.first.flatMap { Calendar(document: $0) }
    }
    
    func deleteCalendar(id: String) async throws {
        let eventsSnapshot = try await db.collection("calendars")
            .document(id)
            .collection("events")
            .getDocuments()
        
        let batch = db.batch()
        
        for eventDoc in eventsSnapshot.documents {
            batch.deleteDocument(eventDoc.reference)
        }
        
        batch.deleteDocument(db.collection("calendars").document(id))
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    // MARK: - Event Operations
    
    func addEvent(
        progressItemId: String,
        timestamp: Date,
        title: String,
        description: String? = nil
    ) async throws -> CalendarEvent {
        let event = CalendarEvent(
            progressItemId: progressItemId,
            timestamp: timestamp,
            title: title,
            description: description
        )
        
        let eventRef = db.collection("calendars")
            .whereField("progressItemId", isEqualTo: progressItemId)
            .limit(to: 1)
        
        let snapshot = try await eventRef.getDocuments()
        guard let calendarDoc = snapshot.documents.first else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])
        }
        
        let docRef = db.collection("calendars")
            .document(calendarDoc.documentID)
            .collection("events")
            .document(event.id)
        
        try await docRef.setData(event.asFirestoreMap())
        return event
    }
    
    func fetchEvents(for progressItemId: String) async throws -> [CalendarEvent] {
        guard let calendar = try await fetchCalendar(for: progressItemId) else {
            return []
        }
        
        let snapshot = try await db.collection("calendars")
            .document(calendar.id)
            .collection("events")
            .order(by: "timestamp", descending: false)
            .getDocuments()
        
        return snapshot.documents.compactMap { CalendarEvent(document: $0) }
    }
    
    func fetchEvents(for progressItemId: String, on date: Date) async throws -> [CalendarEvent] {
        let allEvents = try await fetchEvents(for: progressItemId)
        
        let calendar = Foundation.Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        return allEvents.filter { event in
            event.timestamp >= startOfDay && event.timestamp < endOfDay
        }
    }
    
    func updateEvent(_ event: CalendarEvent) async throws {
        guard let calendar = try await fetchCalendar(for: event.progressItemId) else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])
        }
        
        try await db.collection("calendars")
            .document(calendar.id)
            .collection("events")
            .document(event.id)
            .setData(event.asFirestoreMap(), merge: true)
    }
    
    /// Delete an event - with detailed logging
    func deleteEvent(_ eventId: String, from progressItemId: String) async throws {
        logger.debug("🗑️ deleteEvent called. EventID: \(eventId), ProgressItemID: \(progressItemId)")
        
        // Step 1: Fetch calendar
        logger.debug("📋 Fetching calendar...")
        guard let calendar = try await fetchCalendar(for: progressItemId) else {
            let errorMessage = "Calendar not found for progressItemId: \(progressItemId)"
            logger.error("❌ \(errorMessage)")
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        logger.debug("✅ Calendar found: \(calendar.id)")
        
        // Step 2: Build reference
        let eventPath = "calendars/\(calendar.id)/events/\(eventId)"
        logger.debug("📍 Event path: \(eventPath)")
        
        let eventRef = db.collection("calendars")
            .document(calendar.id)
            .collection("events")
            .document(eventId)
        
        // Step 3: Delete
        logger.debug("⏳ Deleting event...")
        do {
            try await eventRef.delete()
            logger.info("✅ Event deleted successfully")
        } catch {
            let nsError = error as NSError
            logger.error("❌ Delete failed. Code: \(nsError.code), Domain: \(nsError.domain), Message: \(error.localizedDescription)")
            
            if error.localizedDescription.contains("Permission denied") {
                logger.warning("⚠️ This appears to be a Firestore permission issue")
            }
            
            throw error
        }
    }
}

let calendarService = CalendarService()
