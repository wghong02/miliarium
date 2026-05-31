import SwiftUI
import WidgetKit
import MapKit

/// Renders one `NearbyMapEntry` in a `systemMedium` widget.
///
/// Three visual states:
/// 1. **No reference point** (`!snapshot.hasCenter`): "Open the app" prompt.
/// 2. **Center but no items**: empty-state map centered on the user.
/// 3. **Center + items**: map auto-fitted to all pins + user location.
struct NearbyMapEntryView: View {
    let entry: NearbyMapEntry

    var body: some View {
        if !entry.snapshot.hasCenter {
            noLocationState
        } else if entry.snapshot.items.isEmpty {
            nothingNearbyState
        } else {
            mapContent
        }
    }

    // MARK: - States

    private var noLocationState: some View {
        VStack(spacing: 6) {
            Image(systemName: "location.slash.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open the app to share location")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Open the Map tab once so the widget knows where “nearby” is.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nothingNearbyState: some View {
        ZStack {
            // Still show the map so the layout doesn't suddenly collapse,
            // just centered on the user with no pins.
            Map(initialPosition: .region(centerOnlyRegion))
                .opacity(0.9)
            VStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("Nothing nearby to do")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var mapContent: some View {
        ZStack(alignment: .topLeading) {
            Map(initialPosition: .region(fittedRegion)) {
                ForEach(entry.snapshot.items) { item in
                    Marker(item.title, systemImage: "mappin.circle.fill",
                           coordinate: CLLocationCoordinate2D(
                            latitude: item.latitude,
                            longitude: item.longitude
                           ))
                    .tint(.red)
                }

                if let lat = entry.snapshot.centerLatitude,
                   let lon = entry.snapshot.centerLongitude {
                    Annotation("You", coordinate: CLLocationCoordinate2D(
                        latitude: lat, longitude: lon
                    )) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }

            // Small floating label on top of the map for context.
            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("Nearby · \(entry.snapshot.items.count)")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
    }

    // MARK: - Region helpers

    /// Bounding box of all item pins + the user's location, with a small
    /// margin so nothing hugs the edges. Always clamps to a minimum span
    /// so a single nearby pin doesn't zoom to street level.
    private var fittedRegion: MKCoordinateRegion {
        var lats: [Double] = entry.snapshot.items.map(\.latitude)
        var lons: [Double] = entry.snapshot.items.map(\.longitude)
        if let lat = entry.snapshot.centerLatitude, let lon = entry.snapshot.centerLongitude {
            lats.append(lat)
            lons.append(lon)
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return centerOnlyRegion
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.02, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    /// Region centered on the user (or 0,0 if the snapshot has no center)
    /// with a city-ish zoom. Used for the "nothing nearby" state.
    private var centerOnlyRegion: MKCoordinateRegion {
        let center = CLLocationCoordinate2D(
            latitude: entry.snapshot.centerLatitude ?? 0,
            longitude: entry.snapshot.centerLongitude ?? 0
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    }
}
