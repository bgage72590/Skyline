import CoreLocation
import Foundation

/// Thin CoreLocation wrapper. Uses one-shot `requestLocation()` (no continuous updates) to save power.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onUpdate: ((CLLocationCoordinate2D) -> Void)?
    var onAuthorizationChange: ((Bool) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 2_000
    }

    var isAuthorized: Bool { Self.authorized(manager.authorizationStatus) }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: onAuthorizationChange?(false)
        default: manager.requestLocation()
        }
    }

    func refresh() {
        if isAuthorized { manager.requestLocation() }
    }

    nonisolated static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways // the only "authorized" state on macOS
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in self?.onUpdate?(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures are common (no Wi-Fi); the next refresh retries.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let ok = Self.authorized(manager.authorizationStatus)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChange?(ok)
            if ok { self.manager.requestLocation() }
        }
    }
}
