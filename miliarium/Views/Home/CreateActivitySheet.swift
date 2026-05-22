import SwiftUI
import CoreLocation

// MARK: - Create

/// Form for creating a new `Activity`. The activity can opt into any
/// combination of the three optional dimensions (time / location /
/// completion) plus belong to one or more `ActivityCollection`s.
struct CreateActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let progressItemId: String
    let initialTimestamp: Date?
    var onActivityCreated: () -> Void = {}

    init(
        progressItemId: String,
        initialTimestamp: Date? = nil,
        onActivityCreated: @escaping () -> Void = {}
    ) {
        self.progressItemId = progressItemId
        self.initialTimestamp = initialTimestamp
        self.onActivityCreated = onActivityCreated

        // When opened from the Calendar tab we want the time dimension
        // already enabled and the date pre-filled to the selected day.
        if let initialTimestamp {
            _hasTime = State(initialValue: true)
            _timestamp = State(initialValue: initialTimestamp)
        }
    }

    // Text dimension
    @State private var title = ""
    @State private var notes = ""

    // Time dimension
    @State private var hasTime = false
    @State private var timestamp = Date()

    // Location dimension
    @State private var hasLocation = false
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var locationName = ""

    // Completion dimension
    @State private var trackCompletion = false
    @State private var isCompleted = false

    // Collection multi-select
    @State private var availableCollections: [ActivityCollection] = []
    @State private var selectedCollectionIds: Set<String> = []
    @State private var isLoadingCollections = true

    // Submission state
    @State private var isCreating = false
    @State private var isFetchingLocation = false
    @State private var errorMessage: String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedTitle.isEmpty
            && !selectedCollectionIds.isEmpty
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                timeSection
                locationSection
                completionSection
                collectionsFormSection

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: createActivity) {
                        if isCreating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Create Activity")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .navigationTitle("New Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadCollections() }
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section("Activity") {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...5)
        }
    }

    private var timeSection: some View {
        Section("Time") {
            Toggle("Has time", isOn: $hasTime)
            if hasTime {
                DatePicker(
                    "When",
                    selection: $timestamp,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            Toggle("Has location", isOn: $hasLocation)
            if hasLocation {
                Button(action: fetchCurrentLocation) {
                    HStack {
                        if isFetchingLocation {
                            ProgressView()
                        } else {
                            Image(systemName: "location.circle.fill")
                        }
                        Text(isFetchingLocation ? "Getting location..." : "Use current location")
                    }
                }
                .disabled(isFetchingLocation)

                TextField("Location name (optional)", text: $locationName)
                    .textInputAutocapitalization(.words)

                if let lat = latitude, let lon = longitude {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.5f, %.5f", lat, lon))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var completionSection: some View {
        Section("Completion") {
            Toggle("Track completion", isOn: $trackCompletion)
            if trackCompletion {
                Toggle("Completed", isOn: $isCompleted)
            }
        }
    }

    private var collectionsFormSection: some View {
        Section {
            if isLoadingCollections {
                HStack {
                    ProgressView()
                    Text("Loading collections...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if availableCollections.isEmpty {
                Text("No collections available. Create one first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableCollections) { collection in
                    Button {
                        toggleCollection(collection.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedCollectionIds.contains(collection.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(
                                    selectedCollectionIds.contains(collection.id)
                                        ? Color.blue
                                        : Color.secondary
                                )
                            Text(collection.name)
                                .foregroundStyle(.primary)
                            if collection.isDefault {
                                Text("default")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(3)
                            }
                            Spacer()
                            if collection.isFavourite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Collections")
                Spacer()
                if !selectedCollectionIds.isEmpty {
                    Text("\(selectedCollectionIds.count) selected")
                        .font(.caption)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if selectedCollectionIds.isEmpty {
                Text("Select at least one collection.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func toggleCollection(_ id: String) {
        if selectedCollectionIds.contains(id) {
            selectedCollectionIds.remove(id)
        } else {
            selectedCollectionIds.insert(id)
        }
    }

    private func loadCollections() async {
        do {
            let fetched = try await activityCollectionService.fetchCollections(for: progressItemId)
            await MainActor.run {
                self.availableCollections = fetched
                if let defaultCollection = fetched.first(where: { $0.isDefault }) {
                    self.selectedCollectionIds.insert(defaultCollection.id)
                }
                self.isLoadingCollections = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoadingCollections = false
            }
        }
    }

    private func fetchCurrentLocation() {
        isFetchingLocation = true
        errorMessage = nil

        Task { @MainActor in
            do {
                if locationService.authorizationStatus == .notDetermined {
                    locationService.requestLocationPermission()
                    try await Task.sleep(for: .seconds(0.5))
                }
                let coord = try await locationService.getCurrentLocation()
                latitude = coord.latitude
                longitude = coord.longitude
                isFetchingLocation = false
            } catch {
                errorMessage = "Couldn't get location: \(error.localizedDescription)"
                isFetchingLocation = false
            }
        }
    }

    private func createActivity() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                _ = try await activityService.createActivity(
                    progressItemId: progressItemId,
                    title: trimmedTitle,
                    notes: cleanedNotes.isEmpty ? nil : cleanedNotes,
                    timestamp: hasTime ? timestamp : nil,
                    latitude: hasLocation ? latitude : nil,
                    longitude: hasLocation ? longitude : nil,
                    locationName: hasLocation && !cleanedLocationName.isEmpty ? cleanedLocationName : nil,
                    isCompleted: trackCompletion ? isCompleted : nil,
                    collectionIds: Array(selectedCollectionIds)
                )
                await MainActor.run {
                    isCreating = false
                    onActivityCreated()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Edit

/// Form for editing an existing `Activity`. Same fields as `CreateActivitySheet`
/// but pre-populated and with a delete action.
struct EditActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let activity: Activity
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var title = ""
    @State private var notes = ""
    @State private var hasTime = false
    @State private var timestamp = Date()
    @State private var hasLocation = false
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var locationName = ""
    @State private var trackCompletion = false
    @State private var isCompleted = false

    @State private var availableCollections: [ActivityCollection] = []
    @State private var selectedCollectionIds: Set<String> = []
    @State private var isLoadingCollections = true

    @State private var isUpdating = false
    @State private var isFetchingLocation = false
    @State private var showDeleteAlert = false
    @State private var errorMessage: String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canUpdate: Bool {
        !trimmedTitle.isEmpty
            && !selectedCollectionIds.isEmpty
            && !isUpdating
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                timeSection
                locationSection
                completionSection
                collectionsFormSection

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button(action: updateActivity) {
                        if isUpdating {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Update Activity")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(!canUpdate)
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
            .navigationTitle("Edit Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
            .onAppear { prefill() }
            .task { await loadCollections() }
            .alert("Delete Activity?", isPresented: $showDeleteAlert) {
                Button("Cancel") {
                    showDeleteAlert = false
                }
                Button("Delete", role: .cancel) {
                    Task { await deleteActivity() }
                }
            } message: {
                Text("This action cannot be undone.")
            }
        }
    }

    // MARK: - Sections (same shape as create)

    private var detailsSection: some View {
        Section("Activity") {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...5)
        }
    }

    private var timeSection: some View {
        Section("Time") {
            Toggle("Has time", isOn: $hasTime)
            if hasTime {
                DatePicker(
                    "When",
                    selection: $timestamp,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            Toggle("Has location", isOn: $hasLocation)
            if hasLocation {
                Button(action: fetchCurrentLocation) {
                    HStack {
                        if isFetchingLocation {
                            ProgressView()
                        } else {
                            Image(systemName: "location.circle.fill")
                        }
                        Text(isFetchingLocation ? "Getting location..." : "Use current location")
                    }
                }
                .disabled(isFetchingLocation)

                TextField("Location name (optional)", text: $locationName)
                    .textInputAutocapitalization(.words)

                if let lat = latitude, let lon = longitude {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.5f, %.5f", lat, lon))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var completionSection: some View {
        Section("Completion") {
            Toggle("Track completion", isOn: $trackCompletion)
            if trackCompletion {
                Toggle("Completed", isOn: $isCompleted)
            }
        }
    }

    private var collectionsFormSection: some View {
        Section {
            if isLoadingCollections {
                HStack {
                    ProgressView()
                    Text("Loading collections...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if availableCollections.isEmpty {
                Text("No collections available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableCollections) { collection in
                    Button {
                        toggleCollection(collection.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedCollectionIds.contains(collection.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(
                                    selectedCollectionIds.contains(collection.id)
                                        ? Color.blue
                                        : Color.secondary
                                )
                            Text(collection.name)
                                .foregroundStyle(.primary)
                            if collection.isDefault {
                                Text("default")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(3)
                            }
                            Spacer()
                            if collection.isFavourite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Collections")
                Spacer()
                if !selectedCollectionIds.isEmpty {
                    Text("\(selectedCollectionIds.count) selected")
                        .font(.caption)
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if selectedCollectionIds.isEmpty {
                Text("Select at least one collection.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func toggleCollection(_ id: String) {
        if selectedCollectionIds.contains(id) {
            selectedCollectionIds.remove(id)
        } else {
            selectedCollectionIds.insert(id)
        }
    }

    private func prefill() {
        title = activity.title
        notes = activity.notes ?? ""
        hasTime = activity.timestamp != nil
        timestamp = activity.timestamp ?? Date()
        hasLocation = activity.hasLocation
        latitude = activity.latitude
        longitude = activity.longitude
        locationName = activity.locationName ?? ""
        trackCompletion = activity.isCompleted != nil
        isCompleted = activity.isCompleted ?? false
        selectedCollectionIds = Set(activity.collectionIds)
    }

    private func loadCollections() async {
        do {
            let fetched = try await activityCollectionService.fetchCollections(for: progressItemId)
            await MainActor.run {
                self.availableCollections = fetched
                self.isLoadingCollections = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoadingCollections = false
            }
        }
    }

    private func fetchCurrentLocation() {
        isFetchingLocation = true
        errorMessage = nil

        Task { @MainActor in
            do {
                if locationService.authorizationStatus == .notDetermined {
                    locationService.requestLocationPermission()
                    try await Task.sleep(for: .seconds(0.5))
                }
                let coord = try await locationService.getCurrentLocation()
                latitude = coord.latitude
                longitude = coord.longitude
                isFetchingLocation = false
            } catch {
                errorMessage = "Couldn't get location: \(error.localizedDescription)"
                isFetchingLocation = false
            }
        }
    }

    private func updateActivity() {
        guard canUpdate else { return }
        isUpdating = true
        errorMessage = nil

        let cleanedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedLocationName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the double-optional parameters: .some(value) to set,
        // .some(nil) to explicitly clear, nil (outer) to leave untouched.
        // Since this form represents the full state every time, we always
        // pass .some(...) for every field.
        let notesParam: String?? = cleanedNotes.isEmpty ? .some(nil) : .some(cleanedNotes)
        let timestampParam: Date?? = hasTime ? .some(timestamp) : .some(nil)
        let latitudeParam: Double?? = hasLocation ? .some(latitude) : .some(nil)
        let longitudeParam: Double?? = hasLocation ? .some(longitude) : .some(nil)
        let locationNameParam: String??
        if hasLocation && !cleanedLocationName.isEmpty {
            locationNameParam = .some(cleanedLocationName)
        } else {
            locationNameParam = .some(nil)
        }
        let isCompletedParam: Bool?? = trackCompletion ? .some(isCompleted) : .some(nil)

        Task {
            do {
                try await activityService.updateActivity(
                    activity,
                    progressItemId: progressItemId,
                    title: trimmedTitle,
                    notes: notesParam,
                    timestamp: timestampParam,
                    latitude: latitudeParam,
                    longitude: longitudeParam,
                    locationName: locationNameParam,
                    isCompleted: isCompletedParam,
                    collectionIds: Array(selectedCollectionIds)
                )
                await MainActor.run {
                    isUpdating = false
                    onDismiss()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isUpdating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteActivity() async {
        do {
            try await activityService.deleteActivity(activity, progressItemId: progressItemId)
            await MainActor.run {
                onDismiss()
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
    CreateActivitySheet(progressItemId: "test123")
}
