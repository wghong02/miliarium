import Foundation
import CoreLocation

@Observable
@MainActor
class LocationService: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    @ObservationIgnored
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    /// Stored so @Observable can track changes; updated by the delegate.
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Most recent successful GPS reading. Persists across `MapView`
    /// appearances so the widget snapshot service can render a "nearby"
    /// map even when MapView isn't currently on screen. `nil` until the
    /// first successful `requestLocation()` callback.
    private(set) var lastKnownCoordinate: CLLocationCoordinate2D?

    var isLocationServiceEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Permission Management

    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    // MARK: - Location Request

    func getCurrentLocation() async throws -> CLLocationCoordinate2D {
        if authorizationStatus != .authorizedWhenInUse && authorizationStatus != .authorizedAlways {
            throw LocationError.permissionDenied
        }

        if !isLocationServiceEnabled {
            throw LocationError.locationServicesDisabled
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            locationContinuation?.resume(throwing: LocationError.noLocationFound)
            locationContinuation = nil
            return
        }

        lastKnownCoordinate = location.coordinate
        locationContinuation?.resume(returning: location.coordinate)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}

enum LocationError: LocalizedError {
    case permissionDenied
    case locationServicesDisabled
    case noLocationFound
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission was denied. Please enable it in Settings."
        case .locationServicesDisabled:
            return "Location services are disabled on this device."
        case .noLocationFound:
            return "Unable to determine your current location."
        case .invalidCoordinate:
            return "Invalid location coordinate."
        }
    }
}

@MainActor let locationService = LocationService()
