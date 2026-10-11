import AppKit
import CoreLocation
import Foundation
import Observation
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

    var searchText = ""
    var searchResults: [PlaceSearchResult] = []
    var isSearching = false

    /// Radar map expanded to fill the detail area (in-window, Apple-Weather style).
    var radarExpanded = false
    /// Module detail panel shown over the detail area (tap a module to open).
    var activeModule: ModuleSelection?

    private(set) var isMainWindowVisible = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locationProvider = LocationProvider()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    private enum Keys {
        static let locations = "savedLocations.v1"
        static let selected = "selectedLocationID"
        static let units = "unitPreference"
        static let refresh = "refreshMinutes"
        static let seeded = "seededDefaultLocation"
    }

    /// A report younger than this is shown without refetching.
    private let staleAfter: TimeInterval = 10 * 60

    init(service: WeatherService = WeatherService(), defaults: UserDefaults = .standard) {
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

    // MARK: Loading

    func load(_ location: WeatherLocation, force: Bool = false) async {
        if !force, let existing = reports[location.id],
           Date().timeIntervalSince(existing.fetchedAt) < staleAfter,
           existing.location.coordinate == location.coordinate {
            return
        }
        loadingIDs.insert(location.id)
        defer { loadingIDs.remove(location.id) }
        do {
            var report = try await service.report(for: location, forceRefresh: force)
            report.location = location
            reports[location.id] = report
            errors[location.id] = nil
        } catch is CancellationError {
        } catch {
            if reports[location.id] == nil { errors[location.id] = error.localizedDescription }
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
        radar.isVisible = visible
        if visible { Task { await refreshDue() } }
    }

    // MARK: Current location

    private func setUpLocation() {
        locationProvider.onUpdate = { [weak self] coordinate in self?.handleLocation(coordinate) }
        locationProvider.onAuthorizationChange = { [weak self] authorized in
            guard let self else { return }
            self.locationDenied = !authorized
            if !authorized, self.currentLocation != nil {
                self.currentLocation = nil
                if self.selectedID == WeatherLocation.currentLocationID { self.selectedID = self.savedLocations.first?.id }
            }
        }
        locationProvider.start()
    }

    private func handleLocation(_ c: CLLocationCoordinate2D) {
        let coordinate = Coordinate(latitude: c.latitude, longitude: c.longitude)
        if let existing = currentLocation,
           CLLocation(latitude: existing.coordinate.latitude, longitude: existing.coordinate.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 2_000 {
            return
        }
        let isFirstFix = currentLocation == nil
        let location = WeatherLocation(id: WeatherLocation.currentLocationID, name: currentLocation?.name ?? "My Location",
                                       coordinate: coordinate, isCurrentLocation: true)
        currentLocation = location
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
            }
            await load(location, force: true)
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

    private func persistLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            defaults.set(data, forKey: Keys.locations)
        }
    }
}
