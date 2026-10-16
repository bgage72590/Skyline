import Foundation

/// Item 1 (saved cities wiped by new builds). Two pieces of pure logic, kept here so they're testable:
///
/// * `launchLocations`: at launch, a city in the last-synced state but missing from this process's
///   UserDefaults was NOT removed by the user (nobody can remove a city while the app isn't running).
///   It means this process reads a different or stale defaults domain (e.g. an unbundled
///   `.build/…/Skyline` run uses the "Skyline" domain), and treating the gap as a removal stamped
///   "now" used to beat every add and wipe the cities on every Mac through sync.json.
/// * `LocationRecovery`: finds cities a past wipe tombstoned so a one-time migration can bring them back.
public enum LocationPersistence {
    public static let bundleID = "com.briangage.Skyline"

    /// Sync may only run in the real app (or with an explicit test sync file): another defaults domain
    /// would read a different city list but share sync-state.json and sync.json.
    public static func syncAllowed(bundleIdentifier: String?, hasOverrideFile: Bool) -> Bool {
        hasOverrideFile || bundleIdentifier == bundleID
    }

    /// Local cities first (their order), then any city from the last-synced state this process lacks.
    public static func launchLocations(local: [WeatherLocation], lastSynced: [WeatherLocation]) -> [WeatherLocation] {
        var ids = Set(local.map(\.id))
        var out = local
        for l in lastSynced where !l.isCurrentLocation && ids.insert(l.id).inserted { out.append(l) }
        return out
    }
}

public enum LocationRecovery {
    /// The sidebar removes one city per action, so two or more ids tombstoned at the same instant are
    /// the signature of the launch wipe, not a user's choice. Single removals are left alone.
    public static func wipedIDs(removed: [String: Date], present: Set<String>, minimumBatch: Int = 2) -> [String] {
        let groups = Dictionary(grouping: removed.filter { !present.contains($0.key) }, by: { $0.value })
        return groups.values.filter { $0.count >= minimumBatch }.flatMap { $0.map(\.key) }.sorted()
    }

    /// Saved-city ids are "%.4f,%.4f" of the coordinate.
    public static func coordinate(fromID id: String) -> Coordinate? {
        let parts = id.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// Cities to add back: full records from legacy stores first (they carry names), then wiped ids
    /// rebuilt from their coordinates (named later by reverse geocoding). Never duplicates `current`.
    public static func recover(current: [WeatherLocation], legacy: [WeatherLocation],
                               removed: [String: Date]) -> [WeatherLocation] {
        var have = Set(current.map(\.id))
        var out: [WeatherLocation] = []
        let wiped = Set(wipedIDs(removed: removed, present: have))
        for l in legacy where !l.isCurrentLocation && wiped.contains(l.id) && have.insert(l.id).inserted { out.append(l) }
        for id in wiped.sorted() where !have.contains(id) {
            guard let c = coordinate(fromID: id) else { continue }
            have.insert(id)
            out.append(WeatherLocation(id: id, name: String(format: "%.2f, %.2f", c.latitude, c.longitude), coordinate: c))
        }
        return out
    }
}
