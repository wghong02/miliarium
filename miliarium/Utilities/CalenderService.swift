import Foundation
import FirebaseFirestore

/// Service for managing calendars and calendar events in Firestore
actor CalendarService {
    private let db = Firestore.firestore()
    
    // MARK: - Calendar Operations
    
    /// Create a new calendar for a progress item (typically called when progress is created)
    func createCalendar(progressItemId: String) async throws -> Calendar {
        let calendar = Calendar(progressItemId: progressItemId)
        let calendarRef = db.collection("calendars").document(calendar.id)
        
        try await calendarRef.setData(calendar.asFirestoreMap())
        return calendar
    }
    
    /// Fetch calendar by progress item ID
    func fetchCalendar(for progressItemId: String) async throws -> Calendar? {
        let snapshot = try await db.collection("calendars")
            .whereField("progressItemId", isEqualTo: progressItemId)
            .limit(to: 1)
            .getDocuments()
        
        return snapshot.documents.first.flatMap { Calendar(document: $0) }
    }
    
    /// Delete calendar (cascades to events)
    func deleteCalendar(id: String) async throws {
        try await db.collection("calendars").document(id).delete()
    }
    
    // MARK: - Event Operations
    
    /// Add a new event to a calendar
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
    
    /// Fetch all events for a calendar
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
    
    /// Fetch events for a specific date
    func fetchEvents(for progressItemId: String, on date: Date) async throws -> [CalendarEvent] {
        let allEvents = try await fetchEvents(for: progressItemId)
        
        // Use Foundation.Calendar to get date components (explicit to avoid name collision)
        let calendar = Foundation.Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        return allEvents.filter { event in
            event.timestamp >= startOfDay && event.timestamp < endOfDay
        }
    }
    
    /// Update an existing event
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
    
    /// Delete an event
    func deleteEvent(_ eventId: String, from progressItemId: String) async throws {
        guard let calendar = try await fetchCalendar(for: progressItemId) else {
            throw NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])
        }
        
        try await db.collection("calendars")
            .document(calendar.id)
            .collection("events")
            .document(eventId)
            .delete()
    }
    
    // MARK: - Listener (Real-time updates)
    
    /// Listen to events for a progress item in real-time
    func listenToEvents(for progressItemId: String, completion: @escaping (Result<[CalendarEvent], Error>) -> Void) -> ListenerRegistration? {
        Task {
            guard let calendar = try await fetchCalendar(for: progressItemId) else {
                completion(.failure(NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Calendar not found"])))
                return
            }
            
            let listener = db.collection("calendars")
                .document(calendar.id)
                .collection("events")
                .order(by: "timestamp", descending: false)
                .addSnapshotListener { snapshot, error in
                    if let error = error {
                        completion(.failure(error))
                        return
                    }
                    
                    guard let snapshot = snapshot else {
                        completion(.failure(NSError(domain: "CalendarService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No snapshot"])))
                        return
                    }
                    
                    let events = snapshot.documents.compactMap { CalendarEvent(document: $0) }
                    completion(.success(events))
                }
            
            // Note: In a real app, you'd want to manage this listener lifecycle
        }
        
        return nil
    }
}

/// Singleton instance for convenience
nonisolated let calendarService = CalendarService()