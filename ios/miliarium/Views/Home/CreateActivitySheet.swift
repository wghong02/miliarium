import SwiftUI
import CoreLocation
import FirebaseAuth

// MARK: - Create

/// Form for creating a new `Activity`. The activity can opt into any
/// combination of the three optional dimensions (time / location /
/// completion) plus belong to one or more `ActivityCollection`s.
struct CreateActivitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OnboardingState.self) private var onboardingState
    @Environment(AuthViewModel.self) private var auth

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

        // When opened from the Calendar tab we want both date and time
        // pre-filled to the selected day.
        if let initialTimestamp {
            _hasStartDate = State(initialValue: true)
            _startDate = State(initialValue: initialTimestamp)
            _hasStartTime = State(initialValue: true)
            _startTime = State(initialValue: initialTimestamp)
        }
        // When opened from the Map tab with explicit coordinates (e.g.
        // the user tapped a search-result preview pin), pre-fill them
        // so the form opens with the location already "set". The
        // passed-in location name is treated as the Apple Maps resolved
        // name, not as a user-entered custom name — so the custom name
        // field stays empty.
        if let initialLatitude { _latitude = State(initialValue: initialLatitude) }
        if let initialLongitude { _longitude = State(initialValue: initialLongitude) }
        if let initialLocationName {
            _resolvedLocationName = State(initialValue: initialLocationName)
        }
        // `initialHasLocation` from older callers is now a no-op — the
        // section is always shown. We accept the parameter for source
        // compatibility but don't act on it.
        _ = initialHasLocation
    }

    // Text dimension
    @State private var title = ""
    @State private var notes = ""

    // Time dimension. Date and time are independently "set" — the UI shows
    // a placeholder until each is filled in. Time rows are hidden when
    // `isAllDay` is true.
    @State private var isAllDay = false
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var hasStartTime = false
    @State private var startTime = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()
    @State private var hasEndTime = false
    @State private var endTime = Date()

    // Location dimension. No gating toggle — the fields are always shown
    // and an activity has a location whenever both `latitude` and
    // `longitude` are set (`hasAnyLocation` below).
    @State private var latitude: Double?
    @State private var longitude: Double?
    /// Apple Maps display name for the resolved coordinate (e.g.
    /// "Eiffel Tower"). Set by the location search field; cleared when
    /// the location is reset.
    @State private var resolvedLocationName: String?
    /// User-entered custom name. Stays empty by default — the placeholder
    /// "Enter custom name" hints at the field.
    @State private var customLocationName = ""

    // Completion dimension — tri-state. `.notTracked` (default) saves as
    // `isCompleted == nil` on the activity; `.pending` saves as `false`;
    // `.completed` saves as `true`. There's no separate gating toggle.
    @State private var completionChoice: CompletionChoice = .notTracked

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
        !trimmedTitle.isEmpty && !isCreating && timeValidationError == nil
    }

    /// `nil` when the time inputs are valid; otherwise a human-readable
    /// reason the form is blocked. Renders inline beneath the time rows.
    private var timeValidationError: String? {
        validateTimeRange(
            isAllDay: isAllDay,
            hasStartDate: hasStartDate, startDate: startDate,
            hasStartTime: hasStartTime, startTime: startTime,
            hasEndDate: hasEndDate, endDate: endDate,
            hasEndTime: hasEndTime, endTime: endTime
        )
    }

    /// True when coordinates are actually set — derived from the latitude
    /// and longitude fields directly (no separate toggle to keep in sync).
    private var hasAnyLocation: Bool {
        latitude != nil && longitude != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                hintSection
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
    private var hintSection: some View {
        if !onboardingState.hasSeenActivitySheetHint {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Only the title is required")
                            .font(.callout.weight(.semibold))
                        Text("Every other field is optional — tap any placeholder (\"-/-/--\", \"--:--\", \"Enter custom name\") to fill it in, or leave it empty. You can edit any of these later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation { onboardingState.markActivitySheetHintSeen() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss hint")
                }
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            TextField("Title (required)", text: $title)
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
            Toggle("All day", isOn: $isAllDay)

            OptionalDatePickerRow(
                label: "Start date",
                placeholder: "-/-/--",
                isSet: $hasStartDate,
                date: $startDate,
                components: .date
            )
            if !isAllDay {
                OptionalDatePickerRow(
                    label: "Start time",
                    placeholder: "--:--",
                    isSet: $hasStartTime,
                    date: $startTime,
                    components: .hourAndMinute
                )
            }

            OptionalDatePickerRow(
                label: "End date",
                placeholder: "-/-/--",
                isSet: $hasEndDate,
                date: $endDate,
                components: .date
            )
            if !isAllDay {
                OptionalDatePickerRow(
                    label: "End time",
                    placeholder: "--:--",
                    isSet: $hasEndTime,
                    date: $endTime,
                    components: .hourAndMinute
                )
            }

            if let error = timeValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            // Always-visible search field. Empty placeholder when nothing
            // is selected. Picking a suggestion fills lat/lon + resolved name.
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

            // "Selected" row only shows once coordinates are actually set.
            // The X clears everything, returning the section to its empty
            // state (placeholders in the search field and custom name).
            if hasAnyLocation {
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

    private var completionSection: some View {
        Section("Completion") {
            Picker("Status", selection: $completionChoice) {
                ForEach(CompletionChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)
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
        // meaningful label. When no coordinates are set, name is nil too.
        let cleanedCustomName = customLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLocationName: String? = hasAnyLocation
            ? (cleanedCustomName.isEmpty ? resolvedLocationName : cleanedCustomName)
            : nil

        Task {
            do {
                _ = try await activityService.createActivity(
                    progressItemId: progressItemId,
                    title: trimmedTitle,
                    notes: cleanedNotes.isEmpty ? nil : cleanedNotes,
                    timestamp: combineDateAndTime(
                        hasDate: hasStartDate, date: startDate,
                        hasTime: hasStartTime, time: startTime,
                        isAllDay: isAllDay
                    ),
                    endTimestamp: combineDateAndTime(
                        hasDate: hasEndDate, date: endDate,
                        hasTime: hasEndTime, time: endTime,
                        isAllDay: isAllDay
                    ),
                    isAllDay: isAllDay && hasStartDate,
                    latitude: latitude,
                    longitude: longitude,
                    locationName: finalLocationName,
                    isCompleted: completionChoice.savedValue,
                    collectionIds: Array(selectedCollectionIds),
                    createdBy: auth.user?.uid
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
    @Environment(OnboardingState.self) private var onboardingState
    @Environment(AuthViewModel.self) private var auth

    let activity: Activity
    let progressItemId: String
    var onDismiss: () -> Void = {}

    @State private var title = ""
    @State private var notes = ""
    @State private var isAllDay = false
    @State private var hasStartDate = false
    @State private var startDate = Date()
    @State private var hasStartTime = false
    @State private var startTime = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()
    @State private var hasEndTime = false
    @State private var endTime = Date()
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var resolvedLocationName: String?
    @State private var customLocationName = ""
    @State private var completionChoice: CompletionChoice = .notTracked

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
        !trimmedTitle.isEmpty && !isUpdating && timeValidationError == nil
    }

    /// `nil` when the time inputs are valid; otherwise a human-readable
    /// reason the form is blocked. Mirrors the validation in
    /// `CreateActivitySheet`.
    private var timeValidationError: String? {
        validateTimeRange(
            isAllDay: isAllDay,
            hasStartDate: hasStartDate, startDate: startDate,
            hasStartTime: hasStartTime, startTime: startTime,
            hasEndDate: hasEndDate, endDate: endDate,
            hasEndTime: hasEndTime, endTime: endTime
        )
    }

    /// True when coordinates are actually set — derived from the latitude
    /// and longitude fields directly (no separate toggle to keep in sync).
    /// Mirrors the helper in `CreateActivitySheet`.
    private var hasAnyLocation: Bool {
        latitude != nil && longitude != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                hintSection
                detailsSection
                timeSection
                locationSection
                completionSection
                collectionsFormSection
                ActivityMediaSection(
                    progressItemId: progressItemId,
                    activityId: activity.id,
                    uploadedBy: auth.user?.uid
                )

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
    private var hintSection: some View {
        if !onboardingState.hasSeenActivitySheetHint {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Only the title is required")
                            .font(.callout.weight(.semibold))
                        Text("Every other field is optional — tap any placeholder (\"-/-/--\", \"--:--\", \"Enter custom name\") to fill it in, or leave it empty. You can edit any of these later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation { onboardingState.markActivitySheetHintSeen() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss hint")
                }
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            TextField("Title (required)", text: $title)
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
            Toggle("All day", isOn: $isAllDay)

            OptionalDatePickerRow(
                label: "Start date",
                placeholder: "-/-/--",
                isSet: $hasStartDate,
                date: $startDate,
                components: .date
            )
            if !isAllDay {
                OptionalDatePickerRow(
                    label: "Start time",
                    placeholder: "--:--",
                    isSet: $hasStartTime,
                    date: $startTime,
                    components: .hourAndMinute
                )
            }

            OptionalDatePickerRow(
                label: "End date",
                placeholder: "-/-/--",
                isSet: $hasEndDate,
                date: $endDate,
                components: .date
            )
            if !isAllDay {
                OptionalDatePickerRow(
                    label: "End time",
                    placeholder: "--:--",
                    isSet: $hasEndTime,
                    date: $endTime,
                    components: .hourAndMinute
                )
            }

            if let error = timeValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            // Always-visible search field. Empty placeholder when nothing
            // is selected. Picking a suggestion fills lat/lon + resolved name.
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

            // "Selected" row only shows once coordinates are actually set.
            // The X clears everything, returning the section to its empty
            // state (placeholders in the search field and custom name).
            if hasAnyLocation {
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

    private var completionSection: some View {
        Section("Completion") {
            Picker("Status", selection: $completionChoice) {
                ForEach(CompletionChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)
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

        // Time: split the stored timestamp(s) into the four independent
        // "is set" + value pairs. Time portions are only marked as set
        // when the activity isn't all-day.
        isAllDay = activity.isAllDay
        if let start = activity.timestamp {
            hasStartDate = true
            startDate = start
            hasStartTime = !activity.isAllDay
            startTime = start
        }
        if let end = activity.endTimestamp {
            hasEndDate = true
            endDate = end
            hasEndTime = !activity.isAllDay
            endTime = end
        }

        latitude = activity.latitude
        longitude = activity.longitude
        // Show the persisted name in the location display row via
        // resolvedLocationName. customLocationName starts empty so the user
        // can type an override; on save, a non-empty custom name wins over
        // the resolved name (same priority as create).
        resolvedLocationName = activity.locationName
        customLocationName = ""
        completionChoice = CompletionChoice.from(activity.isCompleted)
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
        let computedStart = combineDateAndTime(
            hasDate: hasStartDate, date: startDate,
            hasTime: hasStartTime, time: startTime,
            isAllDay: isAllDay
        )
        let computedEnd = combineDateAndTime(
            hasDate: hasEndDate, date: endDate,
            hasTime: hasEndTime, time: endTime,
            isAllDay: isAllDay
        )
        let timestampParam: Date?? = .some(computedStart)
        let endTimestampParam: Date?? = .some(computedEnd)
        let isAllDayParam: Bool? = isAllDay && hasStartDate
        // Always send the current values; nil ⇒ clear. There's no
        // separate "has location" flag — coordinates being nil IS the
        // signal that the activity has no location.
        let latitudeParam: Double?? = .some(latitude)
        let longitudeParam: Double?? = .some(longitude)
        // Custom name wins; otherwise fall back to the resolved Apple
        // Maps name; otherwise clear. When coordinates are absent the
        // name is also cleared.
        let locationNameParam: String??
        if hasAnyLocation {
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
        // Always send the user's choice — `.notTracked` becomes nil
        // server-side, `.pending` is false, `.completed` is true.
        let isCompletedParam: Bool?? = .some(completionChoice.savedValue)

        Task {
            do {
                try await activityService.updateActivity(
                    activity,
                    progressItemId: progressItemId,
                    title: trimmedTitle,
                    notes: notesParam,
                    timestamp: timestampParam,
                    endTimestamp: endTimestampParam,
                    isAllDay: isAllDayParam,
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

// MARK: - Completion (shared by Create + Edit)

/// Three-state completion picker. Maps to the stored `Bool?` field:
/// - `.notTracked` ⇒ `nil` (the activity isn't completion-tracked)
/// - `.pending`    ⇒ `false`
/// - `.completed`  ⇒ `true`
private enum CompletionChoice: Hashable, CaseIterable {
    case notTracked
    case pending
    case completed

    var label: String {
        switch self {
        case .notTracked: return "Not tracked"
        case .pending:    return "Pending"
        case .completed:  return "Completed"
        }
    }

    var savedValue: Bool? {
        switch self {
        case .notTracked: return nil
        case .pending:    return false
        case .completed:  return true
        }
    }

    static func from(_ saved: Bool?) -> CompletionChoice {
        switch saved {
        case .none:        return .notTracked
        case .some(false): return .pending
        case .some(true):  return .completed
        }
    }
}

// MARK: - Time helpers (shared by Create + Edit)

/// A form row that shows a "set" `DatePicker` when filled and a tappable
/// placeholder button when empty. Used for the four time fields so the
/// editor renders every option up-front without a gating section toggle.
private struct OptionalDatePickerRow: View {
    let label: String
    let placeholder: String
    @Binding var isSet: Bool
    @Binding var date: Date
    let components: DatePickerComponents

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            if isSet {
                DatePicker("", selection: $date, displayedComponents: components)
                    .labelsHidden()
                Button {
                    isSet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(label)")
            } else {
                Button {
                    isSet = true
                } label: {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(label)")
            }
        }
    }
}

/// Combines an independently-set date and time pair into a single `Date`,
/// honouring the all-day flag (forces midnight) and the case where only
/// the date is set (also normalized to start-of-day).
///
/// Returns `nil` when no date is set — that's the editor's signal that
/// this side of the time range is unset.
private func combineDateAndTime(
    hasDate: Bool,
    date: Date,
    hasTime: Bool,
    time: Date,
    isAllDay: Bool
) -> Date? {
    guard hasDate else { return nil }
    let cal = Foundation.Calendar.current
    if isAllDay || !hasTime {
        return cal.startOfDay(for: date)
    }
    var components = cal.dateComponents([.year, .month, .day], from: date)
    let timeComponents = cal.dateComponents([.hour, .minute], from: time)
    components.hour = timeComponents.hour
    components.minute = timeComponents.minute
    return cal.date(from: components) ?? date
}

/// Validates the time inputs. Returns `nil` on success or an inline error
/// string to surface beneath the time rows.
private func validateTimeRange(
    isAllDay: Bool,
    hasStartDate: Bool, startDate: Date,
    hasStartTime: Bool, startTime: Date,
    hasEndDate: Bool, endDate: Date,
    hasEndTime: Bool, endTime: Date
) -> String? {
    // End without start is invalid — Activity.endTimestamp without
    // .timestamp is reserved for legacy/imported docs, not user input.
    if hasEndDate, !hasStartDate {
        return "Set a start date before adding an end."
    }
    let start = combineDateAndTime(
        hasDate: hasStartDate, date: startDate,
        hasTime: hasStartTime, time: startTime,
        isAllDay: isAllDay
    )
    let end = combineDateAndTime(
        hasDate: hasEndDate, date: endDate,
        hasTime: hasEndTime, time: endTime,
        isAllDay: isAllDay
    )
    if let start, let end, end <= start {
        return "End must be after start."
    }
    return nil
}
