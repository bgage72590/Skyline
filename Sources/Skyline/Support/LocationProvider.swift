import CoreLocation
import Foundation
import SkylineCore

/// Thin CoreLocation wrapper. Uses one-shot `requestLocation()` (no continuous updates) to save power.
///
/// Permission policy: the system prompt is requested only when the status is `.notDetermined` (never
/// when authorized or denied). The status is read from `locationManagerDidChangeAuthorization`,
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
    private var requestedThisLaunch = false

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

    /// macOS reports `.authorizedAlways` for an allowed app, but newer systems can report
    /// "when in use" (raw 4, not exposed in the macOS SDK) for the same "Allow"; both count,
    /// or refreshes would stop (L5).
    nonisolated static func authorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status.rawValue == 4
    }

    private func handle(_ newStatus: CLAuthorizationStatus) {
        status = newStatus
        switch newStatus {
        case .notDetermined:
            // Only an app that has never been answered is .notDetermined (the stable signing identity in
            // build-app.sh keeps the answer across rebuilds), so this asks once ever. At most once per
            // launch, so an ignored prompt is not re-posted while the app runs.
            if !requestedThisLaunch {
                requestedThisLaunch = true
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

    /// Build 42 (QA build-41 G1): only plausible fixes reach the app. Inaccurate (> 5 km), stale
    /// (> 5 min), invalid fixes are dropped, and a jump of more than 500 km needs a second fix nearby.
    private var filter = LocationFixFilter()

    /// The last accepted place (from the saved fix at launch), so a first bogus fix can't jump far.
    func seed(_ c: Coordinate?) { filter = LocationFixFilter(last: c) }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            LocationFixFilter.Fix(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                                  accuracy: $0.horizontalAccuracy, timestamp: $0.timestamp)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var accepted: CLLocationCoordinate2D?
            var held = false
            for f in fixes {
                switch self.filter.evaluate(f, now: Date()) {
                case .accept: accepted = CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude)
                case .holdForConfirmation: held = true
                default: break
                }
            }
            if let accepted {
                self.retryCount = 0
                self.retryTask?.cancel()
                self.onUpdate?(accepted)
            } else if held {
                // Ask again soon: a real trip is confirmed by the next fix.
                self.retryTask?.cancel()
                self.retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.manager.requestLocation()
                }
            } else {
                self.scheduleRetry()
            }
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
