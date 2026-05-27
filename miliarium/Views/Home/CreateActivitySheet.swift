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
    let initialHasLocation: Bool
    let initialLatitude: Double?
    let initialLongitude: Double?
    let initialLocationName: String?
    var onActivityCreated: () -> Void = {}

    init(
        progressItemId: String,
        initialTimestamp: Date? = nil,
        initialHasLocation: Bool = false,
        initialLatitude: Double? = nil,
        initialLongitude: Double? = nil,
        initialLocationName: String? = nil,
        onActivityCreated: @escaping () -> Void = {}
    ) {
        self.progressItemId = progressItemId
        self.initialTimestamp = initialTimestamp
        self.initialHasLocation = initialHasLocation
        self.initialLatitude = initialLatitude
        self.initialLongitude = initialLongitude
        self.initialLocationName = initialLocationName
        self.onActivityCreated = onActivityCreated

        // When opened from the Calendar tab we want the time dimension
        // already enabled and the date pre-filled to the selected day.
        if let initialTimestamp {
            _hasTime = State(initialValue: true)
            _timestamp = State(initialValue: initialTimestamp)
        }
        // When opened from the Map tab we want the location dimension
        // already enabled. If coordinates are also passed (e.g. the user
        // tapped a search-result preview pin), we pre-fill them and skip
        // the auto current-location fetch. The passed-in location name is
        // treated as the Apple Maps resolved name, not as a user-entered
        // custom name — so the custom name field stays empty.
        if initialHasLocation || initialLatitude != nil {
            _hasLocation = State(initialValue: true)
            if let initialLatitude { _latitude = State(initialValue: initialLatitude) }
            if let initialLongitude { _longitude = State(initialValue: initialLongitude) }
            if let initialLocationName {
                _resolvedLocationName = State(initialValue: initialLocationName)
            }
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
    /// Apple Maps display name for the resolved coordinate (e.g.
    /// "Eiffel Tower"). Set by the location search field; cleared when
    /// the location is reset.
    @State private var resolvedLocationName: String?
    /// User-entered custom name. Stays empty by default — the placeholder
    /// "Enter custom name" hints at the field.
    @State private var customLocationName = ""

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
        // Collections are optional now — activities with zero collections
        // still appear in the virtual "All activities" view.
        !trimmedTitle.isEmpty && !isCreating
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
            }
            .navigationTitle("New Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create", action: createActivity)
                            .disabled(!canCreate)
                            .bold()
                    }
                }
            }
            .task {
                await loadCollections()
                // Auto-fetch current location only when the caller asked for
                // the location dimension AND didn't pre-fill coordinates.
                if initialHasLocation && latitude == nil {
                    fetchCurrentLocation()
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
                .onChange(of: title) { _, newValue in
                    if newValue.count > TextLimits.name {
                        title = String(newValue.prefix(TextLimits.name))
                    }
                }
        } header: {
            HStack {
                Text("Title")
                Spacer()
                CharacterCounter(count: title.count, limit: TextLimits.name)
            }
        }

        Section("Notes") {
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
                LocationSearchField(
                    resolvedLocationName: $resolvedLocationName,
                    latitude: $latitude,
                    longitude: $longitude
                )

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

                HStack {
                    TextField("Enter custom name", text: $customLocationName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: customLocationName) { _, newValue in
                            if newValue.count > TextLimits.name {
                                customLocationName = String(newValue.prefix(TextLimits.name))
                            }
                        }
                    CharacterCounter(
                        count: customLocationName.count,
                        limit: TextLimits.name
                    )
                }

                if resolvedLocationName != nil || (latitude != nil && longitude != nil) {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                        Text(resolvedLocationName ?? "Current location")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            latitude = nil
                            longitude = nil
                            resolvedLocationName = nil
                            customLocationName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
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
                            Spacer()
                            if collection.isFavorite {
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
            Text("Optional. Activities without a collection still appear in “All activities”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        // Use the user's custom name when provided; otherwise fall back to
        // the resolved Apple Maps name so the saved activity has a
        // meaningful label.
        let cleanedCustomName = customLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLocationName: String? = hasLocation
            ? (cleanedCustomName.isEmpty ? resolvedLocationName : cleanedCustomName)
            : nil

        Task {
            do {
                _ = try await activityService.createActivity(
                    progressItemId: progressItemId,
                    title: trimmedTitle,
                    notes: cleanedNotes.isEmpty ? nil : cleanedNotes,
                    timestamp: hasTime ? timestamp : nil,
                    latitude: hasLocation ? latitude : nil,
                    longitude: hasLocation ? longitude : nil,
                    locationName: finalLocationName,
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
    @State private var resolvedLocationName: String?
    @State private var customLocationName = ""
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
        // Collections are optional — activities with zero collections still
        // appear in the virtual "All activities" view.
        !trimmedTitle.isEmpty && !isUpdating
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

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            TextField("Title", text: $title)
                .textInputAutocapitalization(.sentences)
                .onChange(of: title) { _, newValue in
                    if newValue.count > TextLimits.name {
                        title = String(newValue.prefix(TextLimits.name))
                    }
                }
        } header: {
            HStack {
                Text("Title")
                Spacer()
                CharacterCounter(count: title.count, limit: TextLimits.name)
            }
        }

        Section("Notes") {
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
                LocationSearchField(
                    resolvedLocationName: $resolvedLocationName,
                    latitude: $latitude,
                    longitude: $longitude
                )

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

                HStack {
                    TextField("Enter custom name", text: $customLocationName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: customLocationName) { _, newValue in
                            if newValue.count > TextLimits.name {
                                customLocationName = String(newValue.prefix(TextLimits.name))
                            }
                        }
                    CharacterCounter(
                        count: customLocationName.count,
                        limit: TextLimits.name
                    )
                }

                if resolvedLocationName != nil || (latitude != nil && longitude != nil) {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                        Text(resolvedLocationName ?? "Current location")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            latitude = nil
                            longitude = nil
                            resolvedLocationName = nil
                            customLocationName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
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
                            Spacer()
                            if collection.isFavorite {
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
            Text("Optional. Activities without a collection still appear in “All activities”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        // Show the persisted name in the location display row via
        // resolvedLocationName. customLocationName starts empty so the user
        // can type an override; on save, a non-empty custom name wins over
        // the resolved name (same priority as create).
        resolvedLocationName = activity.locationName
        customLocationName = ""
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
        let cleanedCustomName = customLocationName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the double-optional parameters: .some(value) to set,
        // .some(nil) to explicitly clear, nil (outer) to leave untouched.
        // Since this form represents the full state every time, we always
        // pass .some(...) for every field.
        let notesParam: String?? = cleanedNotes.isEmpty ? .some(nil) : .some(cleanedNotes)
        let timestampParam: Date?? = hasTime ? .some(timestamp) : .some(nil)
        let latitudeParam: Double?? = hasLocation ? .some(latitude) : .some(nil)
        let longitudeParam: Double?? = hasLocation ? .some(longitude) : .some(nil)
        // Custom name wins; otherwise fall back to the resolved Apple Maps
        // name from a fresh search, otherwise clear the field.
        let locationNameParam: String??
        if hasLocation {
            if !cleanedCustomName.isEmpty {
                locationNameParam = .some(cleanedCustomName)
            } else if let resolvedLocationName, !resolvedLocationName.isEmpty {
                locationNameParam = .some(resolvedLocationName)
            } else {
                locationNameParam = .some(nil)
            }
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
