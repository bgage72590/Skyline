import Foundation

/// What the Accuracy screen shows for one location. Built only from verified pairs (or, behind the
/// `-SkylineDemoAccuracy` launch argument, from clearly flagged demo data).
public struct AccuracyReport: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case collecting, ready }

    public var status: Status
    /// Days since Skyline started recording forecasts for this location.
    public var daysCollected: Double
    /// Verified forecast hours (forecast/observation pairs).
    public var verifiedPairs: Int
    public var pendingForecasts: Int
    public var stationID: String?
    public var stationName: String?
    /// Age-weighted scores over everything verified (≤ 90 days).
    public var overall: [VerificationSource: SourceScore]
    public var byBucket: [LeadBucket: [VerificationSource: SourceScore]]
    /// Lowest temperature MAE over the last 7 days (leads < 48 h), when there's enough to say.
    public var recentWinner: VerificationSource?
    public var recentWinnerMAE: Double?
    /// The learned multipliers currently applied to the blend (neutral until there's enough data).
    public var weights: BlendWeights
    public var minDays: Double
    public var isDemo: Bool

    public init(status: Status, daysCollected: Double, verifiedPairs: Int, pendingForecasts: Int,
                stationID: String?, stationName: String?, overall: [VerificationSource: SourceScore],
                byBucket: [LeadBucket: [VerificationSource: SourceScore]], recentWinner: VerificationSource?,
                recentWinnerMAE: Double?, weights: BlendWeights, minDays: Double, isDemo: Bool = false) {
        self.status = status; self.daysCollected = daysCollected; self.verifiedPairs = verifiedPairs
        self.pendingForecasts = pendingForecasts; self.stationID = stationID; self.stationName = stationName
        self.overall = overall; self.byBucket = byBucket; self.recentWinner = recentWinner
        self.recentWinnerMAE = recentWinnerMAE; self.weights = weights; self.minDays = minDays; self.isDemo = isDemo
    }
}

public enum VerificationKey {
    /// Saved locations use their id. "My Location" is keyed by a ~20 km cell so travelling doesn't mix
    /// one place's errors into another's weights.
    public static func key(for location: WeatherLocation) -> String {
        guard location.isCurrentLocation else { return location.id }
        let c = location.coordinate
        return String(format: "here@%.1f,%.1f", (c.latitude * 5).rounded() / 5, (c.longitude * 5).rounded() / 5)
    }
}

