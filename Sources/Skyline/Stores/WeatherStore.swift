import AppKit
import CoreLocation
import Foundation
import Observation
import SwiftUI
import SkylineCore

/// App-wide state: saved locations, current location, cached reports and refresh scheduling.
///
/// Power policy: one background loop wakes every `refreshMinutes` (default 15, with timer tolerance so
/// macOS can coalesce wake-ups). It refreshes only the menu-bar location unless the main window is
/// actually visible (not occluded/minimised), in which case the sidebar locations are refreshed too.
@MainActor
@Observable
final class WeatherStore {
    let service: WeatherService
    let radar: RadarPlayback

    var savedLocations: [WeatherLocation] = [] { didSet { persistLocations() } }
    var currentLocation: WeatherLocation?
    var selectedID: String? { didSet { defaults.set(selectedID, forKey: Keys.selected) } }
    var reports: [String: WeatherReport] = [:]
    var errors: [String: String] = [:]
    var loadingIDs: Set<String> = []
    var units: UnitPreference { didSet { defaults.set(units.rawValue, forKey: Keys.units) } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh); startRefreshLoop() } }
    var locationDenied = false
    /// True while "My Location" is waiting for its first fix (the sidebar shows a loading row).
    var isLocating = false

    var searchText = ""
    var searchResults: [PlaceSearchResult] = []
    var isSearching = false

    /// Radar map expanded to fill the detail area (in-window, Apple-Weather style).
    var radarExpanded = false
    /// Module detail panel shown over the detail area (tap a module to open).
    var activeModule: ModuleSelection?
    /// Forecast-verification summary per location id (real data; demo only with -SkylineDemoAccuracy).
    var accuracy: [String: AccuracyReport] = [:]
    /// Alert whose outline the radar map should frame and highlight ("Show on Map").
    var focusedAlertID: String?
    /// True while the user drags a chart or radar scrubber (the living background pauses).
    var isScrubbing = false
    /// Bumped to ask the detail area to take keyboard focus (⌘⇧F); views move @FocusState on change.
    var focusContentRequest = 0

    private(set) var isMainWindowVisible = false
    /// Bumped when a report crosses its staleness deadline or an alert ends, so views that show data age
    /// (menu-bar dimming, the offline banner) re-render without polling.
    private(set) var staleTick = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationProvider = LocationProvider()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Quick retries after a failed refresh (1, 2, 4… min, capped at the refresh interval), per location.
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAttempts: [String: Int] = [:]
    /// One sleeping task that wakes at the next staleness deadline / alert end.
    @ObservationIgnored private var housekeepingTask: Task<Void, Never>?

    private enum Keys {
        static let locations = "savedLocations.v1"
        static let selected = "selectedLocationID"
        static let units = "unitPreference"
        static let refresh = "refreshMinutes"
        static let seeded = "seededDefaultLocation"
        static let lastFix = "lastCurrentLocation.v1"
    }

    /// A report younger than this is shown without refetching.
    private let staleAfter: TimeInterval = 10 * 60

    init(service: WeatherService = WeatherStore.makeService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.radar = RadarPlayback(service: service)
        self.defaults = defaults
        self.units = UnitPreference(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .system
        let minutes = defaults.integer(forKey: Keys.refresh)
        self.refreshMinutes = minutes >= 5 ? minutes : 15
        self.selectedID = defaults.string(forKey: Keys.selected)
        if let data = defaults.data(forKey: Keys.locations),
           let saved = try? JSONDecoder().decode([WeatherLocation].self, from: data) {
            self.savedLocations = saved
        }
        if savedLocations.isEmpty && !defaults.bool(forKey: Keys.seeded) {
            // First launch: start with one city so the window isn't empty while location permission is pending.
            savedLocations = [WeatherLocation(name: "New York", region: "New York", country: "United States",
                                              coordinate: Coordinate(latitude: 40.7128, longitude: -74.0060),
                                              timeZoneIdentifier: "America/New_York")]
            defaults.set(true, forKey: Keys.seeded)
            persistLocations()
        }
        if selectedID == nil || !allLocations.contains(where: { $0.id == selectedID }) && selectedID != WeatherLocation.currentLocationID {
            selectedID = savedLocations.first?.id
        }
        // Show "My Location" immediately from the last fix (refined when CoreLocation answers), so the
        // row never goes missing at launch while the first fix is slow.
        if let data = defaults.data(forKey: Keys.lastFix),
           let last = try? JSONDecoder().decode(WeatherLocation.self, from: data) {
            currentLocation = last
        } else {
            isLocating = true
        }
        setUpLocation()
        observeWake()
        startRefreshLoop()
    }

    // MARK: Derived

    var allLocations: [WeatherLocation] {
        (currentLocation.map { [$0] } ?? []) + savedLocations
    }

    var selectedLocation: WeatherLocation? {
        allLocations.first { $0.id == selectedID } ?? allLocations.first
    }

    /// Menu bar follows the device location when available, else the selected / first saved place.
    var menuBarLocation: WeatherLocation? {
        currentLocation ?? selectedLocation
    }

    var menuBarReport: WeatherReport? {
        menuBarLocation.flatMap { reports[$0.id] }
    }

    func isLoading(_ location: WeatherLocation) -> Bool { loadingIDs.contains(location.id) }

    /// Data older than this is flagged as stale (see `DataAge.staleAfter`).
    var staleDataAge: TimeInterval { DataAge.staleAfter(refreshMinutes: refreshMinutes) }

    /// True when the report's data is old, came from the offline cache, or its last refresh failed.
    /// Reads `staleTick`, so callers re-render when the report goes stale with no other change.
    func isStale(_ report: WeatherReport, now: Date = Date()) -> Bool {
        _ = staleTick
        return isOffline(report) || report.dataAge(at: now) > staleDataAge
    }

    /// True when the last refresh for this report's location failed (network or service error).
    func isOffline(_ report: WeatherReport) -> Bool {
        report.isOfflineFallback || errors[report.location.id] != nil
    }

    // MARK: Loading

    func load(_ location: WeatherLocation, force: Bool = false) async {
        if !force, let existing = reports[location.id], errors[location.id] == nil, !existing.isOfflineFallback,
           Date().timeIntervalSince(existing.fetchedAt) < staleAfter,
           existing.location.coordinate == location.coordinate {
            return
        }
        loadingIDs.insert(location.id)
        defer { loadingIDs.remove(location.id) }
        do {
            var report = try await service.report(for: location, forceRefresh: force)
            report.location = location
            if defaults.bool(forKey: "SkylineDemoAlert"), report.alerts.isEmpty { report.alerts = [Self.demoAlert(near: location)] }
            if defaults.bool(forKey: "SkylineDemoRain") { report.minutely = Self.demoRain(from: report.current.time) }
            reports[location.id] = report
            if report.isOfflineFallback {
                // Old data is better than none, but it must say so, and we try again soon.
                setError("Couldn’t reach the weather service; showing saved data.", for: location.id)
                scheduleRetry(location)
            } else {
                if errors[location.id] != nil { errors[location.id] = nil }
                retryTasks.removeValue(forKey: location.id)?.cancel()
                retryAttempts[location.id] = nil
            }
            scheduleHousekeeping()
            await refreshAccuracy(for: location)
        } catch is CancellationError {
        } catch {
            // Keep the error visible even when older data is on screen (shown as the offline banner),
            // withdraw data that is too old to pass for weather, and retry soon.
            setError(Self.describe(error), for: location.id)
            if let existing = reports[location.id], existing.dataAge() > DataAge.maxDisplayAge {
                reports[location.id] = nil
            }
            scheduleRetry(location)
            scheduleHousekeeping()
        }
    }

    private func setError(_ message: String, for id: String) {
        if errors[id] != message { errors[id] = message }
    }

    /// Short readable text for a refresh failure.
    static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "You’re offline."
            case .timedOut: return "The weather service didn’t respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Couldn’t reach the weather service."
            default: return u.localizedDescription
            }
        }
        if let h = error as? HTTPError, case .status(let code, _) = h {
            return code == 429 ? "The weather service is busy (rate limited)." : "The weather service returned an error (\(code))."
        }
        return error.localizedDescription
    }

    /// After a failure, try again in about a minute instead of waiting for the next refresh cycle
    /// (backing off 1 → 2 → 4 … minutes up to the refresh interval while it keeps failing). Only for
    /// locations the user can currently see (menu-bar location, or any when the window is visible).
    private func scheduleRetry(_ location: WeatherLocation) {
        let id = location.id
        guard retryTasks[id] == nil else { return }
        let attempt = retryAttempts[id, default: 0]
        retryAttempts[id] = attempt + 1
        let delay = min(60 * pow(2, Double(min(attempt, 6))), Double(refreshMinutes) * 60)
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard let current = self.allLocations.first(where: { $0.id == id }),
                  self.isMainWindowVisible || self.menuBarLocation?.id == id else { return }
            await self.load(current)
        }
    }

    /// Sleeps until the earliest moment something on screen changes meaning by itself (a report turns
    /// stale, an alert ends), then drops ended alerts and bumps `staleTick`. One wake per deadline, no polling.
    private func scheduleHousekeeping() {
        housekeepingTask?.cancel()
        let now = Date()
        var deadlines: [Date] = []
        for report in reports.values {
            let staleAt = report.dataAsOf.addingTimeInterval(staleDataAge)
            if staleAt > now { deadlines.append(staleAt) }
            deadlines += report.alerts.compactMap(\.endTime).filter { $0 > now }
        }
        guard let next = deadlines.min() else { return }
        housekeepingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 1), tolerance: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.pruneEndedAlerts()
            self.staleTick &+= 1
            self.scheduleHousekeeping()
        }
    }

    private func pruneEndedAlerts() {
        let now = Date()
        for (id, report) in reports where report.alerts.contains(where: { !$0.isActive(at: now) }) {
            var r = report
            r.alerts = report.activeAlerts(at: now)
            reports[id] = r
        }
    }

    /// The real service, or (QA hook `-SkylineSimulateOffline YES|cold`) one whose network always fails:
    /// `YES` keeps the on-disk cache (offline fallback, stale banner), `cold` starts with an empty cache
    /// (error states). Nothing is recorded for verification in either mode.
    nonisolated static func makeService() -> WeatherService {
        let mode = UserDefaults.standard.string(forKey: "SkylineSimulateOffline")?.lowercased()
        switch mode {
        case "yes", "1", "true":
            return WeatherService(client: OfflineHTTPClient())
        case "cold":
            return WeatherService(client: OfflineHTTPClient(), cache: ResponseCache(directory: nil))
        default:
            return WeatherService(verifier: ForecastVerifier())
        }
    }

    func refreshAll(force: Bool) async {
        locationProvider.refresh()
        await refresh(locations: allLocations, force: force)
    }

    /// Called by the periodic loop and after wake.
    func refreshDue() async {
        var targets: [WeatherLocation] = []
        if let m = menuBarLocation { targets.append(m) }
        if isMainWindowVisible { targets += allLocations }
        await refresh(locations: targets, force: false)
    }

    private func refresh(locations: [WeatherLocation], force: Bool) async {
        var seen = Set<String>()
        let unique = locations.filter { seen.insert($0.id).inserted }
        await withTaskGroup(of: Void.self) { group in
            for location in unique {
                group.addTask { await self.load(location, force: force) }
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        let interval = Double(refreshMinutes) * 60
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(90))
            }
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Give Wi-Fi a moment to reconnect.
                try? await Task.sleep(for: .seconds(5))
                self?.locationProvider.refresh()
                await self?.refreshDue()
            }
        }
    }

    func setMainWindowVisible(_ visible: Bool) {
        guard visible != isMainWindowVisible else { return }
        isMainWindowVisible = visible
        if radar.isVisible != visible { radar.isVisible = visible }
        if visible { Task { await refreshDue() } }
    }

    // MARK: Current location

    private func setUpLocation() {
        locationProvider.onUpdate = { [weak self] coordinate in self?.handleLocation(coordinate) }
        locationProvider.onAuthorizationChange = { [weak self] authorized in
            guard let self else { return }
            self.locationDenied = !authorized
            if !authorized { self.isLocating = false }
            if !authorized, self.currentLocation != nil {
                self.currentLocation = nil
                self.defaults.removeObject(forKey: Keys.lastFix)
                if self.selectedID == WeatherLocation.currentLocationID { self.selectedID = self.savedLocations.first?.id }
            }
        }
        locationProvider.start()
    }

    private func handleLocation(_ c: CLLocationCoordinate2D) {
        if isLocating { isLocating = false }
        let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
        if let existing = currentLocation,
           CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 2_000 {
            return
        }
        let isFirstFix = currentLocation == nil
        var location = WeatherLocation(id: WeatherLocation.currentLocationID, name: currentLocation?.name ?? "My Location",
                                       coordinate: coordinate, isCurrentLocation: true)
        location.timeZoneIdentifier = currentLocation?.timeZoneIdentifier
        currentLocation = location
        persistLastFix(location)
        if isFirstFix && (selectedID == nil || selectedID == savedLocations.first?.id) {
            selectedID = location.id
        }
        Task {
            var location = location
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first {
                location.name = placemark.locality ?? placemark.name ?? "My Location"
                location.region = placemark.administrativeArea
                location.country = placemark.country
                location.timeZoneIdentifier = placemark.timeZone?.identifier
                currentLocation = location
                persistLastFix(location)
            }
            await load(location, force: true)
        }
    }

    /// QA hook (`-SkylineDemoAlert YES`): a clearly labelled fake alert so the banner/map outline can be
    /// tested when no real alert is active. Never shown without the launch argument.
    static func demoAlert(near location: WeatherLocation) -> WeatherAlert {
        let c = location.coordinate
        var alert = WeatherAlert(id: "demo-\(location.id)", event: "Test Alert (demo, not real)",
                                 headline: "Demo alert drawn for QA screenshots. This is not an NWS product.",
                                 severity: .severe, urgency: "Expected", areaDescription: "Demo area",
                                 description: "This alert exists only because Skyline was launched with -SkylineDemoAlert YES.",
                                 instruction: nil, effective: Date(), expires: Date().addingTimeInterval(3 * 3600),
                                 ends: nil, senderName: "Skyline QA")
        alert.polygons = [[Coordinate(latitude: c.latitude + 0.35, longitude: c.longitude - 0.55),
                           Coordinate(latitude: c.latitude + 0.25, longitude: c.longitude + 0.5),
                           Coordinate(latitude: c.latitude - 0.3, longitude: c.longitude + 0.45),
                           Coordinate(latitude: c.latitude - 0.2, longitude: c.longitude - 0.6)]]
        return alert
    }

    /// QA hook (`-SkylineDemoRain YES`): a synthetic shower in the nowcast so the "Next 2 Hours"
    /// chart can be checked on a dry day. Never applied without the launch argument.
    static func demoRain(from now: Date) -> [MinutelyPrecipitation] {
        let start = (now.timeIntervalSince1970 / 900).rounded(.down) * 900
        let mm: [Double] = [0, 0, 0.08, 0.3, 0.7, 1.6, 2.4, 1.3, 0.6, 0.35, 0.2, 0.1, 0, 0]
        return mm.enumerated().map { MinutelyPrecipitation(time: Date(timeIntervalSince1970: start + Double($0.offset) * 900), precipitation: $0.element) }
    }

    /// Pulls the verifier's summary for a location (cheap: cached until new pairs arrive).
    func refreshAccuracy(for location: WeatherLocation) async {
        let new: AccuracyReport?
        if defaults.bool(forKey: "SkylineDemoAccuracy") {
            new = AccuracyDemo.report()
        } else {
            new = await service.verifier?.report(VerificationKey.key(for: location))
        }
        if let new, accuracy[location.id] != new { accuracy[location.id] = new }
    }

    // MARK: Keyboard navigation

    /// ↑/↓ (⌘↑/⌘↓ from anywhere): previous/next location in sidebar order.
    func selectLocation(offset: Int) {
        let all = allLocations
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == selectedLocation?.id } ?? 0
        let j = min(max(i + offset, 0), all.count - 1)
        if all[j].id != selectedID { selectedID = all[j].id }
    }

    /// ⌘1–⌘9: the n-th location (1-based) in sidebar order.
    func selectLocation(number n: Int) {
        let all = allLocations
        guard n >= 1, n <= all.count, all[n - 1].id != selectedID else { return }
        selectedID = all[n - 1].id
    }

    func showAlertOnMap(_ alert: WeatherAlert, wideLayout: Bool) {
        focusedAlertID = alert.id
        if !wideLayout && !radarExpanded {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                activeModule = nil
                radarExpanded = true
            }
        }
    }

    // MARK: Saved locations & search

    func searchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300)) // debounce typing
            guard !Task.isCancelled, let self else { return }
            let results = (try? await self.service.search(query)) ?? []
            guard !Task.isCancelled else { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    func add(_ result: PlaceSearchResult) {
        let location = result.asLocation
        if !savedLocations.contains(where: { $0.id == location.id }) {
            savedLocations.append(location)
        }
        selectedID = location.id
        searchText = ""
        searchResults = []
        Task { await load(location) }
    }

    func remove(_ location: WeatherLocation) {
        guard !location.isCurrentLocation else { return }
        savedLocations.removeAll { $0.id == location.id }
        reports[location.id] = nil
        if selectedID == location.id { selectedID = allLocations.first?.id }
    }

    func move(_ location: WeatherLocation, by offset: Int) {
        guard let i = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        let j = i + offset
        guard savedLocations.indices.contains(j) else { return }
        savedLocations.swapAt(i, j)
    }

    private func persistLastFix(_ location: WeatherLocation) {
        if let data = try? JSONEncoder().encode(location) { defaults.set(data, forKey: Keys.lastFix) }
    }

    private func persistLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            defaults.set(data, forKey: Keys.locations)
        }
    }
}
