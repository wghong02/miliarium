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
    @State private var editingEvent: CalendarEvent?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Calendar header
                calendarHeader
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    .border(Color(.separator), width: 1)
                
                // Month calendar grid
                monthCalendarGrid
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                
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
            .sheet(item: $editingEvent) { event in
                EventDetailSheet(
                    event: event,
                    progressItemId: progressItemId,
                    onUpdate: { _ in
                        editingEvent = nil
                        Task {
                            await loadEvents()
                        }
                    },
                    onDelete: {
                        editingEvent = nil
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
        HStack(spacing: 12) {
            Button(action: previousMonth) {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(monthYearString)
                    .font(.subheadline.weight(.semibold))
                Text(progressTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            
            let days = daysInMonthGrid
            let totalWeeks = (days.count + 6) / 7
            
            ForEach(0..<totalWeeks, id: \.self) { weekIndex in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { dayOffset in
                        let dayIndex = weekIndex * 7 + dayOffset
                        if dayIndex < days.count {
                            dayCell(for: days[dayIndex])
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                    }
                }
            }
        }
    }
    
    private func dayCell(for day: Date?) -> some View {
        VStack(spacing: 1) {
            if let day = day {
                Text("\(Foundation.Calendar.current.component(.day, from: day))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isSelectedDate(day) ? .white : .primary)
                
                if hasEventsOnDate(day) {
                    Circle()
                        .fill(isSelectedDate(day) ? Color.white.opacity(0.5) : Color.blue)
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            Group {
                if let day = day, isSelectedDate(day) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue)
                } else if let day = day, isCurrentDate(day) {
                    RoundedRectangle(cornerRadius: 4)
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
        
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatDate(date))
                        .font(.headline)
                    Text("\(dateEvents.count) event\(dateEvents.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))
            
            if dateEvents.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No events",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Add an event to get started.")
                )
                Spacer()
            } else {
                List {
                    ForEach(dateEvents) { event in
                        EventRowView(event: event, onTap: {
                            editingEvent = event
                        }, onDelete: {
                            Task {
                                await deleteEvent(event)
                            }
                        })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
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
    
    // MARK: - Delete Event
    
    private func deleteEvent(_ event: CalendarEvent) async {
        do {
            try await calendarService.deleteEvent(event.id, from: progressItemId)
            await loadEvents()
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete event: \(error.localizedDescription)"
            }
        }
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

// MARK: - Event Row with Swipe Actions

struct EventRowView: View {
    let event: CalendarEvent
    var onTap: () -> Void
    var onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text(event.timeString)
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
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Text("Delete")
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

// MARK: - Event Detail Sheet

struct EventDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let event: CalendarEvent
    let progressItemId: String
    var onUpdate: (CalendarEvent) -> Void
    var onDelete: () -> Void
    
    @State private var title: String
    @State private var description: String
    @State private var date: Date
    @State private var isSaving = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?
    
    init(
        event: CalendarEvent,
        progressItemId: String,
        onUpdate: @escaping (CalendarEvent) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.event = event
        self.progressItemId = progressItemId
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        
        _title = State(initialValue: event.title)
        _description = State(initialValue: event.description ?? "")
        _date = State(initialValue: event.timestamp)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Event Details") {
                    TextField("Event title", text: $title)
                        .textInputAutocapitalization(.sentences)
                    
                    TextField(
                        "Description (optional)",
                        text: $description,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(3...5)
                }
                
                Section("Date & Time") {
                    DatePicker(
                        "When",
                        selection: $date,
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
                
                Section {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Text("Delete")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEvent()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSaving
                    )
                }
            }
            .alert("Delete Event?", isPresented: $showDeleteAlert) {
                Button("Cancel") {
                    showDeleteAlert = false
                }
                Button("Delete", role: .cancel) {
                    Task {
                        await deleteEvent()
                    }
                }
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }
    
    private func saveEvent() {
        let trimmedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        
        guard !trimmedTitle.isEmpty else { return }
        
        isSaving = true
        errorMessage = nil
        
        Task {
            do {
                var updatedEvent = event
                updatedEvent.title = trimmedTitle
                updatedEvent.description = description.isEmpty ? nil : description
                updatedEvent.timestamp = date
                
                try await calendarService.updateEvent(updatedEvent)
                
                await MainActor.run {
                    isSaving = false
                    onUpdate(updatedEvent)
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
    
    private func deleteEvent() async {
        do {
            try await calendarService.deleteEvent(event.id, from: progressItemId)
            
            await MainActor.run {
                onDelete()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    FirebasePreviewRoot {
        CalendarView(progressItemId: "test-123", progressTitle: "My Goal")
    }
}
