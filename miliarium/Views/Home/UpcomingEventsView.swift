import SwiftUI
import FirebaseFirestore

struct UpcomingEventsView: View {
    let progressItemId: String

    @State private var upcomingEvents: [CalendarEvent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var listener: ListenerRegistration?
    @State private var editingEvent: CalendarEvent?
    @State private var listenerInitialized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Upcoming Events")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if upcomingEvents.isEmpty {
                Text("No upcoming events")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(upcomingEvents.prefix(5)) { event in
                        UpcomingEventRowView(event: event, onTap: {
                            editingEvent = event
                        })
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .sheet(item: $editingEvent) { event in
            EventDetailSheet(
                event: event,
                progressItemId: progressItemId,
                onUpdate: { _ in
                    editingEvent = nil
                    Task {
                        await refreshEvents()
                    }
                },
                onDelete: {
                    editingEvent = nil
                    Task {
                        await refreshEvents()
                    }
                }
            )
        }
        .onAppear {
            if !listenerInitialized {
                setUpListener()
                listenerInitialized = true
            }
        }
        .onDisappear {
            listener?.remove()
            listenerInitialized = false
        }
    }

    private func setUpListener() {
        isLoading = true
        print("[UpcomingEvents] Setting up listener for progress: \(progressItemId)")

        let query = Firestore.firestore()
            .collection("calendars")
            .whereField("progressItemId", isEqualTo: progressItemId)
            .limit(to: 1)

        query.addSnapshotListener { snapshot, error in

            if let error {
                print("[UpcomingEvents] Calendar query error: \(error.localizedDescription)")
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                return
            }

            guard let calendarDoc = snapshot?.documents.first else {
                print("[UpcomingEvents] No calendar found")
                self.upcomingEvents = []
                self.isLoading = false
                return
            }

            let calendarId = calendarDoc.documentID

            // Set up listener for events
            let eventsQuery = Firestore.firestore()
                .collection("calendars")
                .document(calendarId)
                .collection("events")
                .whereField("timestamp", isGreaterThan: Date())
                .order(by: "timestamp", descending: false)

            self.listener = eventsQuery.addSnapshotListener { snapshot, error in
                if let error {
                    print("[UpcomingEvents] Events query error: \(error.localizedDescription)")
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                    return
                }

                guard let snapshot = snapshot else {
                    self.isLoading = false
                    return
                }

                print("[UpcomingEvents] Received \(snapshot.documents.count) upcoming events")
                self.errorMessage = nil
                self.upcomingEvents = snapshot.documents.compactMap { doc in
                    if let event = CalendarEvent(document: doc) {
                        print("[UpcomingEvents] Loaded event: \(event.title)")
                        return event
                    }
                    return nil
                }
                self.isLoading = false
            }
        }
    }

    private func refreshEvents() async {
        isLoading = true
        do {
            let calendarSnapshot = try await Firestore.firestore()
                .collection("calendars")
                .whereField("progressItemId", isEqualTo: progressItemId)
                .limit(to: 1)
                .getDocuments()

            guard let calendarDoc = calendarSnapshot.documents.first else {
                upcomingEvents = []
                isLoading = false
                return
            }

            let calendarId = calendarDoc.documentID

            let eventsSnapshot = try await Firestore.firestore()
                .collection("calendars")
                .document(calendarId)
                .collection("events")
                .whereField("timestamp", isGreaterThan: Date())
                .order(by: "timestamp", descending: false)
                .getDocuments()

            upcomingEvents = eventsSnapshot.documents.compactMap { doc in
                CalendarEvent(document: doc)
            }
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            print("[UpcomingEvents] Refresh error: \(error.localizedDescription)")
        }
    }
}

struct UpcomingEventRowView: View {
    let event: CalendarEvent
    var onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text(event.fullDateTimeString)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let description = event.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(.systemBackground))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

#Preview {
    UpcomingEventsView(progressItemId: "test123")
}
