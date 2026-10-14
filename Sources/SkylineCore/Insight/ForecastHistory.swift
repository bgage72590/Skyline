import Foundation

/// What Skyline forecast for each day at one moment: enough to say "tomorrow's high is down 5° since
/// this morning" (T11). Small: about 10 days × 3 numbers.
public struct ForecastSnapshot: Codable, Hashable, Sendable {
    public struct Day: Codable, Hashable, Sendable {
        /// Local midnight of the day (same value as `DailyForecast.date`).
        public var date: Date
        public var high: Double
        public var low: Double
        public var precipitationProbability: Double?
        public init(date: Date, high: Double, low: Double, precipitationProbability: Double?) {
            self.date = date; self.high = high; self.low = low; self.precipitationProbability = precipitationProbability
        }
    }
    public var issued: Date
    public var days: [Day]

    public init(issued: Date, days: [Day]) { self.issued = issued; self.days = days }

    public init(issued: Date, daily: [DailyForecast]) {
        self.issued = issued
        self.days = daily.map { Day(date: $0.date, high: $0.high, low: $0.low, precipitationProbability: $0.precipitationProbability) }
    }

    public func day(_ date: Date) -> Day? { days.first { $0.date == date } }
}

/// Keeps a few recent daily-forecast snapshots per location (one per 3 h, kept 48 h) in one small JSON
/// file in Application Support, so "why the forecast changed" works everywhere, not only where
/// verification runs. All work is tiny and happens off the main thread (actor).
public actor ForecastHistory {
    public static let interval: TimeInterval = 3 * 3600
    public static let keepFor: TimeInterval = 48 * 3600
    /// The comparison snapshot is the one closest to 12 h old, between 9 and 30 h old.
    public static let compareWindow: ClosedRange<TimeInterval> = (9 * 3600)...(30 * 3600)

    private let fileURL: URL?
    private var loaded = false
    private var snapshots: [String: [ForecastSnapshot]] = [:]

    /// `directory == nil` keeps everything in memory (tests).
    public init(directory: URL?) {
        fileURL = directory?.appendingPathComponent("forecast-history.json")
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.briangage.Skyline", isDirectory: true)
    }

    /// The snapshot to compare against now (nil until the location has ~9 h of history).
    public func earlier(_ key: String, now: Date) -> ForecastSnapshot? {
        load()
        let target: TimeInterval = 12 * 3600
        return snapshots[key]?
            .filter { Self.compareWindow.contains(now.timeIntervalSince($0.issued)) }
            .min { abs(now.timeIntervalSince($0.issued) - target) < abs(now.timeIntervalSince($1.issued) - target) }
    }

    /// Saves today's outlook if the last one for this location is at least 3 h old; prunes old ones.
    public func record(_ key: String, daily: [DailyForecast], now: Date) {
        guard !daily.isEmpty else { return }
        load()
        var list = snapshots[key] ?? []
        if let last = list.last, now.timeIntervalSince(last.issued) < Self.interval, now >= last.issued { return }
        list.append(ForecastSnapshot(issued: now, daily: Array(daily.prefix(10))))
        list.removeAll { now.timeIntervalSince($0.issued) > Self.keepFor || $0.issued > now }
        snapshots[key] = list
        // Locations with nothing recent (removed cities, old "My Location" cells) drop out.
        snapshots = snapshots.filter { $0.value.contains { now.timeIntervalSince($0.issued) <= Self.keepFor } }
        save()
    }

    public func count(_ key: String) -> Int { load(); return snapshots[key]?.count ?? 0 }

    /// Forgets the saved outlooks ("why it changed" starts over), on disk too (L23).
    public func reset() {
        snapshots = [:]
        loaded = true
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [ForecastSnapshot]].self, from: data) else { return }
        snapshots = decoded
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
