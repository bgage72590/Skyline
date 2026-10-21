import Foundation

/// Isolated, unsynced measurement store for Accuracy PR 1.
/// Path: `Application Support/com.briangage.Skyline/verification/benchmark/`.
/// Never writes to verified.jsonl, accuracy.json, or sync.json. Caps retention and total size.
public actor BenchmarkStore {
    public static let retentionDays = 45.0
    public static let maxRecordsPerCity = 4_000
    public static let maxTotalBytes = 10 * 1024 * 1024
    public static let metNorwayIssueInterval: TimeInterval = 3 * 3600

    public struct Meta: Codable, Sendable {
        var station: MetarStationPick?
        var lastMetNorwayFetch: Date?
        var lastMetarBatch: Date?
        var lastSummaryAt: Date?
        var cityElevationM: Double?
        /// Review fix: negative / failure cache for the AWC station search.
        var noStationUntil: Date?
        var lastDailyIssue: Date?
        init(station: MetarStationPick? = nil, lastMetNorwayFetch: Date? = nil, lastMetarBatch: Date? = nil,
             lastSummaryAt: Date? = nil, cityElevationM: Double? = nil,
             noStationUntil: Date? = nil, lastDailyIssue: Date? = nil) {
            self.station = station; self.lastMetNorwayFetch = lastMetNorwayFetch
            self.lastMetarBatch = lastMetarBatch; self.lastSummaryAt = lastSummaryAt
            self.cityElevationM = cityElevationM
            self.noStationUntil = noStationUntil; self.lastDailyIssue = lastDailyIssue
        }
    }

    public struct GlobalMeta: Codable, Sendable {
        var lastAWCBatchAt: Date?
        var knownStationIDs: [String] = []
        var requestCountWindowStart: Date?
        var requestCountInWindow: Int = 0
        init(lastAWCBatchAt: Date? = nil, knownStationIDs: [String] = [],
             requestCountWindowStart: Date? = nil, requestCountInWindow: Int = 0) {
            self.lastAWCBatchAt = lastAWCBatchAt; self.knownStationIDs = knownStationIDs
            self.requestCountWindowStart = requestCountWindowStart
            self.requestCountInWindow = requestCountInWindow
        }
    }

    private let directory: URL
    private let client: HTTPClient
    private let now: @Sendable () -> Date
    private var loaded = false
    private var meta: [String: Meta] = [:]
    private var global = GlobalMeta()
    private var metars: [MetarObservationRecord] = []
    private var dailyIssues: [DailyForecastIssue] = []
    private var dailyObs: [DailyObservedExtremes] = []
    private var metCache: [String: MetNorwayCacheEntry] = [:]
    private var summaries: [String: BenchmarkSummary] = [:]
    /// Hourly Skyline/NWS/Best Match/MET Norway temps recorded for benchmark MAE (isolated).
    private var hourlyBench: [BenchmarkHourlyPair] = []

    public init(directory: URL = BenchmarkStore.defaultDirectory(), client: HTTPClient = URLSessionHTTPClient(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.client = client
        self.now = now
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.briangage.Skyline/verification/benchmark", isDirectory: true)
    }

    /// Parent of the classic verification directory → sibling `benchmark/`.
    public static func directoryAlongside(verification: URL) -> URL {
        verification.appendingPathComponent("benchmark", isDirectory: true)
    }

    // MARK: Public API

    public func summary(for key: String) -> BenchmarkSummary? {
        load()
        return summaries[key]
    }

    public func station(for key: String) -> MetarStationPick? {
        load()
        return meta[key]?.station
    }

    public func metarCount(for key: String) -> Int {
        load()
        return metars.filter { $0.loc == key }.count
    }

    public func metarObservations(for key: String) -> [StationObservation] {
        load()
        return METARClient.asStationObservations(metars.filter { $0.loc == key })
    }

    public func dailyObsCount(for key: String) -> Int {
        load()
        return dailyObs.filter { $0.loc == key }.count
    }

    public func hourlyBenchCount(for key: String) -> Int {
        load()
        return hourlyBench.filter { $0.loc == key }.count
    }

    public func totalByteSize() -> Int {
        load()
        let names = ["metars.jsonl", "daily-issues.jsonl", "daily-obs.jsonl", "hourly.jsonl",
                     "met-cache.json", "meta.json", "global.json", "summaries.json"]
        return names.reduce(0) { sum, name in
            let url = directory.appendingPathComponent(name)
            let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            return sum + n
        }
    }

    /// US cities keep the NWS/ASOS path; non-US cities pick a METAR within 50 km.
    public func ensureStation(key: String, near point: Coordinate, isUS: Bool,
                              cityElevationM: Double? = nil) async -> MetarStationPick? {
        load()
        assertOffMain()
        if isUS { return nil }
        if let s = meta[key]?.station, now().timeIntervalSince(s.pickedAt) < METARClient.stationCacheDays * 86400 {
            return s
        }
        if let until = meta[key]?.noStationUntil, now() < until { return nil }
        let box = METARClient.searchBBox(around: point)
        let url = Endpoints.awcStationInfo(bbox: box.0, box.1, box.2, box.3)
        guard noteRequest(),
              let result = try? await client.fetch(url, headers: ["Accept": "application/json"]),
              (200..<300).contains(result.statusCode) || result.isNoContent else {
            if meta[key]?.station == nil { meta[key, default: Meta()].noStationUntil = now().addingTimeInterval(6 * 3600); saveMeta() }
            return meta[key]?.station
        }
        let stations = result.isNoContent ? [] : METARClient.decodeStations(result.data)
        guard let pick = METARClient.pickNearest(stations, near: point, cityElevationM: cityElevationM) else {
            meta[key, default: Meta()].noStationUntil = now().addingTimeInterval(METARClient.stationCacheDays * 86400)
            saveMeta()
            return nil
        }
        var m = meta[key] ?? Meta()
        m.station = pick
        m.cityElevationM = cityElevationM
        meta[key] = m
        if !global.knownStationIDs.contains(pick.stationID) {
            global.knownStationIDs.append(pick.stationID)
            saveGlobal()
        }
        saveMeta()
        return pick
    }

    /// One batched AWC METAR request per hour for all known non-US stations.
    @discardableResult
    public func fetchMetarsIfDue(for key: String) async -> [MetarObservationRecord] {
        load()
        assertOffMain()
        guard let station = meta[key]?.station else { return [] }
        let t = now()
        let jitter = METARClient.jitter(for: key)
        if let last = global.lastAWCBatchAt, t.timeIntervalSince(last) < METARClient.batchInterval + jitter {
            return metars.filter { $0.loc == key && $0.stationID == station.stationID }
        }
        let ids = Array(Set(meta.values.compactMap(\.station?.stationID) + [station.stationID])).sorted()
        guard !ids.isEmpty, noteRequest() else { return [] }
        let url = Endpoints.awcMetar(ids: ids, hours: 6)
        guard let result = try? await client.fetch(url, headers: ["Accept": "application/json"]) else {
            return []
        }
        global.lastAWCBatchAt = t
        saveGlobal()
        if result.statusCode == 429 || result.statusCode >= 500 || result.statusCode == 403 { return [] }
        if result.isNoContent { return [] }
        if result.isDeprecated { /* logged by caller if needed */ }
        // Decode once; assign each row to every city that shares that station.
        let byStation = Dictionary(grouping: METARClient.decodeMetars(result.data, loc: "", reference: t), by: \.stationID)
        var added: [MetarObservationRecord] = []
        for (city, m) in meta {
            guard let sid = m.station?.stationID, let rows = byStation[sid] else { continue }
            for r in rows {
                let rec = MetarObservationRecord(loc: city, stationID: r.stationID, time: r.time,
                                                 temperatureC: r.temperatureC, windKmh: r.windKmh,
                                                 wet: r.wet, raw: r.raw)
                if !metars.contains(where: { $0.loc == city && $0.stationID == rec.stationID
                    && abs($0.time.timeIntervalSince(rec.time)) < 30 }) {
                    metars.append(rec)
                    added.append(rec)
                }
            }
        }
        if !added.isEmpty {
            append(added, to: "metars.jsonl")
            pruneIfDue()
            recomputeSummaries()
        }
        return added.filter { $0.loc == key }
    }

    /// Fetch MET Norway at most once per city per 3 h issuance; honour Expires / If-Modified-Since.
    @discardableResult
    public func fetchMetNorwayIfDue(key: String, coordinate: Coordinate) async -> [MetNorwayHour] {
        load()
        assertOffMain()
        let t = now()
        // Jitter the due time (0…4 min) so cities don't fire together on the hour.
        let dueAfter = Self.metNorwayIssueInterval + METARClient.jitter(for: key)
        if let last = meta[key]?.lastMetNorwayFetch, t.timeIntervalSince(last) < dueAfter {
            return metCache[key]?.hourly ?? []
        }
        guard noteRequest() else { return metCache[key]?.hourly ?? [] }
        let outcome = await METNorwayClient.fetch(coordinate: coordinate, loc: key, client: client,
                                                  cached: metCache[key], now: t)
        guard let outcome else { return metCache[key]?.hourly ?? [] }
        meta[key, default: Meta()].lastMetNorwayFetch = t
        saveMeta()
        let entry = MetNorwayCacheEntry(loc: key, fetchedAt: t, lastModified: outcome.lastModified,
                                        expires: outcome.expires, body: outcome.body, hourly: outcome.hours)
        metCache[key] = entry
        saveMetCache()
        return outcome.hours
    }

    public func recordDailyIssues(_ issues: [DailyForecastIssue]) {
        load()
        assertOffMain()
        // Review fix: at most one issuance per city per 3 h, and only days that haven't started yet
        // (a same-day "forecast" is mostly observation and makes the daily MAE meaningless).
        var keep: [DailyForecastIssue] = []
        for (loc, rows) in Dictionary(grouping: issues, by: \.loc) {
            guard let issued = rows.map(\.issued).min() else { continue }
            if let last = meta[loc]?.lastDailyIssue, issued.timeIntervalSince(last) < Self.metNorwayIssueInterval { continue }
            let future = rows.filter { $0.localDay > $0.issued }
            guard !future.isEmpty else { continue }
            meta[loc, default: Meta()].lastDailyIssue = issued
            keep.append(contentsOf: future)
        }
        guard !keep.isEmpty else { return }
        saveMeta()
        dailyIssues.append(contentsOf: keep)
        append(keep, to: "daily-issues.jsonl")
        pruneIfDue()
    }

    public func recordHourlyPairs(_ pairs: [BenchmarkHourlyPair]) {
        load()
        assertOffMain()
        // Review fix: the same (city, source, issue, valid) pair is offered on every refresh; keep it once.
        struct K: Hashable { var loc: String; var kind: BenchmarkForecastKind; var issued: Date; var valid: Date }
        var seen = Set(hourlyBench.map { K(loc: $0.loc, kind: $0.kind, issued: $0.issued, valid: $0.valid) })
        let fresh = pairs.filter { seen.insert(K(loc: $0.loc, kind: $0.kind, issued: $0.issued, valid: $0.valid)).inserted }
        guard !fresh.isEmpty else { return }
        hourlyBench.append(contentsOf: fresh)
        append(fresh, to: "hourly.jsonl")
        pruneIfDue()
        recomputeSummaries()
    }

    /// Score completed local days from METAR (or injected NWS) temperatures.
    public func scoreCompletedDays(key: String, timeZoneIdentifier: String,
                                   extraTemps: [(Date, Double)] = []) {
        load()
        assertOffMain()
        guard let tz = TimeZone(identifier: timeZoneIdentifier) else { return }
        let t = now()
        var temps = metars.filter { $0.loc == key }.compactMap { r -> (Date, Double)? in
            guard let c = r.temperatureC else { return nil }
            return (r.time, c)
        }
        temps.append(contentsOf: extraTemps)
        guard let earliest = temps.map(\.0).min() else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var day = cal.startOfDay(for: earliest)
        let last = cal.startOfDay(for: t)
        var newObs: [DailyObservedExtremes] = []
        while day < last {
            defer { day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400) }
            if dailyObs.contains(where: { $0.loc == key && abs($0.localDay.timeIntervalSince(day)) < 1 }) { continue }
            guard let ext = LocalDayAggregator.extremes(temps: temps, day: day, timeZone: tz, now: t) else { continue }
            let obs = DailyObservedExtremes(loc: key, localDay: day, timeZoneIdentifier: timeZoneIdentifier,
                                            highC: ext.high, lowC: ext.low, distinctHours: ext.hours,
                                            stationID: meta[key]?.station?.stationID,
                                            source: extraTemps.isEmpty ? "metar" : "nws_or_metar")
            dailyObs.append(obs)
            newObs.append(obs)
        }
        if !newObs.isEmpty {
            append(newObs, to: "daily-obs.jsonl")
            recomputeSummaries()
        }
    }

    /// Seed helpers for tests (bypass network).
    public func seedStation(_ pick: MetarStationPick, key: String) {
        load()
        meta[key, default: Meta()].station = pick
        if !global.knownStationIDs.contains(pick.stationID) { global.knownStationIDs.append(pick.stationID) }
        saveMeta(); saveGlobal()
    }

    public func seedMetars(_ rows: [MetarObservationRecord]) {
        load()
        metars.append(contentsOf: rows)
        append(rows, to: "metars.jsonl")
        prune(); recomputeSummaries()
    }

    public func seedDailyObs(_ rows: [DailyObservedExtremes]) {
        load()
        dailyObs.append(contentsOf: rows)
        append(rows, to: "daily-obs.jsonl")
        recomputeSummaries()
    }

    public func seedHourly(_ rows: [BenchmarkHourlyPair]) {
        load()
        hourlyBench.append(contentsOf: rows)
        append(rows, to: "hourly.jsonl")
        prune(); recomputeSummaries()
    }

    public func seedMetCache(_ entry: MetNorwayCacheEntry) {
        load()
        metCache[entry.loc] = entry
        saveMetCache()
    }

    public func forceRecomputeSummaries() {
        load()
        recomputeSummaries()
    }

    // MARK: Internals

    private func recomputeSummaries() {
        let keys = Set(meta.keys)
            .union(metars.map(\.loc))
            .union(hourlyBench.map(\.loc))
            .union(dailyObs.map(\.loc))
        for key in keys {
            summaries[key] = BenchmarkScorer.summary(
                hourly: hourlyBench.filter { $0.loc == key },
                dailyIssues: dailyIssues.filter { $0.loc == key },
                dailyObs: dailyObs.filter { $0.loc == key },
                station: meta[key]?.station
            )
        }
        saveSummaries()
    }

    private var lastPruneAt: Date?
    /// Review fix: full rewrite of every file at most hourly (and at load), not on every append.
    private func pruneIfDue() {
        if let last = lastPruneAt, now().timeIntervalSince(last) < 3600, totalByteSize() <= Self.maxTotalBytes { return }
        prune()
    }

    private func fileSize(_ name: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func prune() {
        lastPruneAt = now()
        let cutoff = now().addingTimeInterval(-Self.retentionDays * 86400)
        metars = capped(metars.filter { $0.time >= cutoff }, perCity: \.loc, time: \.time)
        dailyIssues = capped(dailyIssues.filter { $0.issued >= cutoff }, perCity: \.loc, time: \.issued)
        dailyObs = capped(dailyObs.filter { $0.localDay >= cutoff }, perCity: \.loc, time: \.localDay)
        hourlyBench = capped(hourlyBench.filter { $0.valid >= cutoff }, perCity: \.loc, time: \.valid)
        writeAll(metars, to: "metars.jsonl")
        writeAll(dailyIssues, to: "daily-issues.jsonl")
        writeAll(dailyObs, to: "daily-obs.jsonl")
        writeAll(hourlyBench, to: "hourly.jsonl")
        // Hard size ceiling, one pass per file (review fix: the old loop re-encoded and rewrote the whole
        // file once per distinct timestamp). Oldest rows go first, hourly pairs before METARs as before.
        var excess = totalByteSize() - Self.maxTotalBytes
        if excess > 0, !hourlyBench.isEmpty {
            let size = max(1, fileSize("hourly.jsonl"))
            let drop = min(hourlyBench.count, Int(Double(excess) / Double(size) * Double(hourlyBench.count)) + 1)
            hourlyBench.sort { $0.valid < $1.valid }
            hourlyBench.removeFirst(drop)
            writeAll(hourlyBench, to: "hourly.jsonl")
            excess = totalByteSize() - Self.maxTotalBytes
        }
        if excess > 0, !metars.isEmpty {
            let size = max(1, fileSize("metars.jsonl"))
            let drop = min(metars.count, Int(Double(excess) / Double(size) * Double(metars.count)) + 1)
            metars.sort { $0.time < $1.time }
            metars.removeFirst(drop)
            writeAll(metars, to: "metars.jsonl")
        }
    }

    private func capped<T>(_ items: [T], perCity: (T) -> String, time: (T) -> Date) -> [T] {
        var out: [T] = []
        let groups = Dictionary(grouping: items, by: perCity)
        for (_, rows) in groups {
            let sorted = rows.sorted { time($0) < time($1) }
            out.append(contentsOf: sorted.suffix(Self.maxRecordsPerCity))
        }
        return out
    }

    /// Track AWC/MET request rate; refuse when a tight loop would exceed 100/min.
    private func noteRequest() -> Bool {
        let t = now()
        if let start = global.requestCountWindowStart, t.timeIntervalSince(start) < 60 {
            if global.requestCountInWindow >= METARClient.maxRequestsPerMinute { return false }
            global.requestCountInWindow += 1
        } else {
            global.requestCountWindowStart = t
            global.requestCountInWindow = 1
        }
        saveGlobal()
        return true
    }

    private func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metars = readAll(MetarObservationRecord.self, from: "metars.jsonl")
        dailyIssues = readAll(DailyForecastIssue.self, from: "daily-issues.jsonl")
        dailyObs = readAll(DailyObservedExtremes.self, from: "daily-obs.jsonl")
        hourlyBench = readAll(BenchmarkHourlyPair.self, from: "hourly.jsonl")
        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           let m = try? Self.decoder.decode([String: Meta].self, from: data) { meta = m }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("global.json")),
           let g = try? Self.decoder.decode(GlobalMeta.self, from: data) { global = g }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("met-cache.json")),
           let c = try? Self.decoder.decode([String: MetNorwayCacheEntry].self, from: data) { metCache = c }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("summaries.json")),
           let s = try? Self.decoder.decode([String: BenchmarkSummary].self, from: data) { summaries = s }
        prune()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    private func readAll<T: Decodable>(_ type: T.Type, from name: String) -> [T] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return [] }
        // Corrupt lines are skipped.
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
        if let d = try? Self.encoder.encode(meta) {
            try? d.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private func saveGlobal() {
        if let d = try? Self.encoder.encode(global) {
            try? d.write(to: directory.appendingPathComponent("global.json"), options: .atomic)
        }
    }

    private func saveMetCache() {
        if let d = try? Self.encoder.encode(metCache) {
            try? d.write(to: directory.appendingPathComponent("met-cache.json"), options: .atomic)
        }
    }

    private func saveSummaries() {
        if let d = try? Self.encoder.encode(summaries) {
            try? d.write(to: directory.appendingPathComponent("summaries.json"), options: .atomic)
        }
    }
}

/// One hourly forecast vs observation pair kept only in the benchmark store.
public struct BenchmarkHourlyPair: Codable, Hashable, Sendable {
    public var loc: String
    public var issued: Date
    public var valid: Date
    public var kind: BenchmarkForecastKind
    public var forecastC: Double
    public var observedC: Double

    public init(loc: String, issued: Date, valid: Date, kind: BenchmarkForecastKind,
                forecastC: Double, observedC: Double) {
        self.loc = loc; self.issued = issued; self.valid = valid
        self.kind = kind; self.forecastC = forecastC; self.observedC = observedC
    }
}
