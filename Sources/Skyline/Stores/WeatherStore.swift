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
    var selectedID: String? {
        didSet {
            defaults.set(selectedID, forKey: Keys.selected)
            // A different city starts on its forecast, not the previous city's map/panel/alert. This used
            // to be an onChange in LocationDetailView, which never fired: the view is re-created per city
            // (L32). Selection changes come from user actions, never from layout.
            if selectedID != oldValue {
                if radarExpanded { radarExpanded = false }
                if activeModule != nil { activeModule = nil }
                if focusedAlertID != nil { focusedAlertID = nil }
            }
        }
    }
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
    var isLocating = false { didSet { if isLocating { startLocatingTimeout() } } }
    /// No fix after `locatingTimeout` (an ignored permission prompt, no Wi-Fi): stop the spinner and say
    /// so; CoreLocation keeps retrying and the row appears when a fix arrives (L5).
    var locationUnavailable = false
    @ObservationIgnored private var locatingTimeoutTask: Task<Void, Never>?
    static let locatingTimeout: Duration = .seconds(30)

    var searchText = ""
    var searchResults: [PlaceSearchResult] = []
    var isSearching = false
    /// Why the last search failed (offline, rate limit, timeout); nil after a search that answered (QA #2).
    var searchError: String?
    /// The query `searchResults` belong to, so Return never adds a result for older text (QA #1).
    private var resultsQuery = ""
    /// Return found only places it won't add by itself (a country): say "choose one" instead of nothing.
    private var submitFoundNothingToAdd = false

    /// What the search list says besides its results (never silent: hint, searching, none, failed).
    var searchStatus: PlaceSearch.Status? {
        PlaceSearch.status(text: searchText, isSearching: isSearching, resultCount: searchResults.count,
                           resultsQuery: resultsQuery, error: searchError, nothingAdded: submitFoundNothingToAdd)
    }

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
    @ObservationIgnored let widgetPublisher = WidgetPublisher()
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

    /// The app's store: sync only in the real bundle or with the isolated `-SkylineSyncFile` override,
    /// whose defaults are a separate suite (item 1).
    static func forApp() -> WeatherStore {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let env = SyncEnvironment.resolve(bundleIdentifier: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
                                          home: home, iCloudAvailable: fm.fileExists(atPath: home
                                            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path))
        let defaults = env?.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        return WeatherStore(defaults: defaults, sync: env)
    }

    @ObservationIgnored private let syncEnvironment: SyncEnvironment?

    init(service: WeatherService = WeatherStore.makeService(), defaults: UserDefaults = .standard,
         sync: SyncEnvironment? = nil) {
        self.syncEnvironment = sync
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
        IntentStore.shared = self
        // Saved cities and settings shared across Macs through iCloud Drive (polish 1).
        if let syncEnvironment { SyncCoordinator.start(store: self, defaults: defaults, env: syncEnvironment) }
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
                                 text: units.temperatureString(report.current.temperature, withUnit: true),
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
        publishWidget()
    }

    /// Widget snapshot for the menu-bar city (T22). Cheap when nothing changed.
    func publishWidget() {
        guard let location = menuBarLocation, let report = reports[location.id] else { return }
        widgetPublisher.publish(report, name: location.isCurrentLocation ? "My Location" : location.name, units: units)
        if widgetError != widgetPublisher.lastError { widgetError = widgetPublisher.lastError }
    }

    /// Set when the widget's data file couldn't be written (Settings shows it).
    var widgetError: String?

    func isLoading(_ location: WeatherLocation) -> Bool {
        loadingIDs.contains(location.id) || quietRetries.updating.contains(location.id)
    }
    /// Item 2: cities with nothing on screen whose last attempt failed transiently and retry quickly
    /// without a banner (shown as "Updating…"). See `QuietRetryTracker` for when it clears.
    var quietRetries = QuietRetryTracker()

    /// Data older than this is flagged as stale (see `DataAge.staleAfter`).
    var staleDataAge: TimeInterval { DataAge.staleAfter(refreshMinutes: refreshMinutes) }

    /// True when the report's data is old, came from the offline cache, or its last refresh failed.
    /// Reads `staleTick`, so callers re-render when the report goes stale with no other change.
    func isStale(_ report: WeatherReport, now: Date = Date()) -> Bool {
        _ = staleTick
        return hasRefreshProblem(report) || report.dataAge(at: now) > staleDataAge
    }

    /// True when the last refresh for this report's location failed (network or service error).
    /// Only a Mac with no network is "Offline"; a failed or throttled refresh says so in other words.
    func isOffline(_ report: WeatherReport) -> Bool {
        RefreshBookkeeping.isReallyOffline(cause: report.isOfflineFallback ? report.fallbackCause : nil,
                                           error: errors[report.location.id])
    }

    /// Saved data after a failed refresh, or a refresh error: the banner shows (with the right words).
    func hasRefreshProblem(_ report: WeatherReport) -> Bool {
        RefreshBookkeeping.isOffline(isOfflineFallback: report.isOfflineFallback, error: errors[report.location.id])
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
            let priority = FetchRetryPolicy.priority(force: force, hasReport: reports[location.id] != nil)
            var report = try await service.report(for: location, forceRefresh: force, priority: priority)
            // My Location moved while this was loading: this answer is for the old place (L4).
            if location.isCurrentLocation,
               !CurrentLocationGuard.isCurrent(location.coordinate, current: currentLocation?.coordinate) {
                quietRetries.abandoned(location.id) // follow-up L3: don't leave "Updating…" behind
                return
            }
            report.location = location
            if defaults.bool(forKey: "SkylineDemoAlert"), report.alerts.isEmpty { report.alerts = [Self.demoAlert(near: location)] }
            if defaults.bool(forKey: "SkylineDemoRain") { report.minutely = Self.demoRain(from: report.current.time) }
            reports[location.id] = report
            publishWidget()
            let until = report.isOfflineFallback
                ? await service.backoff(for: RefreshBookkeeping.openMeteoHost) : nil
            let follow = RefreshBookkeeping.afterReport(isOfflineFallback: report.isOfflineFallback,
                                                        cause: report.fallbackCause, backoffUntil: until)
            if follow.clearError {
                if errors[location.id] != nil { errors[location.id] = nil }
                quietRetries.succeeded(location.id)
                retryTasks.removeValue(forKey: location.id)?.cancel()
                retryAttempts[location.id] = nil
            } else {
                // Follow-ups M2/M3: saved data is on screen, so no quiet quick retries; the banner shows
                // at once (a real offline included) and the PR #2 ladder applies.
                quietRetries.abandoned(location.id)
                // Saved data stays up. A live back-off retries at `until` ("Open-Meteo busy, retrying at h:mm")
                // instead of hammering the host and keeping the spinner on.
                setError(follow.message, for: location.id)
                // A one-off failure (not offline, not throttled) is retried in 15 s the first time, so a
                // "Couldn’t update" banner after Refresh clears on its own within seconds.
                let quick = retryAttempts[location.id, default: 0] == 0 ? follow.quickRetry : nil
                scheduleRetry(location, notBefore: follow.notBefore,
                              delay: quick.map { $0 + FetchRetryPolicy.jitter(for: location.id) })
            }
            scheduleHousekeeping()
            if !report.isOfflineFallback { considerNotifications(report, for: location) }
            await refreshAccuracy(for: location)
        } catch is CancellationError {
            // Deferred #5 note: a cancelled load must not leave "Updating…" up unless a retry is pending.
            if retryTasks[location.id] == nil { quietRetries.abandoned(location.id) }
        } catch {
            // Force during a long back-off throws `backingOff` immediately (no multi-minute sleep, so
            // `loadingIDs` clears and Refresh stays usable). The banner keeps the saved report.
            let follow = RefreshBookkeeping.afterFailure(error)
            if errors[location.id] == nil,
               followUpQuietly(location, error: error,
                               backoffUntil: await service.backoff(for: RefreshBookkeeping.openMeteoHost)) {
                // A first fetch: "Updating…", retried in seconds, no banner yet (item 2).
                scheduleHousekeeping()
                return
            }
            setError(follow.message, for: location.id)
            if let existing = reports[location.id], existing.dataAge() > DataAge.maxDisplayAge {
                reports[location.id] = nil
            }
            scheduleRetry(location, notBefore: follow.notBefore)
            scheduleHousekeeping()
        }
    }

    /// Item 2: schedules a quiet quick retry when the policy allows; false = show the error as before.
    private func followUpQuietly(_ location: WeatherLocation, error: Error, backoffUntil: Date?) -> Bool {
        let id = location.id
        let decision = quietRetries.failed(id, error: error,
                                           hasReport: reports[id] != nil, backoffUntil: backoffUntil,
                                           refreshInterval: Double(refreshMinutes) * 60)
        guard decision.quiet else { return false }
        // Follow-up L3: an older, slower retry would keep "Updating…" up until it fires; replace it.
        retryTasks.removeValue(forKey: id)?.cancel()
        scheduleRetry(location, delay: decision.retryAfter)
        return true
    }

    private func setError(_ message: String, for id: String) {
        if errors[id] != message { errors[id] = message }
    }

    /// After a failure, try again in about a minute instead of waiting for the next refresh cycle
    /// (backing off 1 → 2 → 4 … minutes up to the refresh interval while it keeps failing). Only for
    /// locations the user can currently see (menu-bar location, or any when the window is visible).
    private func scheduleRetry(_ location: WeatherLocation, notBefore: Date? = nil, delay fixed: TimeInterval? = nil) {
        let id = location.id
        guard retryTasks[id] == nil else { return }
        let attempt = retryAttempts[id, default: 0]
        retryAttempts[id] = attempt + 1
        // After the quiet quick retries, the exponential ladder starts at 1 min again (item 2).
        let slow = quietRetries.ladderIndex(id, attempt: attempt)
        var delay = fixed ?? min(60 * pow(2, Double(min(slow, 6))), Double(refreshMinutes) * 60)
        if let notBefore { delay = max(delay, notBefore.timeIntervalSinceNow + 2) }
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.retryTasks[id] = nil
            guard let current = self.allLocations.first(where: { $0.id == id }),
                  self.isMainWindowVisible || self.menuBarLocation?.id == id || self.reports[id] == nil
                    || ((self.notificationPrefs.alerts || self.notificationPrefs.rain) && self.notifies(current)) else {
                self.quietRetries.abandoned(id)
                return
            }
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

    private var lastDropdownOpen: Date?
    /// When each place's last forced refresh-on-open started (success or failure): the 3-min cooldown.
    private var lastForcedOpen: [String: Date] = [:]

    /// The dropdown (or hotkey panel) opened. While it's raining or rain is due and the data is a few
    /// minutes old, refetch now (forced: past the 10-minute guard and the HTTP cache), otherwise the
    /// usual guarded load. Other cities' rows that went stale are brought up to date too (at most 5).
    func dropdownOpened() async {
        let now = Date()
        if let last = lastDropdownOpen, now.timeIntervalSince(last) < 2 { return } // `.task` + became-key on one open
        lastDropdownOpen = now
        guard let location = menuBarLocation else { return }
        if let report = reports[location.id], !isLoading(location),
           MenuSummary.refreshOnOpen(report, now: now, lastForcedAttempt: lastForcedOpen[location.id]) {
            lastForcedOpen[location.id] = now // set before the fetch: a failure counts too
            await load(location, force: true)
        } else {
            await load(location)
        }
        let stale = allLocations.filter { $0.id != location.id }.prefix(5)
            .filter { reports[$0.id].map { MenuSummary.primaryForecastAge($0, now: now) >= staleDataAge } ?? true }
        if !stale.isEmpty { await refresh(locations: Array(stale), force: false) }
    }

    func refreshAll(force: Bool) async {
        locationProvider.refresh()
        await refresh(locations: allLocations, force: force)
    }

    /// Called by the periodic loop and after wake.
    func refreshDue() async {
        SyncCoordinator.shared?.pullIfChanged() // one stat; merges only when another Mac wrote
        var targets: [WeatherLocation] = []
        if let m = menuBarLocation { targets.append(m) }
        // Cities with warning/rain notifications stay current even with the window closed.
        if notificationPrefs.alerts || notificationPrefs.rain { targets += allLocations.filter(notifies) }
        if isMainWindowVisible { targets += allLocations }
        // A city with no data at all is fetched once even while the window is hidden or occluded
        // (display asleep at launch), so its row never sits on "--" waiting for a visibility change.
        targets += allLocations.filter { reports[$0.id] == nil }
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

    /// Window closed → menu bar only: stop radar playback, release the window, trim radar caches, and
    /// slow the refresh loop. Reopened → a new window, radar prewarmed, then refresh.
    /// Called on the main queue's next turn (never inside layout).
    func setMainWindowOpen(_ open: Bool) {
        guard open != isMainWindowOpen else { return }
        isMainWindowOpen = open
        // Menu bar / Dock policy: regular while the window is open so menus work; accessory when not.
        DockIcon.apply(openMainWindow: open)
        if !open {
            setMainWindowVisible(false)
            radar.setPlaying(false)
            isScrubbing = false
            RadarImageCache.shared.closeForMenuBar()
            MemoryRelief.soon(after: 5) // after SwiftUI has deallocated the window content
            // MapKit/VectorKit tear their engine down asynchronously; relieve again once that is done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.isMainWindowOpen == false { MemoryRelief.soon(after: 0) }
            }
            // Window gone: retries are only for the menu-bar location.
            for (id, task) in retryTasks where id != menuBarLocation?.id { task.cancel(); retryTasks[id] = nil }
        } else {
            RadarImageCache.shared.reopen(frames: radar.frames, shownIndex: radar.index)
        }
        startRefreshLoop() // re-arms with the cadence for the new state (and refreshes what's due now)
    }

    // MARK: Current location

    private func setUpLocation() {
        locationProvider.seed(currentLocation?.coordinate)
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

    private func startLocatingTimeout() {
        locatingTimeoutTask?.cancel()
        locatingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.locatingTimeout)
            guard !Task.isCancelled, let self, self.isLocating, self.currentLocation == nil else { return }
            self.isLocating = false
            self.locationUnavailable = true
        }
    }

    private var currentNameVerified = false

    private func handleLocation(_ c: CLLocationCoordinate2D) {
        if isLocating { isLocating = false }
        locatingTimeoutTask?.cancel()
        if locationUnavailable { locationUnavailable = false }
        // ~1 km from here on: this is what goes to the weather services, Apple's place-name lookup, the
        // saved "last fix" and the verification key (T7). Saved cities keep their own coordinates.
        let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude).coarse
        if let existing = currentLocation,
           CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 2_000 {
            // QA build-44 G1-b: a saved fix at the right spot may carry a wrong name from an earlier
            // session; look the name up again once per launch (no reload unless it changes).
            if !currentNameVerified {
                currentNameVerified = true
                let here = existing.coordinate
                Task {
                    guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(
                              CLLocation(latitude: here.latitude, longitude: here.longitude)).first,
                          var location = currentLocation, location.coordinate == here else { return }
                    let name = placemark.locality ?? placemark.name ?? "My Location"
                    guard name != location.name || placemark.timeZone?.identifier != location.timeZoneIdentifier else { return }
                    location.name = name
                    location.region = placemark.administrativeArea
                    location.country = placemark.country
                    location.countryCode = placemark.isoCountryCode
                    location.timeZoneIdentifier = placemark.timeZone?.identifier
                    currentLocation = location
                    persistLastFix(location)
                }
            }
            return
        }
        currentNameVerified = true
        let isFirstFix = currentLocation == nil
        // Moved: the old place's forecast must not be shown under My Location while the new one loads (L4).
        if !isFirstFix, reports[WeatherLocation.currentLocationID] != nil { reports[WeatherLocation.currentLocationID] = nil }
        // Moved more than 2 km: the old place's name (and region, country, time zone) no longer applies.
        // It shows "My Location" until the place lookup names the new spot; a failed lookup never
        // leaves the old name on the new coordinates (QA build-41 G1).
        let location = WeatherLocation(id: WeatherLocation.currentLocationID, name: "My Location",
                                       coordinate: coordinate, isCurrentLocation: true)
        currentLocation = location
        persistLastFix(location)
        if isFirstFix && (selectedID == nil || selectedID == savedLocations.first?.id) {
            selectedID = location.id
        }
        Task {
            var location = location
            let coarse = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let placemark = try? await CLGeocoder().reverseGeocodeLocation(coarse).first,
               CurrentLocationGuard.isCurrent(coordinate, current: currentLocation?.coordinate) { // a newer fix wins (L4)
                location.name = placemark.locality ?? placemark.name ?? "My Location"
                location.region = placemark.administrativeArea
                location.country = placemark.country
                location.countryCode = placemark.isoCountryCode // not localized (CR batch 6)
                location.timeZoneIdentifier = placemark.timeZone?.identifier
                currentLocation = location
                persistLastFix(location)
            }
            guard CurrentLocationGuard.isCurrent(coordinate, current: currentLocation?.coordinate) else { return }
            await load(currentLocation ?? location, force: true)
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

    /// Settings › Reset Accuracy Data (L23).
    func resetAccuracyData() async {
        await service.verifier?.reset()
        await service.history?.reset()
        accuracy = [:]
        for location in allLocations { await refreshAccuracy(for: location) }
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
        submitFoundNothingToAdd = false
        let query = SearchSubmit.normalized(searchText)
        guard query.count >= 2 else {
            searchResults = []
            resultsQuery = ""
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300)) // debounce typing
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(query, addFirst: false)
        }
    }

    /// One search; errors are shown (not turned into "No matches"), and results remember their query.
    private func runSearch(_ query: String, addFirst: Bool) async {
        do {
            let service = self.service
            let found = try await PlaceSearch.withTimeout(PlaceSearch.timeout) { try await service.search(query) }
            let results = SearchSubmit.ranked(found, query: query)
            guard !Task.isCancelled else { return }
            isSearching = false
            searchError = nil
            if addFirst, let first = SearchSubmit.autoAdd(results) { add(first); return }
            searchResults = results
            resultsQuery = query
            submitFoundNothingToAdd = addFirst && !results.isEmpty
        } catch {
            guard !Task.isCancelled else { return }
            isSearching = false
            searchResults = []
            resultsQuery = ""
            searchError = PlaceSearch.errorMessage(error)
        }
    }

    func retrySearch() {
        searchError = nil
        searchTextChanged()
    }

    func add(_ result: PlaceSearchResult) {
        let location = result.asLocation
        // Same place by id, ~1 km, or name+region+country: select the one we already have (QA #5).
        if let existing = LocationList.existingDuplicate(of: location, in: savedLocations) {
            // CR H2: the copy we select may be a stale one another Mac deleted; picking it in search is
            // the user re-adding it, so log the re-add (otherwise the next sync purges it).
            SyncCoordinator.shared?.recordAddition(existing.id)
            selectedID = existing.id
        } else {
            SyncCoordinator.shared?.recordAddition(location.id)
            savedLocations.append(location)
            selectedID = location.id
        }
        searchText = ""
        searchResults = []
        resultsQuery = ""
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
        // Item 1: the tombstone is on disk before the list changes (survives a quit or crash).
        SyncCoordinator.shared?.recordDeletion(location.id)
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
        SyncCoordinator.shared?.recordAddition(location.id)
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
        let query = SearchSubmit.normalized(searchText)
        if let first = SearchSubmit.pick(results: searchResults, resultsQuery: resultsQuery, currentText: searchText) {
            add(first); return
        }
        guard query.count >= 2 else { return } // the list already says "Type at least 2 letters"
        // Results are for older text (still inside the debounce) or missing: search the current text now.
        searchTask?.cancel()
        isSearching = true
        searchTask = Task { [weak self] in await self?.runSearch(query, addFirst: true) }
    }

    private func persistLastFix(_ location: WeatherLocation) {
        if let data = try? JSONEncoder().encode(location) { defaults.set(data, forKey: Keys.lastFix) }
    }

    // MARK: Sync (polish 1)

    /// Cities brought back by the item-1 recovery carry a coordinate name; look the real one up once.
    func nameRecoveredLocations(_ recovered: [WeatherLocation]) {
        Task { @MainActor in
            for r in recovered {
                let loc = CLLocation(latitude: r.coordinate.latitude, longitude: r.coordinate.longitude)
                guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first,
                      let name = p.locality ?? p.name,
                      let i = savedLocations.firstIndex(where: { $0.id == r.id }) else { continue }
                var named = savedLocations[i]
                named.name = name
                named.region = p.administrativeArea
                named.country = p.country
                named.countryCode = p.isoCountryCode
                named.timeZoneIdentifier = p.timeZone?.identifier
                savedLocations[i] = named
            }
        }
    }

    /// The city list from another Mac (merged; nothing local is dropped unless it was removed there later).
    func applySyncedLocations(_ locations: [WeatherLocation]) {
        guard locations != savedLocations else { return }
        savedLocations = locations
        if let id = selectedID, id != WeatherLocation.currentLocationID, !allLocations.contains(where: { $0.id == id }) {
            selectedID = allLocations.first?.id
        }
        Task { await refreshDue() }
    }

    /// Re-read the synced settings after another Mac changed them (only assigns what differs).
    func reloadSyncedSettings() {
        let preset = UnitPreference(rawValue: defaults.string(forKey: Keys.units) ?? "") ?? .system
        if preset != unitPreset { unitPreset = preset }
        let t = defaults.string(forKey: Keys.temperatureUnit).flatMap(TemperatureUnit.init(rawValue:))
        if t != temperatureUnit { temperatureUnit = t }
        let sp = defaults.string(forKey: Keys.speedUnit).flatMap(SpeedUnit.init(rawValue:))
        if sp != speedUnit { speedUnit = sp }
        let pr = defaults.string(forKey: Keys.precipitationUnit).flatMap(PrecipitationUnit.init(rawValue:))
        if pr != precipitationUnit { precipitationUnit = pr }
        let ps = defaults.string(forKey: Keys.pressureUnit).flatMap(PressureUnit.init(rawValue:))
        if ps != pressureUnit { pressureUnit = ps }
        let d = defaults.string(forKey: Keys.distanceUnit).flatMap(DistanceUnit.init(rawValue:))
        if d != distanceUnit { distanceUnit = d }
        let c = ClockStyle(rawValue: defaults.string(forKey: Keys.clock) ?? "") ?? .system
        if c != clockStyle { clockStyle = c }
        let m = defaults.integer(forKey: Keys.refresh)
        if m >= 5, m != refreshMinutes { refreshMinutes = m }
        let pin = defaults.string(forKey: Keys.menuBarPin)
        if pin != menuBarPinID { menuBarPinID = pin }
        let prefs = defaults.data(forKey: Keys.notifyPrefs).flatMap { try? JSONDecoder().decode(NotificationPrefs.self, from: $0) }
            ?? NotificationPrefs()
        if prefs != notificationPrefs { notificationPrefs = prefs }
        let ids = (defaults.array(forKey: Keys.notifyIDs) as? [String]).map(Set.init)
        if ids != notifyLocationIDs { notifyLocationIDs = ids }
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
            NSApp.activate()
            // On a cold launch the scenes may not have registered their window opener yet: retry briefly.
            Task { @MainActor in
                for _ in 0..<20 {
                    if let open = AppActions.openMainWindow { open(); NSApp.activate(); return }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        scheduleBriefing()
        // Only look at the permission if something is on; never prompt at launch.
        guard notificationPrefs.anyOn else { return }
        notifier.attach()
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
                                               timeLabel: { Self.notificationTime($0, tz) })
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

    /// "3:15 PM", plus the zone ("3:15 PM CDT") when the city keeps a different clock from this Mac, so a
    /// notification about a city elsewhere isn't read in local time (Code Reviewer batch 4).
    static func notificationTime(_ date: Date, _ tz: TimeZone, local: TimeZone = .current) -> String {
        let time = Fmt.time(date, tz)
        guard tz.secondsFromGMT(for: date) != local.secondsFromGMT(for: date) else { return time }
        return time + " " + (tz.abbreviation(for: date) ?? tz.identifier)
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
