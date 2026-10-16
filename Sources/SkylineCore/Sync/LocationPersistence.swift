import Foundation

/// Item 1 (saved cities wiped by new builds): where sync may run and with which files, the explicit
/// delete log, the launch reconcile and the one-time recovery. Pure or file-only, so it's testable here.
public enum LocationPersistence {
    public static let bundleID = "com.briangage.Skyline"

    /// Local cities first (their order), then any city from the last-synced state this process lacks,
    /// unless this Mac recorded deleting it (a delete just before a quit or crash stays deleted).
    public static func launchLocations(local: [WeatherLocation], lastSynced: [WeatherLocation],
                                       deleted: [String: Date] = [:]) -> [WeatherLocation] {
        var ids = Set(local.map(\.id))
        var out = local.filter { deleted[$0.id] == nil }
        for l in lastSynced where !l.isCurrentLocation && deleted[l.id] == nil && ids.insert(l.id).inserted { out.append(l) }
        return out
    }
}

/// Where sync reads and writes. nil = no sync at all (an unbundled or test process without an
/// explicit override file: its defaults domain holds another city list, which is what wiped them).
public struct SyncEnvironment: Equatable, Sendable {
    /// sync.json (nil when iCloud Drive is off: cities stay on this Mac).
    public var fileURL: URL?
    public var stateURL: URL
    public var deletionsURL: URL
    /// nil = UserDefaults.standard; otherwise an isolated suite that never touches the real app's defaults.
    public var defaultsSuite: String?
    public var isOverride: Bool { defaultsSuite != nil }

    public static let overrideArgument = "-SkylineSyncFile"
    public static let overrideSuite = "com.briangage.Skyline.synctest"

    public static func resolve(bundleIdentifier: String?, arguments: [String], home: URL,
                               iCloudAvailable: Bool) -> SyncEnvironment? {
        if let i = arguments.firstIndex(of: overrideArgument), arguments.indices.contains(i + 1) {
            // QA hook: everything next to the override file, nothing shared with the real app.
            let file = URL(fileURLWithPath: arguments[i + 1])
            let dir = file.deletingLastPathComponent()
                .appendingPathComponent("." + file.deletingPathExtension().lastPathComponent + "-state", isDirectory: true)
            return SyncEnvironment(fileURL: file, stateURL: dir.appendingPathComponent("sync-state.json"),
                                   deletionsURL: dir.appendingPathComponent("deletions.json"), defaultsSuite: overrideSuite)
        }
        guard bundleIdentifier == LocationPersistence.bundleID else { return nil }
        let support = home.appendingPathComponent("Library/Application Support/\(LocationPersistence.bundleID)", isDirectory: true)
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Skyline/sync.json")
        return SyncEnvironment(fileURL: iCloudAvailable ? icloud : nil, stateURL: support.appendingPathComponent("sync-state.json"),
                               deletionsURL: support.appendingPathComponent("deletions.json"), defaultsSuite: nil)
    }
}

/// The user's deletes, written synchronously (atomic) at delete time so a quit or crash before the next
/// push can't bring the city back. Entries age out after 180 days, like tombstones.
public final class DeletionLog: @unchecked Sendable {
    public let url: URL
    public private(set) var entries: [String: Date]
    private let lock = NSLock()

    public init(url: URL, now: Date = Date()) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let read = (try? Data(contentsOf: url)).flatMap { try? dec.decode([String: Date].self, from: $0) } ?? [:]
        entries = read.filter { now.timeIntervalSince($0.value) < 180 * 86400 }
    }

    public func record(_ id: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = date
        write()
    }

    public func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries.removeValue(forKey: id) != nil else { return }
        write()
    }

    private func write() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        guard let data = try? enc.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public enum LocationRecovery {
    /// Tombstones that no delete action recorded (not in the synced `deletedByUser`, not in this Mac's
    /// log) were inferred by pre-fix builds, i.e. the wipe. One city or many, any timestamps. A bulk
    /// delete made by a fixed build is always recorded, so it is never read as a wipe.
    public static func wipedIDs(removed: [String: Date], userDeleted: [String: Date], localDeletions: [String: Date],
                                present: Set<String>, before cutoff: Date) -> [String] {
        removed.filter { id, at in
            !present.contains(id) && userDeleted[id] == nil && localDeletions[id] == nil && at < cutoff
                && coordinate(fromID: id) != nil
        }.map(\.key).sorted()
    }

    /// Saved-city ids are "%.4f,%.4f" of the coordinate.
    public static func coordinate(fromID id: String) -> Coordinate? {
        let parts = id.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// Cities to add back: legacy records first (they carry names), else rebuilt from the id's coordinate.
    public static func recover(current: [WeatherLocation], legacy: [WeatherLocation], removed: [String: Date],
                               userDeleted: [String: Date] = [:], localDeletions: [String: Date] = [:],
                               before cutoff: Date = .distantFuture) -> [WeatherLocation] {
        var have = Set(current.map(\.id))
        let wiped = wipedIDs(removed: removed, userDeleted: userDeleted, localDeletions: localDeletions,
                             present: have, before: cutoff)
        let legacyByID = Dictionary(legacy.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [WeatherLocation] = []
        for id in wiped where have.insert(id).inserted {
            if let l = legacyByID[id], !l.isCurrentLocation { out.append(l); continue }
            guard let c = coordinate(fromID: id) else { continue }
            out.append(WeatherLocation(id: id, name: String(format: "%.2f, %.2f", c.latitude, c.longitude), coordinate: c))
        }
        return out
    }
}

/// What the coordinator does at launch when this Mac has synced before (testable without AppKit).
public enum LaunchSync {
    public static let recoveryFlagKey = "recovery.wipedCities.v1"

    public struct Plan: Equatable, Sendable {
        public var cities: [WeatherLocation]
        public var recovered: [WeatherLocation]
    }

    /// Reconcile (missing ≠ deleted, recorded deletes stay deleted), then, once per Mac (flag in
    /// `defaults`), add back the cities a pre-fix build tombstoned without a delete action.
    public static func plan(local: [WeatherLocation], last: SyncDocument, deletions: [String: Date],
                            legacy: [WeatherLocation], defaults: UserDefaults, now: Date = Date()) -> Plan {
        var cities = LocationPersistence.launchLocations(local: local, lastSynced: last.locations, deleted: deletions)
        var recovered: [WeatherLocation] = []
        if !defaults.bool(forKey: recoveryFlagKey) {
            recovered = LocationRecovery.recover(current: cities, legacy: legacy, removed: last.removed,
                                                 userDeleted: last.deletedByUser, localDeletions: deletions, before: now)
            cities += recovered
            defaults.set(true, forKey: recoveryFlagKey)
        }
        return Plan(cities: cities, recovered: recovered)
    }
}
