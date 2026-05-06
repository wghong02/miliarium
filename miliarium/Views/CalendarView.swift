import SwiftUI
import Foundation

struct CalendarView: View {
    let progressItemId: String
    let progressTitle: String
    
    @State private var currentDate = Date()
    @State private var selectedDate: Date?
    @State private var events: [CalendarEvent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showAddEvent = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Calendar header with month/year and navigation
                calendarHeader
                    .padding()
                    .background(Color(.systemBackground))
                    .border(Color(.separator), width: 1)
                
                // Month calendar grid
                monthCalendarGrid
                    .padding()
                
                Divider()
                
                // Daily events list
                if let selectedDate = selectedDate {
                    dailyEventsList(for: selectedDate)
                } else {
                    ContentUnavailableView(
                        "Select a date",
                        systemImage: "calendar",
                        description: Text("Tap a date on the calendar to view events.")
                    )
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showAddEvent = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddEvent) {
                AddEventSheet(
                    progressItemId: progressItemId,
                    onEventAdded: { _ in
                        Task {
                            await loadEvents()
                        }
                    }
                )
            }
            .onAppear {
                Task {
                    await loadEvents()
                    selectedDate = currentDate
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var calendarHeader: some View {
        HStack {
            Button(action: previousMonth) {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                Text(monthYearString)
                    .font(.headline)
                Text(progressTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: nextMonth) {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
        }
    }
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentDate)
    }
    
    // MARK: - Calendar Grid
    
    private var monthCalendarGrid: some View {
        VStack(spacing: 8) {
            // Day of week headers
            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            // Days grid
            let days = daysInMonthGrid
            ForEach(0..<days.count, id: \.self) { index in
                if index % 7 == 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { dayOffset in
                            let dayIndex = index + dayOffset
                            if dayIndex < days.count {
                                dayCell(for: days[dayIndex])
                                    .frame(maxWidth: .infinity)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func dayCell(for day: Date?) -> some View {
        VStack(spacing: 4) {
            if let day = day {
                Text("\(Foundation.Calendar.current.component(.day, from: day))")
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundColor(isSelectedDate(day) ? .white : .primary)
                
                // Dot indicator if day has events
                if hasEventsOnDate(day) {
                    Circle()
                        .fill(isSelectedDate(day) ? Color.white.opacity(0.5) : Color.blue)
                        .frame(width: 4, height: 4)
                }
            }
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .background(
            Group {
                if let day = day, isSelectedDate(day) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue)
                } else if let day = day, isCurrentDate(day) {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.blue, lineWidth: 1)
                } else {
                    Color.clear
                }
            }
        )
        .onTapGesture {
            if let day = day {
                selectedDate = day
            }
        }
    }
    
    private var daysInMonthGrid: [Date?] {
        let calendar = Foundation.Calendar.current
        let monthComponents = calendar.dateComponents([.year, .month], from: currentDate)
        
        guard let firstDayOfMonth = calendar.date(from: monthComponents) else {
            return []
        }
        
        let firstWeekday = calendar.component(.weekday, from: firstDayOfMonth) - 1
        let numberOfDaysInMonth = calendar.range(of: .day, in: .month, for: currentDate)?.count ?? 0
        
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        
        for day in 1...numberOfDaysInMonth {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDayOfMonth) {
                days.append(date)
            }
        }
        
        return days
    }
    
    // MARK: - Daily Events List
    
    private func dailyEventsList(for date: Date) -> some View {
        let dateEvents = events.filter { event in
            Foundation.Calendar.current.isDate(event.timestamp, inSameDayAs: date)
        }.sorted { $0.timestamp < $1.timestamp }
        
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Date header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatDate(date))
                            .font(.headline)
                        Text("\(dateEvents.count) event\(dateEvents.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6))
                
                if dateEvents.isEmpty {
                    ContentUnavailableView(
                        "No events",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Add an event to get started.")
                    )
                    .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(dateEvents) { event in
                            eventRow(event)
                                .onTapGesture {
                                    // Could expand event details here
                                }
                        }
                    }
                }
            }
        }
    }
    
    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .font(.caption)
                        Text(event.timeString)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            
            if let description = event.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .border(Color(.separator), width: 1)
    }
    
    // MARK: - Helper Functions
    
    private func isSelectedDate(_ date: Date) -> Bool {
        guard let selectedDate = selectedDate else { return false }
        return Foundation.Calendar.current.isDate(date, inSameDayAs: selectedDate)
    }
    
    private func isCurrentDate(_ date: Date) -> Bool {
        Foundation.Calendar.current.isDate(date, inSameDayAs: Date())
    }
    
    private func hasEventsOnDate(_ date: Date) -> Bool {
        events.contains { event in
            Foundation.Calendar.current.isDate(event.timestamp, inSameDayAs: date)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }
    
    private func previousMonth() {
        currentDate = Foundation.Calendar.current.date(byAdding: .month, value: -1, to: currentDate) ?? currentDate
    }
    
    private func nextMonth() {
        currentDate = Foundation.Calendar.current.date(byAdding: .month, value: 1, to: currentDate) ?? currentDate
    }
    
    // MARK: - Load Events
    
    private func loadEvents() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedEvents = try await calendarService.fetchEvents(for: progressItemId)
            await MainActor.run {
                self.events = fetchedEvents
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - Add Event Sheet

struct AddEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let progressItemId: String
    var onEventAdded: (CalendarEvent) -> Void
    
    @State private var eventTitle = ""
    @State private var eventDescription = ""
    @State private var eventDate = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Event Details") {
                    TextField("Event title", text: $eventTitle)
                        .textInputAutocapitalization(.sentences)
                    
                    TextField("Description (optional)", text: $eventDescription, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(3...5)
                }
                
                Section("Date & Time") {
                    DatePicker(
                        "When",
                        selection: $eventDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addEvent()
                    }
                    .disabled(eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }
    
    private func addEvent() {
        let trimmedTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        
        isSaving = true
        errorMessage = nil
        
        Task {
            do {
                let event = try await calendarService.addEvent(
                    progressItemId: progressItemId,
                    timestamp: eventDate,
                    title: trimmedTitle,
                    description: eventDescription.isEmpty ? nil : eventDescription
                )
                
                await MainActor.run {
                    isSaving = false
                    onEventAdded(event)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        CalendarView(progressItemId: "test-123", progressTitle: "My Goal")
    }
}