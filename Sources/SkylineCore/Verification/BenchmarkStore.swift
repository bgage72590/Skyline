import Foundation

/// Isolated, unsynced measurement store for Accuracy PR 1.
/// Path: `Application Support/com.briangage.Skyline/verification/benchmark/`.
/// Never writes to verified.jsonl, accuracy.json, or sync.json. Caps retention and total size.
public actor BenchmarkStore {
    public static let retentionDays = 45.0
    public static let maxRecordsPerCity = 4_000
    public static let maxTotalBytes = 10 * 1024 * 1024
    public static let metNorwayIssueInterval: TimeInterval = 3 * 3600
    /// Fix 4: record MET samples only when cache fetchedAt is this fresh (derived; no new hour literal).
    public static var metNorwaySampleMaxAge: TimeInterval { metNorwayIssueInterval }
    /// One day in seconds (named so Form4 expiry / negative-cache literals stay readable).
    public static let secondsPerDay: TimeInterval = 86_400
    /// Fix 4: drop pending whose valid is older than this without an observation.
    public static let metPendingExpiry: TimeInterval = 2 * secondsPerDay
    /// Fix 4: hard cap on met-pending.jsonl rows (global backstop).
    public static let metPendingCap = 10_000
    /// H1: per-city pending cap (~12 fetches × 120 hours). Non-binding, but at least six fetches.
    public static let metPendingPerCityCap = 1_500
    /// H1: cap eviction never drops a row whose valid time is inside this many hours.
    public static let metPendingProtectHours: Double = 6
    /// H2: a station with no METAR rows after this long is retired on the next successful batch.
    static let metarDeadStationAfter: TimeInterval = 3 * 3600
    /// H2: unverified picks (and network failures) recheck after this long, not the 7-day cache.
    static let unverifiedStationRecheck: TimeInterval = 6 * 3600
    /// H2: liveness check covers the nearest this-many METAR candidates in one AWC request.
    static let livenessCandidateCount = 5

    public struct Meta: Codable, Sendable {
        var station: MetarStationPick?
        var lastMetNorwayFetch: Date?
        var lastMetarBatch: Date?
        var lastSummaryAt: Date?
        var cityElevationM: Double?
        /// Review fix: negative / failure cache for the AWC station search.
        var noStationUntil: Date?
        var lastDailyIssue: Date?
        /// Fix 3: 24 h negative cache after a failed US NWS stations seed.
        var noUSStationSeedUntil: Date?
        /// H2: station IDs that returned no METARs, with the time they were marked dead (TTL 7 days).
        var deadStationIDs: [String: Date]?
        init(station: MetarStationPick? = nil, lastMetNorwayFetch: Date? = nil, lastMetarBatch: Date? = nil,
             lastSummaryAt: Date? = nil, cityElevationM: Double? = nil,
             noStationUntil: Date? = nil, lastDailyIssue: Date? = nil,
             noUSStationSeedUntil: Date? = nil, deadStationIDs: [String: Date]? = nil) {
            self.station = station; self.lastMetNorwayFetch = lastMetNorwayFetch
            self.lastMetarBatch = lastMetarBatch; self.lastSummaryAt = lastSummaryAt
            self.cityElevationM = cityElevationM
            self.noStationUntil = noStationUntil; self.lastDailyIssue = lastDailyIssue
            self.noUSStationSeedUntil = noUSStationSeedUntil
            self.deadStationIDs = deadStationIDs
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
    /// Fix 4: MET Norway forecasts awaiting observations (additive file).
    private var metPending: [MetPendingSample] = []
    /// Compact training rows (Accuracy PR 2). Cap 200/city×target, 180 d, 2 MB hard ceiling.
    private var training: [TrainingRow] = []
    private var lastTrainingPruneAt: Date?
    /// METAR→AdaptiveWeighting pairs (non-US only; never written to verified.jsonl).
    private var metarVerified: [VerifiedRecord] = []
    /// Eagerly-loaded correction state (tiny); must not pull large jsonl history.
    private var correctionsFile = CorrectionsFile()
    private var correctionsLoaded = false
    /// Test seam: bytes written since last reset of the counter (append path only).
    private var bytesWrittenSeam = 0

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

    /// Persist NWS temperatures (already fetched by verifyIfDue) so US daily high/low can reach 20 distinct hours.
    public func recordNWSTemps(key: String, stationID: String?, obs: [StationObservation]) {
        load()
        assertOffMain()
        let have = Set(metars.filter { $0.loc == key }.map(\.time))
        var seen = have
        let rows = obs.compactMap { o -> MetarObservationRecord? in
            guard let t = o.temperatureC, seen.insert(o.time).inserted else { return nil }
            return MetarObservationRecord(loc: key, stationID: stationID ?? "NWS", time: o.time, temperatureC: t, windKmh: o.windKmh, wet: o.precipitating)
        }
        guard !rows.isEmpty else { return }
        metars.append(contentsOf: rows)
        append(rows, to: "metars.jsonl")
        pruneIfDue()
    }

    public func dailyObsCount(for key: String) -> Int {
        load()
        return dailyObs.filter { $0.loc == key }.count
    }

    /// Daily forecast issues retained for `key` (after DST scrub on load/prune).
    public func dailyIssues(for key: String) -> [DailyForecastIssue] {
        load()
        return dailyIssues.filter { $0.loc == key }
    }

    public func dailyIssueCount(for key: String) -> Int {
        load()
        return dailyIssues.filter { $0.loc == key }.count
    }

    public func hourlyBenchCount(for key: String) -> Int {
        load()
        return hourlyBench.filter { $0.loc == key }.count
    }

    public func totalByteSize() -> Int {
        load()
        let names = ["metars.jsonl", "daily-issues.jsonl", "daily-obs.jsonl", "hourly.jsonl",
                     "met-cache.json", "meta.json", "global.json", "summaries.json",
                     "training.jsonl", "corrections.json", "metar-verified.jsonl"]
        return names.reduce(0) { sum, name in
            let url = directory.appendingPathComponent(name)
            let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            return sum + n
        }
    }

    /// Bytes appended via `append` since the last `resetBytesWrittenSeam()` (B3 test seam).
    public func bytesWrittenSinceSeamReset() -> Int { bytesWrittenSeam }
    public func resetBytesWrittenSeam() { bytesWrittenSeam = 0 }

    public func trainingCount(for key: String) -> Int {
        load(); loadCorrectionsOnly()
        return training.filter { $0.loc == key }.count
    }

    public func trainingRows(for key: String, target: CorrectionTarget? = nil) -> [TrainingRow] {
        load()
        return training.filter { $0.loc == key && (target == nil || $0.target == target) }
    }

    public func metarVerifiedCount(for key: String) -> Int {
        load()
        return metarVerified.filter { $0.r.loc == key }.count
    }

    public func metarVerifiedRecords(for key: String) -> [VerifiedRecord] {
        load()
        return metarVerified.filter { $0.r.loc == key }
    }

    public func distinctMetarDays(for key: String) -> Int {
        load()
        let days = Set(metars.filter { $0.loc == key }.map { Int($0.time.timeIntervalSince1970 / 86400) })
        return days.count
    }

    /// Eager corrections.json only — never loads large jsonl (B16).
    public func loadCorrectionsOnly() {
        guard !correctionsLoaded else { return }
        correctionsLoaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("corrections.json")),
           let f = try? Self.decoder.decode(CorrectionsFile.self, from: data) {
            correctionsFile = f
        }
    }

    public func correctionsSnapshot() -> CorrectionsFile {
        loadCorrectionsOnly()
        return correctionsFile
    }

    public func correctionEntry(loc: String, target: CorrectionTarget) -> CorrectionEntry? {
        loadCorrectionsOnly()
        return correctionsFile.entry(loc: loc, target: target)
    }

    public func saveCorrections(_ file: CorrectionsFile) {
        assertOffMain()
        loadCorrectionsOnly()
        correctionsFile = file
        guard let d = try? Self.encoder.encode(file), d.count <= BiasCorrection.correctionsMaxBytes else { return }
        try? d.write(to: directory.appendingPathComponent("corrections.json"), options: .atomic)
    }

    /// Clears every benchmark / correction / training file (B15).
    public func reset() {
        assertOffMain()
        metars = []; dailyIssues = []; dailyObs = []; hourlyBench = []; metPending = []
        training = []; metarVerified = []; metCache = [:]; summaries = [:]
        meta = [:]; global = GlobalMeta()
        correctionsFile = CorrectionsFile(); correctionsLoaded = true; loaded = true
        lastPruneAt = nil; lastTrainingPruneAt = nil; bytesWrittenSeam = 0
        let names = ["metars.jsonl", "daily-issues.jsonl", "daily-obs.jsonl", "hourly.jsonl",
                     "met-cache.json", "meta.json", "global.json", "summaries.json",
                     "training.jsonl", "corrections.json", "metar-verified.jsonl", "met-pending.jsonl"]
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Fix 3 — US station seed helpers

    public func shouldSkipUSStationSeed(key: String, now: Date) -> Bool {
        load()
        if let until = meta[key]?.noUSStationSeedUntil, now < until { return true }
        return false
    }

    public func noteUSStationSeedFailure(key: String, until: Date) {
        load()
        meta[key, default: Meta()].noUSStationSeedUntil = until
        saveMeta()
    }

    // MARK: Fix 4 — MET Norway pending

    public func metNorwayFetchedAt(for key: String) -> Date? {
        load()
        return metCache[key]?.fetchedAt
    }

    /// Pending rows for one city (tests and migration checks).
    public func metPendingSamples(for key: String? = nil) -> [MetPendingSample] {
        load()
        guard let key else { return metPending }
        return metPending.filter { $0.loc == key }
    }

    /// Append MET pending samples once per MET fetch. Freshness guard is unchanged.
    /// New rows store `issued` = `fetchedAt` (when the forecast was obtained), not the refresh clock.
    /// Dedupe key is (loc, fetchedAt, valid hour). An unchanged value from an earlier fetch within 1 h is skipped.
    public func recordMetPending(key: String, issued: Date, hours: [MetNorwayHour], fetchedAt: Date?) {
        load()
        assertOffMain()
        guard let fetchedAt, issued.timeIntervalSince(fetchedAt) <= Self.metNorwaySampleMaxAge,
              issued.timeIntervalSince(fetchedAt) >= 0 else { return }
        let aligned = ForecastSampler.metNorwayHourlyValues(fetchedAt: fetchedAt, hours: hours)
        // Lead-ladder samples (valid = issued + lead, often off the hour) are kept only when the
        // series has no on-the-hour times. Live MET hours are on the hour, so this is the pre-H1 path.
        let values: [(valid: Date, t: Double)] = aligned.isEmpty
            ? ForecastSampler.metNorwayLeadValues(location: key, issued: issued, hours: hours).filter { $0.valid > issued }
            : aligned
        let mine = metPending.filter { $0.loc == key }
        struct FK: Hashable { var fetched: Date; var hour: Int }
        var seen = Set(mine.compactMap { row -> FK? in
            guard let f = row.fetchedAt else { return nil }
            return FK(fetched: f, hour: ForecastSampler.hourBucket(row.valid))
        })
        var fresh: [MetPendingSample] = []
        for (valid, t) in values {
            let hour = ForecastSampler.hourBucket(valid)
            let fetchKey = FK(fetched: fetchedAt, hour: hour)
            guard seen.insert(fetchKey).inserted else { continue }
            let sameValueRecently = mine.contains { existing in
                guard let earlier = existing.fetchedAt else { return false }
                guard ForecastSampler.hourBucket(existing.valid) == hour, existing.forecastC == t else { return false }
                let delta = fetchedAt.timeIntervalSince(earlier)
                return delta > 0 && delta <= 3600
            }
            if sameValueRecently { continue }
            fresh.append(MetPendingSample(loc: key, issued: fetchedAt, valid: valid, forecastC: t, fetchedAt: fetchedAt))
        }
        guard !fresh.isEmpty else { return }
        metPending.append(contentsOf: fresh)
        append(fresh, to: "met-pending.jsonl")
        pruneMetPendingIfNeeded(rewrite: false)
    }

    /// Score due MET pending against observations; remove scored/expired samples.
    public func scoreMetPending(key: String, observations obs: [StationObservation],
                                now: Date) -> [BenchmarkHourlyPair] {
        load()
        assertOffMain()
        var pairs: [BenchmarkHourlyPair] = []
        var keep: [MetPendingSample] = []
        var removed = false
        let dueCutoff = now.addingTimeInterval(-20 * 60)
        let expiryCutoff = now.addingTimeInterval(-Self.metPendingExpiry)
        for s in metPending {
            guard s.loc == key else { keep.append(s); continue }
            if s.valid <= expiryCutoff { removed = true; continue }
            if s.valid <= dueCutoff, let o = ObservationAggregator.observe(obs, validTime: s.valid),
               let ot = o.t {
                pairs.append(BenchmarkHourlyPair(loc: s.loc, issued: s.fetchedAt ?? s.issued, valid: s.valid,
                                                 kind: .metNorway, forecastC: s.forecastC, observedC: ot))
                removed = true
                continue
            }
            keep.append(s)
        }
        if removed {
            metPending = keep
            writeAll(metPending, to: "met-pending.jsonl")
        }
        return pairs
    }

    private func pruneMetPendingIfNeeded(rewrite: Bool) {
        let t = now()
        let expiryCutoff = t.addingTimeInterval(-Self.metPendingExpiry)
        let before = metPending.count
        metPending = metPending.filter { $0.valid > expiryCutoff }
        metPending = migrateMetPending(metPending)
        metPending = applyMetPendingCaps(metPending, now: t)
        if rewrite || metPending.count != before {
            writeAll(metPending, to: "met-pending.jsonl")
        }
    }

    /// Drop off-hour legacy rows (no fetchedAt) and collapse the rest to one per (loc, hour, value).
    private func migrateMetPending(_ rows: [MetPendingSample]) -> [MetPendingSample] {
        let modern = rows.filter { $0.fetchedAt != nil }
        let legacy = rows.filter { $0.fetchedAt == nil && ForecastSampler.isOnTheHour($0.valid) }
        struct LK: Hashable { var loc: String; var hour: Int; var forecastC: Double }
        var best: [LK: MetPendingSample] = [:]
        for row in legacy {
            let k = LK(loc: row.loc, hour: ForecastSampler.hourBucket(row.valid), forecastC: row.forecastC)
            if let cur = best[k] {
                if row.issued > cur.issued { best[k] = row }
            } else {
                best[k] = row
            }
        }
        return modern + best.values
    }

    private func applyMetPendingCaps(_ rows: [MetPendingSample], now t: Date) -> [MetPendingSample] {
        let protectUntil = t.addingTimeInterval(Self.metPendingProtectHours * 3600)
        var byCity = Dictionary(grouping: rows, by: \.loc)
        for city in byCity.keys {
            byCity[city] = capMetPendingCity(byCity[city] ?? [], protectUntil: protectUntil)
        }
        var all = byCity.values.flatMap { $0 }
        if all.count > Self.metPendingCap {
            all = capMetPendingGlobal(all, protectUntil: protectUntil)
        }
        return all
    }

    /// Evict unprotected rows until the city is within the cap. Protected rows are never dropped (I2).
    private func capMetPendingCity(_ rows: [MetPendingSample], protectUntil: Date) -> [MetPendingSample] {
        let protectedCount = rows.reduce(0) { $0 + ($1.valid <= protectUntil ? 1 : 0) }
        let unprotectedCount = rows.count - protectedCount
        let room = max(Self.metPendingPerCityCap, protectedCount)
        let allowedUnprotected = room - protectedCount
        guard unprotectedCount > allowedUnprotected else { return rows }
        let dropCount = unprotectedCount - allowedUnprotected
        let unprotected = rows.enumerated().filter { $0.element.valid > protectUntil }
        let drop = Set(metPendingEvictionOrder(unprotected).prefix(dropCount))
        return rows.enumerated().compactMap { drop.contains($0.offset) ? nil : $0.element }
    }

    /// Same eviction order as a city, taking from the largest city first, never a protected row.
    private func capMetPendingGlobal(_ rows: [MetPendingSample], protectUntil: Date) -> [MetPendingSample] {
        var byCity = Dictionary(grouping: rows, by: \.loc)
        func total() -> Int { byCity.values.reduce(0) { $0 + $1.count } }
        var spins = rows.count + 1
        while total() > Self.metPendingCap && spins > 0 {
            spins -= 1
            let cities = byCity.keys.sorted { a, b in
                let ca = byCity[a]?.count ?? 0, cb = byCity[b]?.count ?? 0
                return ca == cb ? a < b : ca > cb
            }
            var evicted = false
            for city in cities {
                var cityRows = byCity[city] ?? []
                let unprotected = cityRows.enumerated().filter { $0.element.valid > protectUntil }
                guard let victim = metPendingEvictionOrder(unprotected).first else { continue }
                cityRows.remove(at: victim)
                byCity[city] = cityRows
                evicted = true
                break
            }
            if !evicted { break }
        }
        return byCity.values.flatMap { $0 }
    }

    /// Indices to evict first: superseded (oldest issued) copies, then farthest-future rows.
    private func metPendingEvictionOrder(_ rows: [(offset: Int, element: MetPendingSample)]) -> [Int] {
        let groups = Dictionary(grouping: rows) { ForecastSampler.hourBucket($0.element.valid) }
        var superseded: [(offset: Int, element: MetPendingSample)] = []
        var keepers: [(offset: Int, element: MetPendingSample)] = []
        for (_, group) in groups {
            let sorted = group.sorted { a, b in
                let ia = a.element.fetchedAt ?? a.element.issued
                let ib = b.element.fetchedAt ?? b.element.issued
                if ia != ib { return ia < ib }
                return a.offset < b.offset
            }
            if sorted.count > 1 {
                superseded.append(contentsOf: sorted.dropLast())
                if let last = sorted.last { keepers.append(last) }
            } else {
                keepers.append(contentsOf: sorted)
            }
        }
        superseded.sort { a, b in
            let ia = a.element.fetchedAt ?? a.element.issued
            let ib = b.element.fetchedAt ?? b.element.issued
            if ia != ib { return ia < ib }
            return a.offset < b.offset
        }
        keepers.sort { a, b in
            if a.element.valid != b.element.valid { return a.element.valid > b.element.valid }
            return a.offset < b.offset
        }
        return (superseded + keepers).map(\.offset)
    }

    /// US cities keep the NWS/ASOS path; non-US cities pick a METAR within 50 km that has reported recently.
    public func ensureStation(key: String, near point: Coordinate, isUS: Bool,
                              cityElevationM: Double? = nil) async -> MetarStationPick? {
        load()
        assertOffMain()
        if isUS { return nil }
        if let s = meta[key]?.station {
            let fresh = now().timeIntervalSince(s.pickedAt) < METARClient.stationCacheDays * Self.secondsPerDay
            let recheckDue = s.verified == false && s.verifiedRecheckAt.map { now() >= $0 } == true
            if fresh && !recheckDue { return s }
        }
        if meta[key]?.station == nil, let until = meta[key]?.noStationUntil, now() < until { return nil }
        let box = METARClient.searchBBox(around: point)
        let url = Endpoints.awcStationInfo(bbox: box.0, box.1, box.2, box.3)
        guard noteRequest(),
              let result = try? await client.fetch(url, headers: ["Accept": "application/json"]),
              (200..<300).contains(result.statusCode) || result.isNoContent else {
            noteStationNetworkFailure(key: key)
            return meta[key]?.station
        }
        let stations = result.isNoContent ? [] : METARClient.decodeStations(result.data)
        let dead = activeDeadStationIDs(key: key)
        let ranked = METARClient.rankCandidates(stations, near: point).filter { !dead.contains($0.id) }
        guard !ranked.isEmpty else {
            var m = meta[key] ?? Meta()
            m.station = nil
            m.noStationUntil = now().addingTimeInterval(METARClient.stationCacheDays * Self.secondsPerDay)
            m.cityElevationM = cityElevationM
            meta[key] = m
            saveMeta()
            return nil
        }
        let top = Array(ranked.prefix(Self.livenessCandidateCount))
        guard noteRequest(),
              let live = try? await client.fetch(Endpoints.awcMetar(ids: top.map(\.id), hours: 6),
                                                 headers: ["Accept": "application/json"]),
              (200..<300).contains(live.statusCode) || live.isNoContent else {
            noteStationNetworkFailure(key: key)
            return meta[key]?.station
        }
        let reported = Set(METARClient.decodeMetars(live.isNoContent ? Data() : live.data, loc: key, reference: now()).map(\.stationID))
        let chosen = top.first { reported.contains($0.id) } ?? ranked[0]
        let verified = reported.contains(chosen.id)
        let pick = stationPick(chosen, near: point, cityElevationM: cityElevationM,
                               verified: verified,
                               recheck: verified ? nil : now().addingTimeInterval(Self.unverifiedStationRecheck))
        var m = meta[key] ?? Meta()
        m.station = pick
        m.cityElevationM = cityElevationM
        m.noStationUntil = nil
        meta[key] = m
        if !global.knownStationIDs.contains(pick.stationID) {
            global.knownStationIDs.append(pick.stationID)
            saveGlobal()
        }
        saveMeta()
        return pick
    }

    /// Network failure keeps today's retry (6 h) and does not start the 7-day station cache.
    private func noteStationNetworkFailure(key: String) {
        if meta[key]?.station == nil {
            meta[key, default: Meta()].noStationUntil = now().addingTimeInterval(Self.unverifiedStationRecheck)
        } else if meta[key]?.station?.verified == false {
            meta[key]?.station?.verifiedRecheckAt = now().addingTimeInterval(Self.unverifiedStationRecheck)
        }
        saveMeta()
    }

    private func stationPick(_ station: METARClient.StationInfo, near point: Coordinate, cityElevationM: Double?,
                             verified: Bool, recheck: Date?) -> MetarStationPick {
        let dist = NexradStation.distanceKm(point, station.coordinate)
        let elevDelta = cityElevationM.flatMap { c in station.elevationM.map { $0 - c } }
        return MetarStationPick(stationID: station.id, name: station.name, coordinate: station.coordinate,
                                elevationM: station.elevationM, distanceKm: dist, elevationDeltaM: elevDelta,
                                pickedAt: now(), verified: verified, verifiedRecheckAt: recheck)
    }

    /// Dead IDs younger than the 7-day TTL. Expired entries are dropped.
    private func activeDeadStationIDs(key: String) -> Set<String> {
        let t = now()
        let ttl = METARClient.stationCacheDays * Self.secondsPerDay
        let dead = meta[key]?.deadStationIDs ?? [:]
        let live = dead.filter { t.timeIntervalSince($0.value) < ttl }
        if live.count != dead.count {
            meta[key]?.deadStationIDs = live.isEmpty ? nil : live
            saveMeta()
        }
        return Set(live.keys)
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
        if (try? JSONSerialization.jsonObject(with: result.data)) is [Any] {
            retireDeadStations(now: t)
        }
        return added.filter { $0.loc == key }
    }

    /// A station with no METAR rows 3 h after it was picked is dead. The next ensureStation skips it.
    private func retireDeadStations(now t: Date) {
        var retired: [String] = []
        var updates: [String: Meta] = [:]
        let ttl = METARClient.stationCacheDays * Self.secondsPerDay
        for (city, m) in meta {
            guard let station = m.station else { continue }
            guard t.timeIntervalSince(station.pickedAt) >= Self.metarDeadStationAfter else { continue }
            let hasRow = metars.contains { $0.loc == city && $0.stationID == station.stationID }
            if hasRow { continue }
            var dead = (m.deadStationIDs ?? [:]).filter { t.timeIntervalSince($0.value) < ttl }
            dead[station.stationID] = t
            var updated = m
            updated.deadStationIDs = dead
            updated.station = nil
            updates[city] = updated
            retired.append(station.stationID)
        }
        for (city, updated) in updates { meta[city] = updated }
        guard !retired.isEmpty else { return }
        let stillUsed = Set(meta.values.compactMap(\.station?.stationID))
        global.knownStationIDs.removeAll { retired.contains($0) && !stillUsed.contains($0) }
        saveMeta()
        saveGlobal()
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

    public func seedTraining(_ rows: [TrainingRow]) {
        load()
        recordTrainingRows(rows)
    }

    public func seedMetarVerified(_ rows: [VerifiedRecord]) {
        load()
        recordMetarVerified(rows)
    }

    public func seedCityElevation(_ m: Double?, key: String) {
        load()
        meta[key, default: Meta()].cityElevationM = m
        saveMeta()
    }

    // MARK: Accuracy PR 2 — training / METAR-verified / learn

    /// Append-only, idempotent on (loc, localDay, target). Prune at most once per day (B1 / B3 / c1).
    public func recordTrainingRows(_ rows: [TrainingRow]) {
        load()
        assertOffMain()
        var seen = Set(training.map(\.key))
        let fresh = rows.filter { seen.insert($0.key).inserted }
        guard !fresh.isEmpty else { return }
        training.append(contentsOf: fresh)
        append(fresh, to: "training.jsonl")
        pruneTrainingIfDue()
    }

    /// METAR-verified records for AdaptiveWeighting inputs. Key (loc, issued, valid). Never verified.jsonl.
    public func recordMetarVerified(_ rows: [VerifiedRecord]) {
        load()
        assertOffMain()
        struct K: Hashable { var loc: String; var issued: Date; var valid: Date }
        var seen = Set(metarVerified.map { K(loc: $0.r.loc, issued: $0.r.issued, valid: $0.r.valid) })
        let fresh = rows.filter {
            $0.r.leadHours >= BiasCorrection.minLeadHoursForLearning
                && seen.insert(K(loc: $0.r.loc, issued: $0.r.issued, valid: $0.r.valid)).inserted
        }
        guard !fresh.isEmpty else { return }
        metarVerified.append(contentsOf: fresh)
        append(fresh, to: "metar-verified.jsonl")
        pruneIfDue()
    }

    /// Build compact training rows from completed local days (uncorrected only). Idempotent.
    public func learnTraining(key: String, timeZoneIdentifier: String) {
        load()
        assertOffMain()
        guard let tz = TimeZone(identifier: timeZoneIdentifier) else { return }
        let t = now()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var newRows: [TrainingRow] = []

        // Hourly targets from skyline benchmark pairs (learningForecastC = uncorrected).
        let sky = hourlyBench.filter { $0.loc == key && $0.kind == .skyline
            && $0.valid.timeIntervalSince($0.issued) / 3600 >= BiasCorrection.minLeadHoursForLearning }
        let byDay = Dictionary(grouping: sky) { cal.startOfDay(for: $0.valid) }
        let today = cal.startOfDay(for: t)
        for (day, pairs) in byDay where day < today {
            let w = LocalDayAggregator.window(forDay: day, timeZone: tz)
            guard LocalDayAggregator.isComplete(w, now: t) else { continue }
            // Dedupe on the lock's key (loc, kind, issued, valid) — loc/kind are fixed above — so every
            // lead bucket keeps its own pairs for the same valid hour (review fix M4, B1/B2).
            struct PairKey: Hashable { var issued: Date; var valid: Date }
            var seenPairs = Set<PairKey>()
            let deduped = pairs.filter { seenPairs.insert(PairKey(issued: $0.issued, valid: $0.valid)).inserted }
            let byBucket = Dictionary(grouping: deduped) { CorrectionTarget(bucket: LeadBucket(leadHours: $0.valid.timeIntervalSince($0.issued) / 3600)) }
            for (target, rows) in byBucket {
                let sumE = rows.reduce(0.0) { $0 + ($1.learningForecastC - $1.observedC) }
                newRows.append(TrainingRow(loc: key, localDay: day, target: target,
                                           sumE: sumE, n: rows.count, distinct: Set(rows.map { Int($0.valid.timeIntervalSince1970 / 3600) }).count))
            }
        }

        // Daily high/low: D+1 issue raw hourly max/min vs observed hourly-slot max/min (B2).
        let temps = metars.filter { $0.loc == key }.compactMap { r -> (Date, Double)? in
            guard let c = r.temperatureC else { return nil }
            return (r.time, c)
        }
        for obs in dailyObs where obs.loc == key {
            guard let slots = BiasCorrection.hourlySlotExtremes(temps: temps, day: obs.localDay,
                                                                timeZone: tz, now: t) else { continue }
            let issue = dailyIssues.filter {
                $0.loc == key && abs($0.localDay.timeIntervalSince(obs.localDay)) < 1 && $0.issued < obs.localDay
            }.max(by: { $0.issued < $1.issued })
            guard let issue else { continue }
            if let rawHi = issue.rawHourlyMaxC {
                newRows.append(TrainingRow(loc: key, localDay: obs.localDay, target: .dailyHigh,
                                           sumE: rawHi - slots.high, n: 1))
            }
            if let rawLo = issue.rawHourlyMinC {
                newRows.append(TrainingRow(loc: key, localDay: obs.localDay, target: .dailyLow,
                                           sumE: rawLo - slots.low, n: 1))
            }
        }
        if !newRows.isEmpty { recordTrainingRows(newRows) }
    }

    /// Recompute applied offsets for a city (rate limit, auto-off). Returns offsets to apply (0 if gated off).
    /// `qaOverrideC` comes from the launch arguments only (ForecastVerifier), never from defaults or data.
    public func refreshCorrections(key: String, timeZoneIdentifier: String,
                                   sitingOK: Bool, qaOverrideC: Double? = nil) -> [CorrectionTarget: Double] {
        load()
        loadCorrectionsOnly()
        assertOffMain()
        let switchOn = BiasCorrection.Switch.isEnabled()
        let measurementOn = AccuracyMeasurement.isEnabled()
        guard let tz = TimeZone(identifier: timeZoneIdentifier) else { return [:] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let t = now()
        let localDay = cal.startOfDay(for: t)
        var file = correctionsFile
        var out: [CorrectionTarget: Double] = [:]

        if let qaRaw = qaOverrideC, qaRaw.isFinite {
            let qa = BiasCorrection.clamp(qaRaw)
            // QA override: force applied offset for gated targets; never write corrections.json.
            for target in CorrectionTarget.allCases {
                let rows = training.filter { $0.loc == key && $0.target == target && $0.localDay < localDay }
                let gated = BiasCorrection.gate(rows: rows, target: target, sitingOK: sitingOK,
                                                switchOn: switchOn, measurementOn: measurementOn)
                out[target] = gated ? qa : 0
            }
            return out
        }

        var changed = false
        for target in CorrectionTarget.allCases {
            let rows = training.filter { $0.loc == key && $0.target == target && $0.localDay < localDay }
            var entry = file.entry(loc: key, target: target)
                ?? CorrectionEntry(loc: key, target: target)
            let (eval, log) = BiasCorrection.evaluateAutoOff(entry: entry, rows: rows, asOf: t)
            entry = eval
            if let log {
                var l = log; l.loc = key; l.target = target
                file.appendLog(l)
                changed = true
            }
            let gated = BiasCorrection.gate(rows: rows, target: target, sitingOK: sitingOK,
                                            switchOn: switchOn, measurementOn: measurementOn)
            let forceZero = !switchOn || !measurementOn || !sitingOK || entry.autoOff || !gated
            let (est, n) = BiasCorrection.estimate(rows: rows, asOf: localDay)
            // Applied correction = −bias (warm forecasts get a negative offset).
            let targetC = forceZero ? 0 : -est
            let sameDay = entry.appliedOn.map { cal.isDate($0, inSameDayAs: localDay) } ?? false
            let applied = BiasCorrection.rateLimited(previous: entry.appliedC, targetC: targetC,
                                                     sameLocalDay: sameDay && !forceZero, forceZero: forceZero)
            if abs(applied - entry.appliedC) > 1e-12 || entry.targetC != targetC || entry.n != n
                || entry.autoOff != eval.autoOff {
                changed = true
            }
            entry.appliedC = applied
            entry.targetC = targetC
            entry.n = n
            if !sameDay || forceZero { entry.appliedOn = localDay }
            file.upsert(entry)
            out[target] = (gated && !forceZero) ? applied : 0
        }
        if changed { saveCorrections(file) }
        else { correctionsFile = file }
        return out
    }

    public func sitingOK(for key: String) -> Bool {
        sitingOK(for: key, cityElevationM: nil)
    }

    /// Persists city elevation when provided, then evaluates the c2 siting rule.
    public func sitingOK(for key: String, cityElevationM: Double?) -> Bool {
        load()
        if let cityElevationM {
            meta[key, default: Meta()].cityElevationM = cityElevationM
            saveMeta()
        }
        let m = meta[key]
        let station = m?.station
        let cityZ = m?.cityElevationM ?? cityElevationM
        return BiasCorrection.sitingPasses(distanceKm: station?.distanceKm,
                                           stationElevationM: station?.elevationM,
                                           cityElevationM: cityZ)
    }

    // MARK: Internals

    private func recomputeSummaries() {
        let keys = Set(meta.keys)
            .union(metars.map(\.loc))
            .union(hourlyBench.map(\.loc))
            .union(dailyObs.map(\.loc))
        for key in keys {
            let hourly = hourlyBench.filter { $0.loc == key }
            var summary = BenchmarkScorer.summary(
                hourly: hourly,
                dailyIssues: dailyIssues.filter { $0.loc == key },
                dailyObs: dailyObs.filter { $0.loc == key },
                station: meta[key]?.station
            )
            summary.pairedHourly = BenchmarkScorer.pairedHourly(hourly, loc: key)
            summaries[key] = summary
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
        metarVerified = capped(metarVerified.filter { $0.r.valid >= cutoff }, perCity: { $0.r.loc }, time: { $0.r.valid })
        // DST daily-date compat: drop pre-ship skewed issue days (and their daily training rows).
        applyDSTDailyDateCompatScrub(rewriteTraining: true)
        pruneMetPendingIfNeeded(rewrite: true)
        writeAll(metars, to: "metars.jsonl")
        writeAll(dailyIssues, to: "daily-issues.jsonl")
        writeAll(dailyObs, to: "daily-obs.jsonl")
        writeAll(hourlyBench, to: "hourly.jsonl")
        writeAll(metarVerified, to: "metar-verified.jsonl")
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
        metPending = readAll(MetPendingSample.self, from: "met-pending.jsonl")
        training = dedupeTraining(readAll(TrainingRow.self, from: "training.jsonl"))
        metarVerified = dedupeMetarVerified(readAll(VerifiedRecord.self, from: "metar-verified.jsonl"))
        if let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
           let m = try? Self.decoder.decode([String: Meta].self, from: data) { meta = m }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("global.json")),
           let g = try? Self.decoder.decode(GlobalMeta.self, from: data) { global = g }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("met-cache.json")),
           let c = try? Self.decoder.decode([String: MetNorwayCacheEntry].self, from: data) { metCache = c }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("summaries.json")),
           let s = try? Self.decoder.decode([String: BenchmarkSummary].self, from: data) { summaries = s }
        prune()
        pruneTrainingIfDue(force: true)
    }

    /// Apply ForecastSampler DST scrub to in-memory daily issues + daily training (load/prune hook).
    private func applyDSTDailyDateCompatScrub(rewriteTraining: Bool) {
        let scrubbed = ForecastSampler.scrubDSTSkewedDailyIssues(dailyIssues)
        dailyIssues = scrubbed.kept
        let filteredTraining = ForecastSampler.scrubDSTSkewedTraining(training, dropped: scrubbed.dropped)
        let trainingChanged = filteredTraining.count != training.count
        training = filteredTraining
        if rewriteTraining, trainingChanged {
            writeAll(training, to: "training.jsonl")
        }
    }

    private func dedupeTraining(_ rows: [TrainingRow]) -> [TrainingRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.key).inserted }
    }

    private func dedupeMetarVerified(_ rows: [VerifiedRecord]) -> [VerifiedRecord] {
        struct K: Hashable { var loc: String; var issued: Date; var valid: Date }
        var seen = Set<K>()
        return rows.filter { seen.insert(K(loc: $0.r.loc, issued: $0.r.issued, valid: $0.r.valid)).inserted }
    }

    /// Training prune at most once per day, one pass (B3 / c1).
    private func pruneTrainingIfDue(force: Bool = false) {
        if !force, let last = lastTrainingPruneAt, now().timeIntervalSince(last) < 86400,
           fileSize("training.jsonl") <= BiasCorrection.trainingMaxBytes { return }
        lastTrainingPruneAt = now()
        let cutoff = now().addingTimeInterval(-BiasCorrection.trainingRetentionDays * 86400)
        var kept: [TrainingRow] = []
        let groups = Dictionary(grouping: training.filter { $0.localDay >= cutoff }) {
            "\($0.loc)|\($0.target.rawValue)"
        }
        for (_, rows) in groups {
            let sorted = rows.sorted { $0.localDay < $1.localDay }
            kept.append(contentsOf: sorted.suffix(BiasCorrection.trainingCapPerCityTarget))
        }
        training = dedupeTraining(kept)
        writeAll(training, to: "training.jsonl")
        // Hard 2 MB ceiling inside the 10 MB total — drop oldest across all cities in one pass.
        let excess = fileSize("training.jsonl") - BiasCorrection.trainingMaxBytes
        if excess > 0, !training.isEmpty {
            training.sort { $0.localDay < $1.localDay }
            let size = max(1, fileSize("training.jsonl"))
            let drop = min(training.count, Int(Double(excess) / Double(size) * Double(training.count)) + 1)
            training.removeFirst(drop)
            writeAll(training, to: "training.jsonl")
        }
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
        bytesWrittenSeam += data.count
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

/// Fix 4: one MET Norway forecast hour awaiting an observation.
public struct MetPendingSample: Codable, Hashable, Sendable {
    public var loc: String
    public var issued: Date
    public var valid: Date
    public var forecastC: Double
    /// When the MET forecast was fetched. Nil on rows written before H1.
    public var fetchedAt: Date?

    public init(loc: String, issued: Date, valid: Date, forecastC: Double, fetchedAt: Date? = nil) {
        self.loc = loc; self.issued = issued; self.valid = valid; self.forecastC = forecastC
        self.fetchedAt = fetchedAt
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
    /// Uncorrected blend temperature used for learning (B5). Falls back to `forecastC` when nil (PR 1 rows).
    public var uncorrectedC: Double?

    public init(loc: String, issued: Date, valid: Date, kind: BenchmarkForecastKind,
                forecastC: Double, observedC: Double, uncorrectedC: Double? = nil) {
        self.loc = loc; self.issued = issued; self.valid = valid
        self.kind = kind; self.forecastC = forecastC; self.observedC = observedC
        self.uncorrectedC = uncorrectedC
    }

    /// Value learning must use — never the corrected display temperature.
    public var learningForecastC: Double { uncorrectedC ?? forecastC }
}
