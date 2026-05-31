import SwiftUI
import MapKit
import OSLog
import FirebaseFirestore

/// Plots activities that have a location on a `Map`. Sourced from the unified
/// `progressItems/{id}/activities` collection, filtered in-memory by
/// `hasLocation`.
///
/// Three ways to interact:
/// - **Tap an existing pin** → opens a menu that lets you toggle the activity
///   in/out of any collection, or open `EditActivitySheet` for full editing.
/// - **Search the top-of-screen bar** → an Apple Maps suggestion drops a
///   purple preview pin at that location; tap the preview pin to create a
///   new activity already pre-filled with the search result's coordinates
///   and name.
/// - **`+` in toolbar** → opens `CreateActivitySheet` with current location
///   auto-fetched.
struct MapView: View {
    let progressItemId: String
    let progressTitle: String
    /// Collections list owned by `ExploreSectionView`; used to render the
    /// per-pin "add to collection" menu.
    let collections: [ActivityCollection]
    /// Active collection filter coming from the section view's toolbar
    /// picker. `nil` means show pins from every collection.
    let selectedCollectionId: String?

    @State private var activitiesWithLocation: [Activity] = []
    @State private var activitiesListener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    // MARK: - Span constants
    /// Tightest view: a city (~15 km). Also used when centering on the user's location.
    private let minSpanDelta = 0.135
    /// Widest view: a large region (~50 km).
    private let maxSpanDelta = 0.45

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasFitCameraInitially = false

    // Current location
    @State private var currentLocation: CLLocationCoordinate2D?
    @State private var locationDenied = false

    /// Activities passing both `hasLocation` (already filtered when the
    /// listener writes) and the optional collection filter.
    private var filteredActivitiesWithLocation: [Activity] {
        guard let selectedCollectionId else { return activitiesWithLocation }
        return activitiesWithLocation.filter { $0.collectionIds.contains(selectedCollectionId) }
    }

    /// Coordinate of the next upcoming activity — one with a timestamp in
    /// the future AND a location — within the current collection filter.
    /// Used as the first camera fallback when no device location is
    /// available, so the map opens on what's next on the user's schedule.
    private var nextUpcomingEventCoordinate: CLLocationCoordinate2D? {
        let now = Date()
        let nextEvent = filteredActivitiesWithLocation
            .filter { activity in
                guard let ts = activity.timestamp else { return false }
                return ts > now
            }
            .min { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        guard let coord = nextEvent?.coordinate else { return nil }
        return CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
    }

    /// Coordinate of the most recently added (by `createdAt`) activity with
    /// a location, within the current collection filter. Used as the second
    /// camera fallback when neither GPS nor an upcoming-with-location
    /// activity is available — the activity the user just added is almost
    /// certainly where they want the map to open.
    private var lastAddedActivityCoordinate: CLLocationCoordinate2D? {
        let lastAdded = filteredActivitiesWithLocation
            .max { $0.createdAt < $1.createdAt }
        guard let coord = lastAdded?.coordinate else { return nil }
        return CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude)
    }

    // Search
    @State private var searchModel = LocationSearchModel()
    @State private var isResolvingSearch = false
    @State private var searchPreviewName: String?
    @State private var searchPreviewLat: Double?
    @State private var searchPreviewLon: Double?

