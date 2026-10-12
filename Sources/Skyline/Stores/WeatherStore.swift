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
/// With the window closed (menu bar only) it wakes at most every `menuBarOnlyMinutes`, refreshes only
/// the menu-bar location, and the window's heavy content (map, radar layers, background) is torn down.
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
    /// The units every view formats with: the preset plus any per-dimension overrides (T20).
    private(set) var units: DisplayUnits = .imperial
    var unitPreset: UnitPreference { didSet { defaults.set(unitPreset.rawValue, forKey: Keys.units); resolveUnits() } }
    var temperatureUnit: TemperatureUnit? { didSet { saveOverride(temperatureUnit?.rawValue, Keys.temperatureUnit) } }
    var speedUnit: SpeedUnit? { didSet { saveOverride(speedUnit?.rawValue, Keys.speedUnit) } }
    var precipitationUnit: PrecipitationUnit? { didSet { saveOverride(precipitationUnit?.rawValue, Keys.precipitationUnit) } }
    var pressureUnit: PressureUnit? { didSet { saveOverride(pressureUnit?.rawValue, Keys.pressureUnit) } }
    var distanceUnit: DistanceUnit? { didSet { saveOverride(distanceUnit?.rawValue, Keys.distanceUnit) } }
    /// 12/24-hour clock for every time shown (T20).
    var clockStyle: ClockStyle { didSet { defaults.set(clockStyle.rawValue, forKey: Keys.clock); Fmt.clock = clockStyle } }
    /// City the menu bar shows (nil = My Location, else the first saved city), chosen in Settings (T10).
    var menuBarPinID: String? { didSet { defaults.set(menuBarPinID, forKey: Keys.menuBarPin) } }
    /// Set by the dropdown's alert line; the main window's alert banner opens that alert and clears it.
    var pendingAlertID: String?
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
    /// False while the main window is closed (menu bar only): ContentView then drops its content, which
    /// frees the MKMapView, radar layers and living background; it's rebuilt when the window reopens.
    private(set) var isMainWindowOpen = true
    /// Bumped when a report crosses its staleness deadline or an alert ends, so views that show data age
    /// (menu-bar dimming, the offline banner) re-render without polling.
    private(set) var staleTick = 0
    /// The status-item image (icon + temperature, dimmed when stale), rendered here whenever one of its
    /// inputs changes, on a later main-actor turn, so `MenuBarLabel.body` only reads it and never runs
    /// ImageRenderer during a view update (Code Reviewer nice-to-have).
    private(set) var menuBarImage: NSImage?
    @ObservationIgnored private var menuBarImageKey: String?

    // MARK: Notifications (T8, L19) and forecaster's notes (T17)

    /// What to notify about (Settings → Notifications). All off until the user turns something on.
    var notificationPrefs: NotificationPrefs {
        didSet {
            guard notificationPrefs != oldValue else { return }
            if let data = try? JSONEncoder().encode(notificationPrefs) { defaults.set(data, forKey: Keys.notifyPrefs) }
            scheduleBriefing()
            if notificationPrefs.alerts != oldValue.alerts || notificationPrefs.rain != oldValue.rain { startRefreshLoop() }
        }
    }
    /// Locations that notify. nil = just the menu-bar city (the default until the user picks).
    var notifyLocationIDs: Set<String>? {
        didSet { defaults.set(notifyLocationIDs.map { Array($0) }, forKey: Keys.notifyIDs) }
    }
    /// macOS permission as last seen (nil = never asked). Settings explains a "denied".
    private(set) var notificationPermission: Bool?
    /// Latest forecaster's notes per NWS office (loaded only while the card is on screen).
    private(set) var forecasterNotes: [String: ForecasterNotes] = [:]
    @ObservationIgnored private var notesFetched: [String: Date] = [:]
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var notificationState = NotificationState()
    @ObservationIgnored private var briefingTask: Task<Void, Never>?

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
        static let temperatureUnit = "unit.temperature"
        static let speedUnit = "unit.speed"
        static let precipitationUnit = "unit.precipitation"
        static let pressureUnit = "unit.pressure"
        static let distanceUnit = "unit.distance"
        static let clock = "clockStyle"
        static let menuBarPin = "menuBarLocationID"
        static let notifyPrefs = "notifications.prefs.v1"
        static let notifyIDs = "notifications.locations.v1"
        static let notifyState = "notifications.state.v1"
    }

    /// A report younger than this is shown without refetching.
    private let staleAfter: TimeInterval = 10 * 60
    /// Refresh cadence while only the menu bar is in use (at least twice the normal interval, ≥ 30 min).
    var menuBarOnlyMinutes: Int { max(refreshMinutes * 2, 30) }

    init(service: WeatherService = WeatherStore.makeService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.radar = RadarPlayback(service: service)
        self.defaults = defaults
        self.unitPreset = UnitPreference(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .system
        self.temperatureUnit = defaults.string(forKey: Keys.temperatureUnit).flatMap(TemperatureUnit.init(rawValue:))
        self.speedUnit = defaults.string(forKey: Keys.speedUnit).flatMap(SpeedUnit.init(rawValue:))
        self.precipitationUnit = defaults.string(forKey: Keys.precipitationUnit).flatMap(PrecipitationUnit.init(rawValue:))
        self.pressureUnit = defaults.string(forKey: Keys.pressureUnit).flatMap(PressureUnit.init(rawValue:))
        self.distanceUnit = defaults.string(forKey: Keys.distanceUnit).flatMap(DistanceUnit.init(rawValue:))
        self.clockStyle = ClockStyle(rawValue: defaults.string(forKey: Keys.clock) ?? "") ?? .system
        self.menuBarPinID = defaults.string(forKey: Keys.menuBarPin)
        self.notificationPrefs = defaults.data(forKey: Keys.notifyPrefs)
            .flatMap { try? JSONDecoder().decode(NotificationPrefs.self, from: $0) } ?? NotificationPrefs()
        self.notifyLocationIDs = (defaults.array(forKey: Keys.notifyIDs) as? [String]).map(Set.init)
        if let data = defaults.data(forKey: Keys.notifyState),
           let state = try? JSONDecoder().decode(NotificationState.self, from: data) {
            self.notificationState = state
        }
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
            // Fixes saved by older builds were ~11 m precise; keep only ~1 km (T7).
            var coarse = last
            coarse.coordinate = last.coordinate.coarse
            currentLocation = coarse
            if coarse != last { persistLastFix(coarse) }
        } else {
            isLocating = true
        }
        Fmt.clock = clockStyle
        resolveUnits()
        setUpLocation()
        observeWake()
        startRefreshLoop()
        trackMenuBarImage()
        setUpNotifications()
        // Download-cache clean-up (entries older than 14 days), off the launch path.
        let service = self.service
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(20))
            await service.pruneCache()
        }
    }

    // MARK: Derived

    var allLocations: [WeatherLocation] {
        (currentLocation.map { [$0] } ?? []) + savedLocations
    }

    var selectedLocation: WeatherLocation? {
        allLocations.first { $0.id == selectedID } ?? allLocations.first
    }

    /// The pinned city (Settings), else My Location, else the first saved city. It no longer changes
    /// when a different sidebar city is clicked (T10).
    var menuBarLocation: WeatherLocation? {
        LocationList.menuBarLocation(current: currentLocation, saved: savedLocations, pinnedID: menuBarPinID)
    }

    private func resolveUnits() {
        let new = DisplayUnits(preset: unitPreset, temperature: temperatureUnit, speed: speedUnit,
                               precipitation: precipitationUnit, pressure: pressureUnit, distance: distanceUnit)
        if new != units { units = new }
    }

    private func saveOverride(_ raw: String?, _ key: String) {
        if let raw { defaults.set(raw, forKey: key) } else { defaults.removeObject(forKey: key) }
        resolveUnits()
    }

    /// The dropdown's one-click °F/°C switch: flips the temperature unit only.
    func toggleTemperatureUnit() {
        temperatureUnit = units.temperature == .fahrenheit ? .celsius : .fahrenheit
    }

    var menuBarReport: WeatherReport? {
        menuBarLocation.flatMap { reports[$0.id] }
    }

    /// What the status item shows: SF Symbol, temperature text, dimmed. Nil before the first report.
    var menuBarLabelSpec: MenuBarLabel.Spec? {
        guard let report = menuBarReport else { return nil }
        return MenuBarLabel.Spec(symbol: report.current.condition.symbolName(isDay: report.current.isDay),
                                 text: units.temperatureString(report.current.temperature),
                                 dimmed: isStale(report))
    }

    /// Re-renders `menuBarImage` when its spec changes. Observation's onChange fires once (before the
    /// change lands), so the work is deferred to a Task and the tracking is re-armed there.
    private func trackMenuBarImage() {
        let spec = withObservationTracking { menuBarLabelSpec } onChange: { [weak self] in
            Task { @MainActor in self?.trackMenuBarImage() }
        }
        let key = spec?.key
        guard key != menuBarImageKey else { return }
        menuBarImageKey = key
        menuBarImage = spec.flatMap(MenuBarLabel.render)
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
            if !report.isOfflineFallback { considerNotifications(report, for: location) }
            await refreshAccuracy(for: location)
        } catch is CancellationError {
        } catch {
            // Keep the error visible even when older data is on screen (shown as the offline banner),
            // withdraw data that is too old to pass for weather, and retry soon.
            setError(Self.describe(error), for: location.id)
            if let existing = reports[location.id], existing.dataAge() > DataAge.maxDisplayAge {
                reports[location.id] = nil
            }
            scheduleRetry(location, notBefore: Self.retryNotBefore(error))
            scheduleHousekeeping()
        }
    }

    private func setError(_ message: String, for id: String) {
        if errors[id] != message { errors[id] = message }
    }

    /// Short readable text for a refresh failure.
    static func describe(_ error: Error) -> String { UserFacingError.message(error) }

    /// When the service asked us to slow down (429/503 Retry-After, or a back-off in progress), the
    /// retry waits at least that long.
    static func retryNotBefore(_ error: Error) -> Date? {
        switch error {
        case HTTPError.throttled(_, _, let after): return after.map { Date().addingTimeInterval($0) }
        case HTTPError.backingOff(_, let until): return until
        default: return nil
        }
    }

    /// After a failure, try again in about a minute instead of waiting for the next refresh cycle
    /// (backing off 1 → 2 → 4 … minutes up to the refresh interval while it keeps failing). Only for
    /// locations the user can currently see (menu-bar location, or any when the window is visible).
    private func scheduleRetry(_ location: WeatherLocation, notBefore: Date? = nil) {
        let id = location.id
        guard retryTasks[id] == nil else { return }
        let attempt = retryAttempts[id, default: 0]
        retryAttempts[id] = attempt + 1
        var delay = min(60 * pow(2, Double(min(attempt, 6))), Double(refreshMinutes) * 60)
        if let notBefore { delay = max(delay, notBefore.timeIntervalSinceNow + 2) }
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard let current = self.allLocations.first(where: { $0.id == id }),
                  self.isMainWindowVisible || self.menuBarLocation?.id == id
                    || ((self.notificationPrefs.alerts || self.notificationPrefs.rain) && self.notifies(current)) else { return }
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
            return WeatherService(verifier: ForecastVerifier(), history: ForecastHistory(directory: ForecastHistory.defaultDirectory()))
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
        // Cities with warning/rain notifications stay current even with the window closed.
        if notificationPrefs.alerts || notificationPrefs.rain { targets += allLocations.filter(notifies) }
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
        MemoryRelief.soon() // the decoded JSON for every location is garbage now
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                // Menu bar only: a slower cadence (the window reopening refreshes immediately).
                // Warning/rain notifications keep the normal cadence (a 30-min gap would miss "rain in 20 min").
                guard let minutes = self.map({ $0.isMainWindowOpen || $0.notificationPrefs.alerts || $0.notificationPrefs.rain
                                                   ? $0.refreshMinutes : $0.menuBarOnlyMinutes }) else { return }
                try? await Task.sleep(for: .seconds(Double(minutes) * 60), tolerance: .seconds(90))
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

    /// Window closed → menu bar only: stop radar playback, drop the window content (ContentView swaps it
    /// for an empty view, deallocating the map and layers), trim radar caches, and slow the refresh loop.
    /// Reopened → rebuild and refresh. Called on the main queue's next turn (never inside layout).
    func setMainWindowOpen(_ open: Bool) {
        guard open != isMainWindowOpen else { return }
        isMainWindowOpen = open
        if !open {
            setMainWindowVisible(false)
            radar.setPlaying(false)
            isScrubbing = false
            RadarImageCache.shared.trim()
            MemoryRelief.soon(after: 5) // after SwiftUI has deallocated the window content
            // Window gone: retries are only for the menu-bar location.
            for (id, task) in retryTasks where id != menuBarLocation?.id { task.cancel(); retryTasks[id] = nil }
        }
        startRefreshLoop() // re-arms with the cadence for the new state (and refreshes what's due now)
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
        // ~1 km from here on: this is what goes to the weather services, Apple's place-name lookup, the
        // saved "last fix" and the verification key (T7). Saved cities keep their own coordinates.
        let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude).coarse
        if let existing = currentLocation,
           CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 2_000 {
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
            let coarse = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(coarse).first {
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

    /// Removes a saved city. With an undo manager (sidebar ⌫ / context menu), Edit › Undo (⌘Z) puts it
    /// back in the same place, and Redo removes it again (T19).
    func remove(_ location: WeatherLocation, undoManager: UndoManager? = nil) {
        guard !location.isCurrentLocation, let index = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        let wasSelected = selectedID == location.id
        // A removed city stops being the menu-bar pick (Settings would show a choice that no longer
        // exists); undo puts the pin back.
        let wasPinned = menuBarPinID == location.id
        let notified = notifyLocationIDs?.contains(location.id) == true
        savedLocations.remove(at: index)
        reports[location.id] = nil
        errors[location.id] = nil
        if wasPinned { menuBarPinID = nil }
        if notified { notifyLocationIDs?.remove(location.id) }
        if wasSelected { selectedID = allLocations.first?.id }
        if let undoManager {
            // Weak: the manager owns this action, so a strong capture would be a (small) retain cycle.
            undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
                MainActor.assumeIsolated {
                    store.restore(location, at: index, select: wasSelected, pinned: wasPinned, notified: notified,
                                  undoManager: undoManager)
                }
            }
            undoManager.setActionName("Remove \(location.name)")
        }
    }

    func restore(_ location: WeatherLocation, at index: Int, select: Bool, pinned: Bool = false, notified: Bool = false,
                 undoManager: UndoManager? = nil) {
        savedLocations = LocationList.restoring(location, at: index, into: savedLocations)
        if select { selectedID = location.id }
        if pinned { menuBarPinID = location.id }
        if notified { notifyLocationIDs?.insert(location.id) }
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { [weak undoManager] store in
                MainActor.assumeIsolated { store.remove(location, undoManager: undoManager) }
            }
            undoManager.setActionName("Remove \(location.name)")
        }
        Task { await load(location) }
    }

    func move(_ location: WeatherLocation, by offset: Int) {
        guard let i = savedLocations.firstIndex(where: { $0.id == location.id }) else { return }
        let j = i + offset
        guard savedLocations.indices.contains(j) else { return }
        savedLocations.swapAt(i, j)
    }

    /// Drag-to-reorder in the sidebar (offsets within the saved cities).
    func moveSaved(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = LocationList.moving(savedLocations, fromOffsets: source, toOffset: destination)
        if moved.map(\.id) != savedLocations.map(\.id) { savedLocations = moved }
    }

    /// Return in the search field adds the first result, searching right away if the debounced search
    /// hasn't answered yet (T19).
    func submitSearch() {
        if let first = searchResults.first { add(first); return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }
        searchTask?.cancel()
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            let results = (try? await self.service.search(query)) ?? []
            guard !Task.isCancelled else { return }
            self.isSearching = false
            if let first = results.first { self.add(first) } else { self.searchResults = [] }
        }
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

// MARK: - Notifications (T8, L19) and forecaster's notes (T17)

extension WeatherStore {
    /// Whether this location sends notifications (default: only the menu-bar city).
    func notifies(_ location: WeatherLocation) -> Bool {
        if let ids = notifyLocationIDs { return ids.contains(location.id) }
        return location.id == menuBarLocation?.id
    }

    func setNotifies(_ location: WeatherLocation, _ on: Bool) {
        var ids = notifyLocationIDs ?? Set(allLocations.filter(notifies).map(\.id))
        if on { ids.insert(location.id) } else { ids.remove(location.id) }
        notifyLocationIDs = ids
    }

    /// Settings turns a notification on: ask macOS once (system prompt), remember the answer.
    func ensureNotificationPermission() async {
        let granted = await notifier.requestAuthorization()
        if notificationPermission != granted { notificationPermission = granted }
        if granted { for location in allLocations { if let r = reports[location.id] { considerNotifications(r, for: location) } } }
    }

    func setUpNotifications() {
        notifier.onOpen = { [weak self] locationID, alertID in
            guard let self else { return }
            if self.allLocations.contains(where: { $0.id == locationID }) { self.selectedID = locationID }
            self.activeModule = nil
            self.radarExpanded = false
            if let alertID { self.pendingAlertID = alertID }
            AppActions.openMainWindow?()
            NSApp.activate()
        }
        scheduleBriefing()
        // Only look at the permission if something is on; never prompt at launch.
        guard notificationPrefs.anyOn else { return }
        Task { [weak self] in
            guard let self else { return }
            let status = await self.notifier.refreshAuthorization()
            let allowed = status.map { $0 == .authorized || $0 == .provisional }
            if self.notificationPermission != allowed { self.notificationPermission = allowed }
            if allowed == true {
                for location in self.allLocations { if let r = self.reports[location.id] { self.considerNotifications(r, for: location) } }
            }
        }
    }

    /// Runs the planner on a fresh report and posts the result. QA hook `-SkylineNotifyPreview YES`
    /// prints what would be posted (every kind on, nothing sent, nothing remembered) instead.
    func considerNotifications(_ report: WeatherReport, for location: WeatherLocation) {
        let preview = UserDefaults.standard.bool(forKey: "SkylineNotifyPreview")
        var prefs = notificationPrefs
        var state = notificationState
        if preview {
            prefs.alerts = true; prefs.rain = true; prefs.morningBriefing = true
            prefs.minimumSeverity = .minor; prefs.quietHours = false
            prefs.briefingMinutes = max(0, NotificationPlannerClock.minutesNow() - 1)
            state = NotificationState()
        } else {
            guard prefs.anyOn, notifier.authorized == true else { return }
        }
        let tz = report.timeZone
        let name = location.name
        var planned: [PlannedNotification] = []
        if preview || notifies(location) {
            planned = NotificationPlanner.plan(report, locationName: name, prefs: prefs, state: &state, now: Date(),
                                               timeLabel: { Fmt.time($0, tz) })
        }
        if location.id == menuBarLocation?.id || preview,
           let b = NotificationPlanner.briefing(report, locationName: name, summary: briefingSummary(report), prefs: prefs,
                                                state: &state, now: Date()) {
            planned.append(b)
        }
        if preview {
            for p in planned { print("[notify] \(p.kind.rawValue) | \(p.title) | \(p.body)") }
            if planned.isEmpty { print("[notify] none for \(name)") }
            fflush(stdout)
            return
        }
        guard state != notificationState else { return }
        notificationState = state
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Keys.notifyState) }
        notifier.post(planned)
    }

    /// "High 64°, low 50°. Rain likely from 4 PM (70%)." for the morning briefing.
    func briefingSummary(_ report: WeatherReport) -> String {
        let tz = report.timeZone
        var parts: [String] = []
        if let today = report.today {
            parts.append("High \(units.temperatureString(today.high)), low \(units.temperatureString(today.low)).")
        }
        parts.append(Briefing.headline(report, now: Date(), hourLabel: { Fmt.hour($0, tz) },
                                       delta: { Int(self.units.temperatureDelta($0).rounded()) }))
        if let alert = report.activeAlerts().first { parts.append("\(alert.event) in effect.") }
        return parts.joined(separator: " ")
    }

    /// One sleeping task per day: wakes at the briefing time, makes sure the menu-bar city is fresh, and
    /// lets `considerNotifications` send the briefing. A Mac asleep then gets it on wake (within 3 h).
    func scheduleBriefing() {
        briefingTask?.cancel()
        briefingTask = nil
        guard notificationPrefs.morningBriefing else { return }
        let next = NotificationPlanner.nextBriefing(after: Date(), prefs: notificationPrefs)
        briefingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 5)), tolerance: .seconds(30))
            guard !Task.isCancelled, let self, let location = self.menuBarLocation else { return }
            await self.load(location)
            if let report = self.reports[location.id], !report.isOfflineFallback {
                self.considerNotifications(report, for: location)
            }
            self.scheduleBriefing()
        }
    }

    /// Forecaster's notes for an office: at most one check per 30 min (the service caches too).
    func loadForecasterNotes(office: String) async {
        if let at = notesFetched[office], Date().timeIntervalSince(at) < 30 * 60, forecasterNotes[office] != nil { return }
        notesFetched[office] = Date()
        let notes = await service.forecasterNotes(office: office)
        if UserDefaults.standard.bool(forKey: "SkylineNotifyPreview") {
            print("[notes] office=\(office) loaded=\(notes != nil) keyMessages=\(notes?.areKeyMessages ?? false) "
                  + "points=\(notes?.points.count ?? 0) changed=\(notes?.whatChanged != nil) first=\(notes?.points.first?.prefix(90) ?? "-")")
            fflush(stdout)
        }
        guard let notes else { return }
        if forecasterNotes[office] != notes { forecasterNotes[office] = notes }
    }
}

/// Local minutes since midnight (for the notification preview hook).
enum NotificationPlannerClock {
    static func minutesNow() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
