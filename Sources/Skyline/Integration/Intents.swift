import AppIntents
import AppKit
import SkylineCore

/// App Intents (L22): "Get Skyline Weather", "Will It Rain" and "Show Radar" for Shortcuts, Siri and
/// Spotlight. They run inside the app (launching it in the menu bar if needed) and use the same store,
/// cache and blend as the window, so answers match what Skyline shows.
@MainActor
enum IntentStore {
    static weak var shared: WeatherStore?

    /// The store, waiting briefly if the system launched Skyline just to run the intent.
    static func store() async throws -> WeatherStore {
        for _ in 0..<40 {
            if let s = shared { return s }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntentError.notReady
    }

    static func location(_ city: CityEntity?, in store: WeatherStore) throws -> WeatherLocation {
        if let city {
            guard let l = store.allLocations.first(where: { $0.id == city.id }) else { throw IntentError.unknownCity }
            return l
        }
        guard let l = store.menuBarLocation ?? store.allLocations.first else { throw IntentError.noCities }
        return l
    }

    static func report(for location: WeatherLocation, in store: WeatherStore) async throws -> WeatherReport {
        await store.load(location)
        guard let r = store.reports[location.id] else { throw IntentError.noData(location.name) }
        return r
    }

    static func name(_ l: WeatherLocation) -> String { l.isCurrentLocation ? "My Location" : l.name }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, unknownCity, noCities, noData(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Skyline is still starting. Try again in a moment."
        case .unknownCity: "That city isn't in Skyline any more."
        case .noCities: "Add a city in Skyline first."
        case .noData(let name): "Couldn't load the weather for \(name)."
        }
    }
}

/// A saved city (or My Location) as Shortcuts sees it.
struct CityEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "City"
    static var defaultQuery = CityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [CityEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [CityEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [CityEntity] { try await all() }

    @MainActor private func all() async throws -> [CityEntity] {
        let store = try await IntentStore.store()
        return store.allLocations.map { CityEntity(id: $0.id, name: IntentStore.name($0)) }
    }
}

struct GetWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Skyline Weather"
    static var description = IntentDescription("Current conditions, today's high and low, and what's next, from Skyline's blended forecast.")
    @Parameter(title: "City", description: "Leave empty for the menu-bar city") var city: CityEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get Skyline weather for \(\.$city)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentStore.store()
        let location = try IntentStore.location(city, in: store)
        let report = try await IntentStore.report(for: location, in: store)
        let text = IntentText.weather(report, name: IntentStore.name(location), units: store.units, now: Date())
        return .result(value: text, dialog: "\(text)")
    }
}

struct WillItRainIntent: AppIntent {
    static var title: LocalizedStringResource = "Will It Rain Soon"
    static var description = IntentDescription("Whether rain (or snow) starts or stops in the next 2 hours, and when.")
    @Parameter(title: "City", description: "Leave empty for the menu-bar city") var city: CityEntity?

    static var parameterSummary: some ParameterSummary { Summary("Will it rain soon in \(\.$city)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = try await IntentStore.store()
        let location = try IntentStore.location(city, in: store)
        let report = try await IntentStore.report(for: location, in: store)
        let text = IntentText.rain(report, name: IntentStore.name(location), now: Date())
        return .result(value: text, dialog: "\(text)")
    }
}

struct ShowRadarIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Skyline Radar"
    static var description = IntentDescription("Opens Skyline with the radar map expanded.")
    static var openAppWhenRun = true
    @Parameter(title: "City", description: "Leave empty for the menu-bar city") var city: CityEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await IntentStore.store()
        let location = try IntentStore.location(city, in: store)
        store.selectedID = location.id
        store.activeModule = nil
        store.radarExpanded = true
        AppExit.showMainWindow()
        return .result()
    }
}

/// Spotlight and Siri phrases (no setup needed; they appear in the Shortcuts app under Skyline).
struct SkylineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WillItRainIntent(), phrases: ["Will it rain in \(.applicationName)",
                                                          "Is rain coming in \(.applicationName)"],
                    shortTitle: "Will It Rain", systemImageName: "cloud.rain")
        AppShortcut(intent: GetWeatherIntent(), phrases: ["Get \(.applicationName) weather", "\(.applicationName) forecast"],
                    shortTitle: "Weather", systemImageName: "cloud.sun")
        AppShortcut(intent: ShowRadarIntent(), phrases: ["Show \(.applicationName) radar"],
                    shortTitle: "Radar", systemImageName: "map")
    }
}