    // Sheets
    @State private var showCurrentLocationCreate = false
    @State private var pendingPreviewCreate = false
    @State private var editingActivity: Activity?
    /// Captures the activity targeted by the pin menu's Delete option until
    /// the user confirms or cancels the confirmation dialog. `nil` = no
    /// dialog is open.
    @State private var pendingDeleteActivity: Activity?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                mapContent
                recenterButton
            }
            .overlay(alignment: .top) { topOverlay }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Map")
                            .font(.subheadline.weight(.semibold))
                        Text(progressTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showCurrentLocationCreate = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCurrentLocationCreate) {
                CreateActivitySheet(progressItemId: progressItemId)
            }
            .sheet(isPresented: $pendingPreviewCreate, onDismiss: clearSearchPreview) {
                CreateActivitySheet(
                    progressItemId: progressItemId,
                    initialHasLocation: true,
                    initialLatitude: searchPreviewLat,
                    initialLongitude: searchPreviewLon,
                    initialLocationName: searchPreviewName
                )
            }
            .sheet(item: $editingActivity) { activity in
                EditActivitySheet(
                    activity: activity,
                    progressItemId: progressItemId
                ) {
                    editingActivity = nil
                }
            }
            .confirmationDialog(
                "Delete this activity?",
                isPresented: Binding(
                    get: { pendingDeleteActivity != nil },
                    set: { if !$0 { pendingDeleteActivity = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeleteActivity
            ) { activity in
                Button("Delete", role: .destructive) {
                    Task { await deleteActivity(activity) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { activity in
                Text("“\(activity.title)” will be permanently removed from this progress and any collections it belongs to. This cannot be undone.")
            }
            .onAppear {
                if !listenerInitialized {
                    setUpActivitiesListener()
                    listenerInitialized = true
                }
            }
            .onDisappear {
                tearDownActivitiesListener()
                hasFitCameraInitially = false
            }
            .task {
                await fetchCurrentLocation()
            }
            .onChange(of: locationService.authorizationStatus) { _, status in
                switch status {
                case .authorizedWhenInUse, .authorizedAlways:
                    Task { await fetchCurrentLocation() }
                case .denied, .restricted:
                    locationDenied = true
                default:
                    break
                }
            }
            .onChange(of: progressItemId) { _, _ in
                tearDownActivitiesListener()
                activitiesWithLocation = []
                hasFitCameraInitially = false
                currentLocation = nil
                locationDenied = false
                setUpActivitiesListener()
                listenerInitialized = true
                Task { await fetchCurrentLocation() }
            }
            .onChange(of: selectedCollectionId) { _, _ in
                // When the filter changes, refit the camera so newly
                // visible pins fill the screen instead of being lost off
                // the edge.
                fitCameraToActivities()
            }
        }
    }

    // MARK: - Map content

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()
            ForEach(filteredActivitiesWithLocation) { activity in
                if let coord = activity.coordinate {
                    Annotation(
                        annotationLabel(for: activity),
                        coordinate: CLLocationCoordinate2D(
                            latitude: coord.latitude,
                            longitude: coord.longitude
                        )
                    ) {
                        activityPinMenu(for: activity)
                    }
                }
            }

            if let lat = searchPreviewLat,
               let lon = searchPreviewLon {
                Annotation(
                    searchPreviewName ?? "Searched location",
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                ) {
                    Button {
                        pendingPreviewCreate = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 36, height: 36)
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                                .foregroundStyle(.purple)
                        }
                        .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard)
    }

    /// Tapping a pin opens a Menu with one row per collection (checkmark
    /// when already a member) plus an "Edit details" escape hatch.
    private func activityPinMenu(for activity: Activity) -> some View {
        Menu {
            if collections.isEmpty {
                Text("No collections yet")
            } else {
                Section("Collections") {
                    ForEach(collections) { collection in
                        Button {
                            Task { await toggleMembership(activity: activity, collection: collection) }
                        } label: {
                            if activity.collectionIds.contains(collection.id) {
                                Label(collection.name, systemImage: "checkmark")
                            } else {
                                Text(collection.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                editingActivity = activity
            } label: {
                Label("Edit details", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                pendingDeleteActivity = activity
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 32, height: 32)
                Image(systemName: pinSymbol(for: activity))
                    .font(.title2)
                    .foregroundStyle(pinColor(for: activity))
            }
            .shadow(radius: 2)
        }
    }

    // MARK: - Top overlay (search + status banners)

    @ViewBuilder
    private var topOverlay: some View {
        VStack(spacing: 6) {
            searchBar
            if locationDenied {
                locationWarningBanner
            }
            if !searchModel.results.isEmpty {
                searchResultsCard
            } else if filteredActivitiesWithLocation.isEmpty && !isLoading && searchModel.query.isEmpty {
                emptyStateCard
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var locationWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash.fill")
                .foregroundStyle(.orange)
            Text("Location access unavailable — some features may be limited.")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: isResolvingSearch ? "hourglass" : "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Location On Map", text: $searchModel.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !searchModel.query.isEmpty {
                Button {
                    searchModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var searchResultsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(searchModel.results.prefix(5).enumerated()), id: \.element) { index, result in
                Button {
                    selectSearchResult(result)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "mappin.circle")
                            .foregroundStyle(.blue)
                            .frame(width: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isResolvingSearch)
                if index < min(5, searchModel.results.count) - 1 {
                    Divider()
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var emptyStateCard: some View {
        VStack(spacing: 4) {
            Text("No locations yet")
                .font(.subheadline.weight(.semibold))
            Text("Tap + to add an activity, or search to drop a preview pin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var recenterButton: some View {
        Group {
            if !filteredActivitiesWithLocation.isEmpty {
                Button {
                    fitCameraToActivities()
                } label: {
                    Image(systemName: "scope")
                        .font(.title3)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 2)
                }
                .padding()
            }
        }
    }

    // MARK: - Annotation styling

    private func annotationLabel(for activity: Activity) -> String {
        if let name = activity.locationName, !name.isEmpty { return name }
        return activity.title
    }

    private func pinSymbol(for activity: Activity) -> String {
        if let completed = activity.isCompleted {
            return completed ? "checkmark.circle.fill" : "circle"
        }
        if activity.hasTime { return "clock.fill" }
        return "mappin.circle.fill"
    }

    private func pinColor(for activity: Activity) -> Color {
        if let completed = activity.isCompleted {
            return completed ? .green : .orange
        }
        if activity.hasTime { return .blue }
        return .red
    }

    // MARK: - Search

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        isResolvingSearch = true
        errorMessage = nil
        Task {
            do {
                let item = try await searchModel.resolve(result)
                let coord = LocationSearchModel.coordinate(of: item)
                searchPreviewName = item.name ?? result.title
                searchPreviewLat = coord.latitude
                searchPreviewLon = coord.longitude
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))
                searchModel.clear()
                isResolvingSearch = false
            } catch {
                errorMessage = error.localizedDescription
                isResolvingSearch = false
            }
        }
    }

    private func clearSearchPreview() {
        searchPreviewName = nil
        searchPreviewLat = nil
        searchPreviewLon = nil
    }

    // MARK: - Collection membership

    private func toggleMembership(
        activity: Activity,
        collection: ActivityCollection
    ) async {
        do {
            if activity.collectionIds.contains(collection.id) {
                try await activityService.removeActivity(
                    activity.id,
                    fromCollection: collection.id,
                    progressItemId: progressItemId
                )
            } else {
                try await activityService.addActivity(
                    activity.id,
                    toCollection: collection.id,
                    progressItemId: progressItemId
                )
            }
            // The activities listener will deliver the updated `collectionIds`.
        } catch {
            await MainActor.run {
                errorMessage = "Couldn't update collection: \(error.localizedDescription)"
            }
        }
    }

    /// Permanently deletes the activity (and removes it from every collection
    /// it belonged to, in one atomic batch). The activities listener refreshes
    /// the pins automatically.
    private func deleteActivity(_ activity: Activity) async {
        do {
            try await activityService.deleteActivity(activity, progressItemId: progressItemId)
        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Data

    private func setUpActivitiesListener() {
        isLoading = true
        activitiesListener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.activitiesWithLocation = fetched.filter { $0.hasLocation }
            if !self.hasFitCameraInitially {
                if let loc = self.currentLocation {
                    // 1) GPS wins — start on the user's actual location.
                    self.setCameraToLocation(loc)
                    self.hasFitCameraInitially = true
                } else if let nextCoord = self.nextUpcomingEventCoordinate {
                    // 2) No GPS — show what's next on the schedule.
                    self.setCameraToLocation(nextCoord)
                    self.hasFitCameraInitially = true
                } else if let lastCoord = self.lastAddedActivityCoordinate {
                    // 3) No GPS and no upcoming-with-location — fall back
                    // to the activity the user most recently added, which
                    // is almost certainly where they want the map to open.
                    self.setCameraToLocation(lastCoord)
                    self.hasFitCameraInitially = true
                }
                // 4) No pins at all — leave camera at `.automatic` and
                // let the empty-state overlay guide the user.
            }
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    private func tearDownActivitiesListener() {
        activitiesListener?.remove()
        activitiesListener = nil
        listenerInitialized = false
    }

    // MARK: - Location

    private func fetchCurrentLocation() async {
        switch locationService.authorizationStatus {
        case .notDetermined:
            locationService.requestLocationPermission()
        case .denied, .restricted:
            locationDenied = true
        case .authorizedWhenInUse, .authorizedAlways:
            do {
                let coord = try await locationService.getCurrentLocation()
                let isFirst = currentLocation == nil
                currentLocation = coord
                // Always center on user location the first time we get it,
                // even if we already fit to pins — location takes priority.
                if isFirst {
                    setCameraToLocation(coord)
                    hasFitCameraInitially = true
                }
                // Nudge the widget snapshot service: now that a fresh GPS
                // reading is cached, the nearby-map widget can render even
                // if no Firestore change happens to retrigger it.
                widgetSnapshotService.rebuildSnapshots()
            } catch {
                // GPS failure — not a permission issue; don't show the warning.
                AppLogger.activity.debug("fetchCurrentLocation failed: \(error)")
            }
        @unknown default:
            break
        }
    }

    private func setCameraToLocation(_ coord: CLLocationCoordinate2D) {
        cameraPosition = .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(
                latitudeDelta: minSpanDelta,
                longitudeDelta: minSpanDelta
            )
        ))
    }

    /// Fits the camera to a bounding box that contains every visible pin,
    /// clamped between neighbourhood (minSpanDelta) and city (maxSpanDelta).
    /// Falls back to current location when there are no pins.
    private func fitCameraToActivities() {
        let coords = filteredActivitiesWithLocation.compactMap { $0.coordinate }
        guard !coords.isEmpty else {
            if let loc = currentLocation { setCameraToLocation(loc) }
            return
        }

        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        let center = CLLocationCoordinate2D(
            latitude: ((lats.min()! + lats.max()!) / 2),
            longitude: ((lons.min()! + lons.max()!) / 2)
        )
        let latDelta = max(minSpanDelta, min(maxSpanDelta, (lats.max()! - lats.min()!) * 1.5))
        let lonDelta = max(minSpanDelta, min(maxSpanDelta, (lons.max()! - lons.min()!) * 1.5))
        cameraPosition = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        ))
    }
}
