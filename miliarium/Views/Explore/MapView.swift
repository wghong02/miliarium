import SwiftUI
import MapKit
import FirebaseFirestore

/// Plots activities that have a location on a `Map`. Sourced from the unified
/// `progressItems/{id}/activities` collection, filtered in-memory by
/// `hasLocation`. Tapping a pin opens `EditActivitySheet`. The `+` button
/// opens `CreateActivitySheet` with the location dimension pre-toggled and
/// the current device location auto-fetched.
struct MapView: View {
    let progressItemId: String
    let progressTitle: String

    @State private var activitiesWithLocation: [Activity] = []
    @State private var listener: ListenerRegistration?
    @State private var listenerInitialized = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasFitCameraInitially = false

    @State private var showAddActivity = false
    @State private var editingActivity: Activity?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Map(position: $cameraPosition) {
                    ForEach(activitiesWithLocation) { activity in
                        if let coord = activity.coordinate {
                            Annotation(
                                annotationLabel(for: activity),
                                coordinate: CLLocationCoordinate2D(
                                    latitude: coord.latitude,
                                    longitude: coord.longitude
                                )
                            ) {
                                Button {
                                    editingActivity = activity
                                } label: {
                                    annotationView(for: activity)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .mapStyle(.standard)

                if !activitiesWithLocation.isEmpty {
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
            .overlay(alignment: .top) {
                if activitiesWithLocation.isEmpty && !isLoading {
                    VStack(spacing: 6) {
                        Text("No locations yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Tap + to add an activity with a location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 4)
                }
            }
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
                    Button(action: { showAddActivity = true }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddActivity) {
                CreateActivitySheet(
                    progressItemId: progressItemId,
                    initialHasLocation: true
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
            .onAppear {
                if !listenerInitialized {
                    setUpListener()
                    listenerInitialized = true
                }
            }
            .onDisappear {
                listener?.remove()
                listenerInitialized = false
                hasFitCameraInitially = false
            }
            .onChange(of: progressItemId) { _, _ in
                listener?.remove()
                listenerInitialized = false
                activitiesWithLocation = []
                hasFitCameraInitially = false
                setUpListener()
                listenerInitialized = true
            }
        }
    }

    // MARK: - Annotation

    private func annotationLabel(for activity: Activity) -> String {
        if let name = activity.locationName, !name.isEmpty { return name }
        return activity.title
    }

    private func annotationView(for activity: Activity) -> some View {
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

    // MARK: - Data

    private func setUpListener() {
        isLoading = true
        listener = activityService.setActivitiesListener(for: progressItemId) { fetched in
            self.activitiesWithLocation = fetched.filter { $0.hasLocation }
            if !self.hasFitCameraInitially && !self.activitiesWithLocation.isEmpty {
                self.fitCameraToActivities()
                self.hasFitCameraInitially = true
            }
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    /// Set the camera region to a bounding box that includes every pinned
    /// activity, padded slightly so pins aren't on the very edge.
    private func fitCameraToActivities() {
        let coords = activitiesWithLocation.compactMap { $0.coordinate }
        guard !coords.isEmpty else { return }

        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            // Multiply by 1.5 for padding; floor at 0.005 so a single pin
            // doesn't show a zoomed-to-rooftop view.
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.5),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.5)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}