/// Persists issued forecasts, fetches NWS station observations, pairs them, and serves scores and
/// adaptive weights. All work is small, throttled and off the main thread:
/// * at most one issuance per location every 3 h (~21 rows), at most one observation fetch per hour;
/// * JSONL files in Application Support, pruned to 90 days;
/// * scores/weights are cached and recomputed only when new pairs arrive.
public actor ForecastVerifier {
    public static let retentionDays = 90.0
    public static let issueInterval: TimeInterval = 3 * 3600
    public static let observationInterval: TimeInterval = 55 * 60

    struct Meta: Codable {
        var firstIssued: Date?
        var lastIssued: Date?
        var lastObsCheck: Date?
        var stationID: String?
        var stationName: String?
        var stationFetched: Date?
    }

    private let directory: URL
    private let client: HTTPClient
    private let now: @Sendable () -> Date
    private let config: AdaptiveWeighting.Config
    private var loaded = false
    private var pending: [ForecastRecord] = []
    private var verified: [VerifiedRecord] = []
    private var meta: [String: Meta] = [:]
    private var cachedScores: [String: AccuracyScorer.Scores] = [:]
    private var cachedWeights: [String: BlendWeights] = [:]

    public init(directory: URL = ForecastVerifier.defaultDirectory(), client: HTTPClient = URLSessionHTTPClient(),
                config: AdaptiveWeighting.Config = AdaptiveWeighting.Config(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.client = client
        self.config = config
        self.now = now
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.briangage.Skyline/verification", isDirectory: true)
    }

    // MARK: Public API

    /// True when a new issuance for `key` would be recorded (cheap check before sampling).
    public func wantsIssuance(_ key: String) -> Bool {
        load()
        guard let last = meta[key]?.lastIssued else { return true }
        return now().timeIntervalSince(last) >= Self.issueInterval
    }

    public func record(_ records: [ForecastRecord], key: String) {
        guard !records.isEmpty, wantsIssuance(key) else { return }
        let t = now()
        pending.append(contentsOf: records)
        // Cap: never keep more than ~4 days of issuances waiting per location.
        let mine = pending.filter { $0.loc == key }
        if mine.count > 3000 {
            let drop = Set(mine.sorted { $0.valid < $1.valid }.prefix(mine.count - 3000).map { $0 })
            pending.removeAll { drop.contains($0) }
            writeAll(pending, to: "pending.jsonl")
        } else {
            append(records, to: "pending.jsonl")
        }
        meta[key, default: Meta()].lastIssued = t
        if meta[key]?.firstIssued == nil { meta[key]?.firstIssued = t }
        saveMeta()
    }

    /// Fetches observations for due forecasts (hourly at most) and pairs them.
    public func verifyIfDue(key: String, stationsURL: URL?) async {
        load()
        let t = now()
        if let last = meta[key]?.lastObsCheck, t.timeIntervalSince(last) < Self.observationInterval { return }
        let due = pending.filter { $0.loc == key && $0.valid <= t.addingTimeInterval(-20 * 60) }
        guard !due.isEmpty else { return }
        meta[key, default: Meta()].lastObsCheck = t
        guard let station = await station(for: key, stationsURL: stationsURL) else { saveMeta(); return }
        let start = max(due.map(\.valid).min()!.addingTimeInterval(-70 * 60), t.addingTimeInterval(-3 * 86400))
        guard let url = Self.observationsURL(station: station, start: start),
              let data = try? await client.get(url, headers: ["Accept": "application/geo+json"]),
              let obs = try? NWSObservationParser.decode(data) else { saveMeta(); return }
        ingest(observations: obs, key: key)
        saveMeta()
    }

    /// Pairs due forecasts with observations (also used by tests).
    public func ingest(observations obs: [StationObservation], key: String) {
        load()
        let t = now()
        var newPairs: [VerifiedRecord] = []
        var keep: [ForecastRecord] = []
        let latest = obs.map(\.time).max() ?? .distantPast
        for r in pending {
            guard r.loc == key, r.valid <= t.addingTimeInterval(-20 * 60) else { keep.append(r); continue }
            if r.valid <= latest, let o = ObservationAggregator.observe(obs, validTime: r.valid) {
                newPairs.append(VerifiedRecord(r, o))
            } else if r.valid > t.addingTimeInterval(-36 * 3600) {
                keep.append(r) // observations may still arrive
            }
        }
        pending = keep
        writeAll(pending, to: "pending.jsonl")
        if !newPairs.isEmpty {
            verified.append(contentsOf: newPairs)
            append(newPairs, to: "verified.jsonl")
            cachedScores[key] = nil
            cachedWeights[key] = nil
        }
    }

    public func weights(_ key: String) -> BlendWeights {
        load()
        if let w = cachedWeights[key] { return w }
        // Learn from every member's full record (see `dedupingNOAAFamily(dropDuplicates:)`); display stays de-duplicated.
        let learning = AccuracyScorer.score(verified.filter { $0.r.loc == key }, now: now(), dedupe: false)
        let w = AdaptiveWeighting.weights(from: learning, config: config)
        cachedWeights[key] = w
        return w
    }

    public func report(_ key: String) -> AccuracyReport {
        load()
        let s = scores(key)
        let t = now()
        let m = meta[key]
        let recentRecords = verified.filter { $0.r.loc == key && $0.r.valid >= t.addingTimeInterval(-7 * 86400) && $0.r.leadHours < 48 }
        let recent = AccuracyScorer.score(recentRecords, now: t, halfLifeDays: 0)
        let candidates = recent.overall.values.filter { $0.source != .blend && $0.tempN >= config.minSamples }
        let winner = candidates.min { ($0.tempMAE ?? .infinity) < ($1.tempMAE ?? .infinity) }
        let days = m?.firstIssued.map { t.timeIntervalSince($0) / 86400 } ?? 0
        // "Ready" means exactly "the learned weights are in use" (same thresholds, same weighted n).
        let w = weights(key)
        return AccuracyReport(status: w.isNeutral ? .collecting : .ready, daysCollected: days, verifiedPairs: s.pairs,
                              pendingForecasts: pending.filter { $0.loc == key }.count,
                              stationID: m?.stationID, stationName: m?.stationName,
                              overall: s.overall, byBucket: s.byBucket,
                              recentWinner: winner?.source, recentWinnerMAE: winner?.tempMAE,
                              weights: w, minDays: config.minDays)
    }

    // MARK: Internals

    private func scores(_ key: String) -> AccuracyScorer.Scores {
        if let s = cachedScores[key] { return s }
        let s = AccuracyScorer.score(verified.filter { $0.r.loc == key }, now: now())
        cachedScores[key] = s
        return s
    }

    private func station(for key: String, stationsURL: URL?) async -> String? {
        if let id = meta[key]?.stationID, let fetched = meta[key]?.stationFetched,
           now().timeIntervalSince(fetched) < 7 * 86400 { return id }
        guard let stationsURL, let data = try? await client.get(stationsURL, headers: ["Accept": "application/geo+json"]),
              let first = try? NWSObservationParser.firstStation(data) else { return meta[key]?.stationID }
        meta[key, default: Meta()].stationID = first.id
        meta[key]?.stationName = first.name
        meta[key]?.stationFetched = now()
        return first.id
    }

    static func observationsURL(station: String, start: Date) -> URL? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var u = URLComponents(string: "https://api.weather.gov/stations/\(station)/observations")
        u?.queryItems = [URLQueryItem(name: "start", value: f.string(from: start))]
        return u?.url
    }

    // MARK: Files

    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = now().addingTimeInterval(-Self.retentionDays * 86400)
        pending = readAll(ForecastRecord.self, from: "pending.jsonl").filter { $0.valid > now().addingTimeInterval(-2 * 86400) }
        let all = readAll(VerifiedRecord.self, from: "verified.jsonl")
        verified = all.filter { $0.r.valid >= cutoff }
        if verified.count != all.count { writeAll(verified, to: "verified.jsonl") } // prune
        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           let m = try? Self.decoder.decode([String: Meta].self, from: data) { meta = m }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    private func readAll<T: Decodable>(_ type: T.Type, from name: String) -> [T] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? Self.decoder.decode(T.self, from: Data($0)) }
    }

    private func lines<T: Encodable>(_ items: [T]) -> Data {
        var out = Data()
        for item in items {
            guard let d = try? Self.encoder.encode(item) else { continue }
            out.append(d); out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    private func append<T: Encodable>(_ items: [T], to name: String) {
        let url = directory.appendingPathComponent(name)
        let data = lines(items)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writeAll<T: Encodable>(_ items: [T], to name: String) {
        try? lines(items).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func saveMeta() {
        if let d = try? Self.encoder.encode(meta) { try? d.write(to: directory.appendingPathComponent("meta.json"), options: .atomic) }
    }
}
