import CoreLocation
import Foundation

/// Thin CoreLocation wrapper. Uses one-shot `requestLocation()` (no continuous updates) to save power.
///
/// Permission policy: the system prompt is requested only when the status is `.notDetermined`, and
/// only once ever (remembered in defaults). The status is read from `locationManagerDidChangeAuthorization`,
/// which CoreLocation calls right after the manager is created, never by re-requesting at launch.
/// Failed fixes are retried with backoff (5 s, 20 s, 60 s, then every 5 min) so "My Location" always
/// resolves even when the first `requestLocation()` times out.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    var onUpdate: ((CLLocationCoordinate2D) -> Void)?
    var onAuthorizationChange: ((Bool) -> Void)?
    /// nil until CoreLocation reports the status.
    private(set) var status: CLAuthorizationStatus?
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var started = false

    static let requestedKey = "locationAuthorizationRequested"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 2_000
    }

    var isAuthorized: Bool { status.map(Self.authorized) ?? false }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Sets the delegate; CoreLocation then calls `locationManagerDidChangeAuthorization` with the status.
    func start() {
        guard !started else { return }
        started = true
        manager.delegate = self
    }

    func refresh() {
        if isAuthorized { manager.requestLocation() }
    }

    nonisolated static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways // the only "authorized" state on macOS
    }

    private func handle(_ newStatus: CLAuthorizationStatus) {
        status = newStatus
        switch newStatus {
        case .notDetermined:
            // First launch ever: ask once. Never ask again, even if the status reads undetermined later.
            if !defaults.bool(forKey: Self.requestedKey) {
                defaults.set(true, forKey: Self.requestedKey)
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            retryTask?.cancel()
            onAuthorizationChange?(false)
        default:
            defaults.set(true, forKey: Self.requestedKey)
            onAuthorizationChange?(true)
            manager.requestLocation()
        }
    }

    private func scheduleRetry() {
        guard isAuthorized else { return }
        retryTask?.cancel()
        let delays: [Double] = [5, 20, 60]
        let delay = retryCount < delays.count ? delays[retryCount] : 300
        retryCount += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in
            self?.retryCount = 0
            self?.retryTask?.cancel()
            self?.onUpdate?(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures are common (no Wi-Fi, first fix timing out): retry with backoff.
        Task { @MainActor [weak self] in self?.scheduleRetry() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.handle(status) }
    }
}
