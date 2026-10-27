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
    /// Fix 3: 24 h negative cache after a failed US NWS stations seed (named Form4 day literal).
    public static let usStationSeedNegativeCache: TimeInterval = BenchmarkStore.secondsPerDay

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
    /// Isolated, unsynced store for METAR / MET Norway / daily benchmark (Accuracy PR 1).
    private let benchmark: BenchmarkStore
    /// Review fix: last NWS observations fetched by verifyIfDue, reused (in memory only) for the US
    /// daily high/low benchmark so it needs no extra request.
    private var lastNWSObs: [String: [StationObservation]] = [:]
    /// Accuracy PR 2: corrections.json loaded eagerly in the background; never pulls large jsonl (B16).
    private var correctionsReady = false
    private var cachedOffsets: [String: [CorrectionTarget: Double]] = [:]
    private var cachedStatuses: [String: [CorrectionStatus]] = [:]
    /// In-memory METAR→weights inputs (never verified.jsonl). Populated by runMeasurement.
    private var metarWeightInputs: [String: [VerifiedRecord]] = [:]
    private var metarWeightEligible: Set<String> = []
    /// Whether `cachedWeights[key]` was computed with the METAR merge; a mismatch (e.g. switch OFF) recomputes (H2).
    private var cachedWeightsMerged: [String: Bool] = [:]
    /// `-SkylineCorrectionQAOverride` from the launch arguments only (never defaults or data), clamped (H1).
    private let qaOverrideC: Double?
    /// In-memory: US keys that already tried a launch seed this process (sync insert before first await).
    private var seedAttempted: Set<String> = []
    /// Keys that already performed a stations GET for seed this process (budget ≤1).
    private var seedFetched: Set<String> = []
    /// In-flight launch seeds so concurrent verify awaits one GET.
    private var seedInFlight: [String: Task<Void, Never>] = [:]
    /// Keys seen with a non-nil `stationsURL` (US) this process — drives "(pending)" without touching WeatherService.
    private var usKeys: Set<String> = []
    /// Last time-zone id used to build `cachedStatuses` (in-memory; rebuild after seed).
    private var statusTimeZoneIdentifier: [String: String] = [:]

    public init(directory: URL = ForecastVerifier.defaultDirectory(), client: HTTPClient = URLSessionHTTPClient(),
                config: AdaptiveWeighting.Config = AdaptiveWeighting.Config(),
                now: @escaping @Sendable () -> Date = { Date() },
                benchmarkDirectory: URL? = nil,
                launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.directory = directory
        self.qaOverrideC = BiasCorrection.QAOverride.celsius(arguments: launchArguments)
        self.client = client
        self.config = config
        self.now = now
        self.benchmark = BenchmarkStore(directory: benchmarkDirectory ?? BenchmarkStore.directoryAlongside(verification: directory),
                                        client: client, now: now)
        let store = self.benchmark
        Task.detached(priority: .utility) {
            await store.loadCorrectionsOnly()
        }
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
        guard let issued = records.map(\.issued).min() else { return }
        load()
        // QA SF1 (build 32): gate on the forecast's issue time, not on when this call runs. The issue time
        // is captured before the (detached, possibly delayed) recording task, so gating on `now()` let two
        // issuances land minutes apart, and the accuracy merge then collapsed them (pairs dropped).
        if let last = meta[key]?.lastIssued, issued.timeIntervalSince(last) < Self.issueInterval { return }
        let t = issued
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
    public func verifyIfDue(key: String, stationsURL: URL?, near forecastPoint: Coordinate? = nil,
                            cityElevationM: Double? = nil) async {
        load()
        if stationsURL != nil { usKeys.insert(key) }
        // Seed before the 55-min throttle / empty-due returns so fresh installs don't wait on verify.
        await seedBenchmarkStationIfMissing(key: key, stationsURL: stationsURL, near: forecastPoint,
                                            cityElevationM: cityElevationM)
        if let inflight = seedInFlight[key] { await inflight.value }

        let t = now()
        if let last = meta[key]?.lastObsCheck, t.timeIntervalSince(last) < Self.observationInterval { return }
        let due = pending.filter { $0.loc == key && $0.valid <= t.addingTimeInterval(-20 * 60) }
        guard !due.isEmpty else { return }
        meta[key, default: Meta()].lastObsCheck = t
        // Never start a fresh stations GET while a launch seed for this key is in flight.
        if let inflight = seedInFlight[key] { await inflight.value }
        guard let station = await station(for: key, stationsURL: stationsURL, near: forecastPoint,
                                          cityElevationM: cityElevationM) else { saveMeta(); return }
        let start = max(due.map(\.valid).min()!.addingTimeInterval(-70 * 60), t.addingTimeInterval(-3 * 86400))
        guard let url = Self.observationsURL(station: station, start: start),
              let data = try? await client.get(url, headers: ["Accept": "application/geo+json"]),
              let obs = try? NWSObservationParser.decode(data) else { saveMeta(); return }
        lastNWSObs[key] = obs
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
            unsyncedPairs += newPairs.count
            cachedScores[key] = nil
            cachedWeights[key] = nil
        }
    }

    /// The learned weights only if the history is already in memory; never reads the files. The first
    /// forecast after launch doesn't wait for up to 90 days of history to load (L9): it uses neutral
    /// weights and the history loads in the background for the next refresh.
    public func weightsIfLoaded(_ key: String) -> BlendWeights? {
        loaded ? weights(key) : nil
    }

    public var isLoaded: Bool { loaded }

    /// "Reset accuracy data" in Settings (L23): forgets every saved forecast and verified pair, on disk
    /// too. Learning starts over (neutral weights until 3 days are collected again).
    /// Accuracy PR 2 (B15): also clears benchmark/, corrections, training, metar-verified, and caches.
    public func reset() async {
        pending = []; verified = []; meta = [:]; cachedScores = [:]; cachedWeights = [:]
        cachedOffsets = [:]; cachedStatuses = [:]; correctionsReady = false
        metarWeightInputs = [:]; metarWeightEligible = []
        lastNWSObs = [:]
        loaded = true
        for name in ["pending.jsonl", "verified.jsonl", "meta.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        await benchmark.reset()
        // The reset travels to the other Macs through accuracy.json as the next generation (H3).
        accuracyReset = AccuracyReset(generation: (accuracyReset?.generation ?? 0) + 1, at: now())
        resetNeedsPush = true
        unsyncedPairs = 0
        saveResetAt()
    }

    // MARK: Sharing between Macs (builds 31-32)

    /// The winning "Reset Accuracy Data" (this Mac's or another's); pairs issued earlier are dropped.
    private var accuracyReset: AccuracyReset?
    /// Pairs verified here since they were last written to accuracy.json (H1: push only when > 0).
    private var unsyncedPairs = 0
    /// A reset made here that accuracy.json doesn't have yet.
    private var resetNeedsPush = false

    /// Whether this Mac has something accuracy.json lacks.
    public var hasUnsyncedAccuracy: Bool { unsyncedPairs > 0 || resetNeedsPush }

    /// This Mac's recent pairs and reset, ready to merge with accuracy.json (runs on this actor, off main).
    public func syncFile() -> AccuracyFile {
        load()
        return AccuracyFile(reset: accuracyReset, pairs: AccuracySync.merge(verified, [], resetAt: accuracyReset?.at, now: now()))
    }

    /// Pairs verified here that accuracy.json doesn't have yet.
    public var unsyncedPairCount: Int { unsyncedPairs }
    /// A reset made here that accuracy.json doesn't have yet.
    public var hasUnsyncedReset: Bool { resetNeedsPush }

    /// accuracy.json now holds what this Mac had when `syncFile()` was taken (`pairs` = the
    /// `unsyncedPairCount` read then, so pairs verified meanwhile still count as unsynced).
    public func markSynced(pairs: Int, reset: AccuracyReset?) {
        unsyncedPairs = max(0, unsyncedPairs - pairs)
        if reset == accuracyReset { resetNeedsPush = false }
    }

    /// Folds in pairs from the other Macs (de-duplicated, see `AccuracySync`) and a winning reset.
    /// Returns true when the local history changed.
    @discardableResult
    public func absorb(_ file: AccuracyFile) -> Bool {
        load()
        var changed = false
        let t = now()
        if let incoming = file.reset?.clamped(now: t), AccuracyReset.winner(accuracyReset, incoming) != accuracyReset {
            accuracyReset = incoming
            saveResetAt()
            pending.removeAll { $0.issued < incoming.at }
            writeAll(pending, to: "pending.jsonl")
            for key in meta.keys {
                if let f = meta[key]?.firstIssued, f < incoming.at { meta[key]?.firstIssued = nil }
            }
            changed = true
        }
        let cutoff = t.addingTimeInterval(-Self.retentionDays * 86400)
        let merged = AccuracySync.merge(verified, file.pairs.filter { $0.r.valid >= cutoff }, resetAt: accuracyReset?.at)
        if changed || Set(merged) != Set(verified.map(AccuracySync.normalized)) {
            verified = merged
            writeAll(verified, to: "verified.jsonl")
            cachedScores = [:]; cachedWeights = [:]
            changed = true
        }
        // "Days collected" counts from the earliest pair any Mac has for the location.
        for v in verified {
            let k = v.r.loc
            if meta[k]?.firstIssued.map({ v.r.issued < $0 }) ?? true { meta[k, default: Meta()].firstIssued = v.r.issued }
        }
        if changed { saveMeta() }
        return changed
    }

    private func saveResetAt() {
        guard let accuracyReset, let d = try? Self.encoder.encode(accuracyReset) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? d.write(to: directory.appendingPathComponent("sync-reset.json"), options: .atomic)
    }

    public func weights(_ key: String) -> BlendWeights {
        load()
        // Accuracy PR 2 (B17): non-US METAR pairs feed AdaptiveWeighting inputs when gated.
        // Formula / bounds / eligibility unchanged. US cities stay byte-identical (no merge).
        let extra = metarWeightInputs[key] ?? []
        let merge = BiasCorrection.Switch.isEnabled() && metarWeightEligible.contains(key) && !extra.isEmpty
        // A cache built with a different merge state (switch flipped, eligibility lost) is stale (H2).
        if let w = cachedWeights[key], (cachedWeightsMerged[key] ?? false) == merge { return w }
        // Learn from every member's full record (see `dedupingNOAAFamily(dropDuplicates:)`); display stays de-duplicated.
        var records = AccuracySync.collapsedForScoring(verified.filter { $0.r.loc == key })
        if merge {
            records = AccuracySync.collapsedForScoring(records + extra)
        }
        let learning = AccuracyScorer.score(records, now: now(), dedupe: false)
        let w = AdaptiveWeighting.weights(from: learning, config: config)
        cachedWeights[key] = w
        cachedWeightsMerged[key] = merge
        return w
    }

    /// Same as `weightsIfLoaded` for correction offsets (B16). Nil until this key's offsets are in memory.
    /// Nil whenever the kill switch or measurement is OFF, so the very next report is PR 1 (H2).
    public func correctionIfLoaded(_ key: String) -> [CorrectionTarget: Double]? {
        guard correctionsReady, BiasCorrection.Switch.isEnabled(), AccuracyMeasurement.isEnabled() else { return nil }
        return cachedOffsets[key]
    }

    /// Ensures corrections are loaded / refreshed for `key`. Safe to call off-main / detached.
    /// `isUS`: test/UI seam for "(pending)" when `stationsURL` has not yet marked the key (WeatherService unchanged).
    @discardableResult
    public func corrections(_ key: String, timeZoneIdentifier: String = TimeZone.gmt.identifier,
                            cityElevationM: Double? = nil, isUS: Bool? = nil) async -> [CorrectionTarget: Double] {
        await benchmark.loadCorrectionsOnly()
        correctionsReady = true
        if isUS == true { usKeys.insert(key) }
        statusTimeZoneIdentifier[key] = timeZoneIdentifier
        let siting = await benchmark.sitingOK(for: key, cityElevationM: cityElevationM)
        let offsets = await benchmark.refreshCorrections(key: key, timeZoneIdentifier: timeZoneIdentifier,
                                                         sitingOK: siting, qaOverrideC: qaOverrideC)
        cachedOffsets[key] = offsets
        cachedStatuses[key] = await buildStatuses(key: key, timeZoneIdentifier: timeZoneIdentifier,
                                                 sitingOK: siting, offsets: offsets, isUS: isUS)
        return offsets
    }

    public func correctionStatuses(_ key: String) -> [CorrectionStatus] {
        cachedStatuses[key] ?? []
    }

    private func buildStatuses(key: String, timeZoneIdentifier: String, sitingOK: Bool,
                              offsets: [CorrectionTarget: Double], isUS: Bool? = nil) async -> [CorrectionStatus] {
        let switchOn = BiasCorrection.Switch.isEnabled()
        let qa = qaOverrideC != nil
        var cal = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: timeZoneIdentifier) { cal.timeZone = tz }
        let localDay = cal.startOfDay(for: now())
        let stationNil = await benchmark.station(for: key) == nil
        let skip = await benchmark.shouldSkipUSStationSeed(key: key, now: now())
        let usContext: Bool = {
            if isUS == false { return false }
            if isUS == true { return true }
            return usKeys.contains(key) || meta[key]?.stationID != nil
        }()
        let stationPending = stationNil && usContext && !skip
        var out: [CorrectionStatus] = []
        for target in CorrectionTarget.allCases {
            let rows = await benchmark.trainingRows(for: key, target: target)
                .filter { $0.localDay < localDay }
            let nDays = Set(rows.map { Int($0.localDay.timeIntervalSince1970) }).count
            var entry = await benchmark.correctionEntry(loc: key, target: target)
            // The line shows what is actually applied (QA override is never written to corrections.json).
            if qa {
                entry = entry ?? CorrectionEntry(loc: key, target: target)
                entry?.appliedC = offsets[target] ?? 0
            }
            let nPairs = rows.reduce(0) { $0 + max(0, $1.n) }
            let gated = BiasCorrection.gate(rows: rows, target: target, sitingOK: sitingOK,
                                            switchOn: switchOn, measurementOn: AccuracyMeasurement.isEnabled())
            let line = BiasCorrection.statusLine(entry: entry, gated: gated, sitingOK: sitingOK,
                                                 switchOn: switchOn, nDays: nDays,
                                                 units: { $0 }, qaOverride: qa,
                                                 target: target, nPairs: nPairs,
                                                 stationPending: stationPending)
            out.append(CorrectionStatus(loc: key, target: target, line: line,
                                        appliedC: offsets[target] ?? 0, nDays: nDays, nPairs: nPairs,
                                        gated: gated, autoOff: entry?.autoOff ?? false, sitingOK: sitingOK))
        }
        return out
    }

    public func report(_ key: String) -> AccuracyReport {
        load()
        let s = scores(key)
        let t = now()
        let m = meta[key]
        let recentRecords = AccuracySync.collapsedForScoring(verified.filter { $0.r.loc == key }).filter { $0.r.valid >= t.addingTimeInterval(-7 * 86400) && $0.r.leadHours < 48 }
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

    // MARK: Accuracy PR 1 — measurement only (isolated store)

    /// Cached benchmark summary for the Accuracy screen (reads only; never fetches).
    public func benchmarkSummary(_ key: String) async -> BenchmarkSummary? {
        await benchmark.summary(for: key)
    }

    public func benchmarkStoreDirectory() async -> URL {
        // Exposed for tests / QA size checks.
        BenchmarkStore.directoryAlongside(verification: directory)
    }

    /// Runs METAR / MET Norway / daily measurement + PR 2 training / corrections refresh.
    public func runMeasurement(key: String, coordinate: Coordinate, timeZoneIdentifier: String,
                               daily: [DailyForecast], openMeteo om: OpenMeteoResponse,
                               blended: [HourlyForecast], isUS: Bool,
                               nwsObservations: [StationObservation] = [],
                               cityElevationM: Double? = nil) async {
        guard AccuracyMeasurement.isEnabled() else { return }
        let nwsObservations = nwsObservations.isEmpty ? (lastNWSObs[key] ?? []) : nwsObservations
        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let issued = now()
        let elev = cityElevationM ?? om.elevation
        if !isUS {
            _ = await benchmark.ensureStation(key: key, near: coordinate, isUS: false, cityElevationM: elev)
            _ = await benchmark.fetchMetarsIfDue(for: key)
        } else if let elev {
            await benchmark.seedCityElevation(elev, key: key)
        }
        let metHours = await benchmark.fetchMetNorwayIfDue(key: key, coordinate: coordinate)
        if isUS, !nwsObservations.isEmpty {
            await benchmark.recordNWSTemps(key: key, stationID: meta[key]?.stationID, obs: nwsObservations)
        }
        let issues = ForecastSampler.dailyIssues(location: key, issued: issued, daily: daily, openMeteo: om,
                                                 timeZone: tz, metNorway: metHours, blendedHourly: blended)
        await benchmark.recordDailyIssues(issues)

        var pairs: [BenchmarkHourlyPair] = []
        var metarPairs: [VerifiedRecord] = []
        var obs = isUS ? nwsObservations : await benchmark.metarObservations(for: key)
        if obs.isEmpty, !nwsObservations.isEmpty { obs = nwsObservations }
        if !obs.isEmpty {
            for r in pending where r.loc == key {
                guard let o = ObservationAggregator.observe(obs, validTime: r.valid), let ot = o.t else { continue }
                if let bt = r.values(.blend)?.t {
                    pairs.append(BenchmarkHourlyPair(loc: key, issued: r.issued, valid: r.valid, kind: .skyline,
                                                     forecastC: bt, observedC: ot, uncorrectedC: bt))
                }
                if let nt = r.values(.nws)?.t {
                    pairs.append(BenchmarkHourlyPair(loc: key, issued: r.issued, valid: r.valid, kind: .nws,
                                                     forecastC: nt, observedC: ot))
                }
                if let mt = r.values(.bestMatch)?.t {
                    pairs.append(BenchmarkHourlyPair(loc: key, issued: r.issued, valid: r.valid, kind: .bestMatch,
                                                     forecastC: mt, observedC: ot))
                }
                if !isUS, r.leadHours >= BiasCorrection.minLeadHoursForLearning {
                    metarPairs.append(VerifiedRecord(r, o))
                }
            }
            // Fix 4: score MET pending against observations (same 20-min rule); no immediate-future lookup.
            let scored = await benchmark.scoreMetPending(key: key, observations: obs, now: now())
            pairs.append(contentsOf: scored)
        }
        // Fix 4: record MET pending at this issuance for future valid hours (fresh MET only).
        let metFetchedAt = await benchmark.metNorwayFetchedAt(for: key)
        await benchmark.recordMetPending(key: key, issued: issued, hours: metHours, fetchedAt: metFetchedAt)
        if !pairs.isEmpty { await benchmark.recordHourlyPairs(pairs) }
        if !metarPairs.isEmpty { await benchmark.recordMetarVerified(metarPairs) }

        let extraTemps = nwsObservations.compactMap { o -> (Date, Double)? in
            guard let t = o.temperatureC else { return nil }
            return (o.time, t)
        }
        await benchmark.scoreCompletedDays(key: key, timeZoneIdentifier: timeZoneIdentifier, extraTemps: extraTemps)
        await benchmark.learnTraining(key: key, timeZoneIdentifier: timeZoneIdentifier)

        if !isUS, BiasCorrection.Switch.isEnabled() {
            let siting = await benchmark.sitingOK(for: key, cityElevationM: elev)
            let days = await benchmark.distinctMetarDays(for: key)
            if siting, days >= 7 {
                metarWeightEligible.insert(key)
                metarWeightInputs[key] = await benchmark.metarVerifiedRecords(for: key)
                cachedWeights[key] = nil
            } else {
                if metarWeightEligible.remove(key) != nil { cachedWeights[key] = nil }
                metarWeightInputs[key] = nil
            }
        } else {
            if metarWeightEligible.remove(key) != nil { cachedWeights[key] = nil }
            metarWeightInputs[key] = nil
        }
        _ = await corrections(key, timeZoneIdentifier: timeZoneIdentifier, cityElevationM: elev)
    }

    /// Test seam (B17/H2): METAR→weights inputs as `runMeasurement` would set them for an eligible city.
    func seedMetarWeightInputs(_ records: [VerifiedRecord], key: String) {
        metarWeightEligible.insert(key)
        metarWeightInputs[key] = records
        cachedWeights[key] = nil
    }

    /// Whether a QA override was passed at launch (Accuracy line "(QA override)").
    public var isQAOverrideActive: Bool { qaOverrideC != nil }

    /// Test seam: seed the isolated store without touching verified.jsonl / weights.
    public func seedBenchmark(station: MetarStationPick? = nil, key: String,
                              metars: [MetarObservationRecord] = [],
                              hourly: [BenchmarkHourlyPair] = [],
                              daily: [DailyObservedExtremes] = [],
                              training: [TrainingRow] = [],
                              cityElevationM: Double? = nil) async {
        if let station { await benchmark.seedStation(station, key: key) }
        if let cityElevationM { await benchmark.seedCityElevation(cityElevationM, key: key) }
        if !metars.isEmpty { await benchmark.seedMetars(metars) }
        if !hourly.isEmpty { await benchmark.seedHourly(hourly) }
        if !daily.isEmpty { await benchmark.seedDailyObs(daily) }
        if !training.isEmpty { await benchmark.seedTraining(training) }
        await benchmark.forceRecomputeSummaries()
    }

    /// Test seam: write verification-station meta (existing fields only) without a stations GET.
    public func seedVerificationStationMeta(key: String, stationID: String, stationName: String? = nil,
                                            fetched: Date, lastObsCheck: Date? = nil) {
        load()
        meta[key, default: Meta()].stationID = stationID
        meta[key]?.stationName = stationName
        meta[key]?.stationFetched = fetched
        if let lastObsCheck { meta[key]?.lastObsCheck = lastObsCheck }
        saveMeta()
    }

    public func pendingCount(for key: String) -> Int {
        load(); return pending.filter { $0.loc == key }.count
    }

    public func verifiedCount(for key: String) -> Int {
        load(); return verified.filter { $0.r.loc == key }.count
    }

    public func verificationStationID(for key: String) -> String? {
        load(); return meta[key]?.stationID
    }

    public func lastObsCheck(for key: String) -> Date? {
        load(); return meta[key]?.lastObsCheck
    }

    public func benchmarkMetarCount(_ key: String) async -> Int { await benchmark.metarCount(for: key) }
    public func benchmarkByteSize() async -> Int { await benchmark.totalByteSize() }
    public func benchmarkStation(for key: String) async -> MetarStationPick? { await benchmark.station(for: key) }
    public func shouldSkipUSStationSeed(key: String, now: Date) async -> Bool {
        await benchmark.shouldSkipUSStationSeed(key: key, now: now)
    }
    public func noteUSStationSeedFailure(key: String, until: Date) async {
        await benchmark.noteUSStationSeedFailure(key: key, until: until)
    }

    // MARK: Internals

    private func scores(_ key: String) -> AccuracyScorer.Scores {
        if let s = cachedScores[key] { return s }
        let s = AccuracyScorer.score(AccuracySync.collapsedForScoring(verified.filter { $0.r.loc == key }), now: now())
        cachedScores[key] = s
        return s
    }

    /// Launch/verify path: seed the US benchmark station when missing, before the obs throttle.
    private func seedBenchmarkStationIfMissing(key: String, stationsURL: URL?,
                                               near forecastPoint: Coordinate?,
                                               cityElevationM: Double?) async {
        // forecastPoint checked before any GET; non-US (nil stationsURL) never seeds here.
        guard let stationsURL, forecastPoint != nil else { return }
        if let inflight = seedInFlight[key] {
            await inflight.value
            return
        }
        if seedAttempted.contains(key) { return }
        // Sync insert before the first await (actor reentrancy).
        seedAttempted.insert(key)
        let point = forecastPoint
        let elev = cityElevationM
        let task = Task {
            await self.runUSStationSeed(key: key, stationsURL: stationsURL, near: point, cityElevationM: elev)
        }
        seedInFlight[key] = task
        await task.value
        seedInFlight[key] = nil
    }

    private func runUSStationSeed(key: String, stationsURL: URL, near forecastPoint: Coordinate?,
                                  cityElevationM: Double?) async {
        if await benchmark.station(for: key) != nil { return }
        if await benchmark.shouldSkipUSStationSeed(key: key, now: now()) { return }
        guard let forecastPoint else { return }

        let cachedID = meta[key]?.stationID
        let cachedFresh = cachedID != nil
            && meta[key]?.stationFetched.map { now().timeIntervalSince($0) < 7 * 86400 } == true
        if cachedFresh, let id = cachedID {
            await seedUSBenchmarkStationIfNeeded(key: key, verifyingID: id, stationsURL: stationsURL,
                                                 near: forecastPoint, cityElevationM: cityElevationM)
            if await benchmark.station(for: key) != nil {
                await invalidateStatusesAfterSeed(key: key, cityElevationM: cityElevationM)
            }
            return
        }

        // Fresh install / expired ID: one stations GET; write existing meta fields + benchmark seed.
        if seedFetched.contains(key) { return }
        seedFetched.insert(key)
        guard let data = try? await client.get(stationsURL, headers: ["Accept": "application/geo+json"]),
              let chosen = try? NWSObservationParser.verificationStation(data, near: forecastPoint) else {
            await benchmark.noteUSStationSeedFailure(key: key,
                                                     until: now().addingTimeInterval(Self.usStationSeedNegativeCache))
            return
        }
        meta[key, default: Meta()].stationID = chosen.id
        meta[key]?.stationName = chosen.name
        meta[key]?.stationFetched = now()
        if let pick = Self.nwsStationPick(data: data, id: chosen.id, near: forecastPoint,
                                          cityElevationM: cityElevationM, at: now()) {
            await benchmark.seedStation(pick, key: key)
            if let cityElevationM { await benchmark.seedCityElevation(cityElevationM, key: key) }
            await invalidateStatusesAfterSeed(key: key, cityElevationM: cityElevationM)
        } else {
            await benchmark.noteUSStationSeedFailure(key: key,
                                                     until: now().addingTimeInterval(Self.usStationSeedNegativeCache))
        }
        saveMeta()
    }

    private func invalidateStatusesAfterSeed(key: String, cityElevationM: Double?) async {
        // Rebuild in place so correctionStatuses() does not briefly hide rows.
        guard cachedStatuses[key] != nil || cachedOffsets[key] != nil else { return }
        let tz = statusTimeZoneIdentifier[key] ?? TimeZone.gmt.identifier
        let siting = await benchmark.sitingOK(for: key, cityElevationM: cityElevationM)
        let offsets = cachedOffsets[key] ?? [:]
        cachedStatuses[key] = await buildStatuses(key: key, timeZoneIdentifier: tz,
                                                 sitingOK: siting, offsets: offsets)
    }

    private func station(for key: String, stationsURL: URL?, near forecastPoint: Coordinate?,
                         cityElevationM: Double? = nil) async -> String? {
        if let inflight = seedInFlight[key] { await inflight.value }
        let cachedID = meta[key]?.stationID
        let cachedFresh = cachedID != nil
            && meta[key]?.stationFetched.map { now().timeIntervalSince($0) < 7 * 86400 } == true
        if cachedFresh, let id = cachedID {
            // Fix 3: even on a 7-day verification-station cache hit, seed/replace benchmark meta
            // when missing or pointing at a different station id.
            await seedUSBenchmarkStationIfNeeded(key: key, verifyingID: id, stationsURL: stationsURL,
                                                 near: forecastPoint, cityElevationM: cityElevationM)
            return id
        }
        // Launch seed already spent this key's stations GET budget — do not start another.
        if seedFetched.contains(key) { return meta[key]?.stationID }
        guard let stationsURL, let data = try? await client.get(stationsURL, headers: ["Accept": "application/geo+json"]),
              let chosen = try? NWSObservationParser.verificationStation(data, near: forecastPoint) else { return meta[key]?.stationID }
        meta[key, default: Meta()].stationID = chosen.id
        meta[key]?.stationName = chosen.name
        meta[key]?.stationFetched = now()
        if let point = forecastPoint, let pick = Self.nwsStationPick(data: data, id: chosen.id, near: point,
                                                                     cityElevationM: cityElevationM, at: now()) {
            await benchmark.seedStation(pick, key: key)
            if let cityElevationM { await benchmark.seedCityElevation(cityElevationM, key: key) }
        }
        return chosen.id
    }

    /// Fix 3: for US keys, when benchmark has no station or a mismatched id, fetch stations once
    /// (24 h negative cache on failure) and seed from the verifying NWS station.
    private func seedUSBenchmarkStationIfNeeded(key: String, verifyingID: String, stationsURL: URL?,
                                                near forecastPoint: Coordinate?,
                                                cityElevationM: Double?) async {
        let existing = await benchmark.station(for: key)
        if let existing, existing.stationID.uppercased() == verifyingID.uppercased() { return }
        guard let stationsURL else { return }
        // Point must be known before GET (launch seed already gates this; keep the order here too).
        guard let point = forecastPoint else { return }
        if await benchmark.shouldSkipUSStationSeed(key: key, now: now()) { return }
        if seedFetched.contains(key) { return }
        seedFetched.insert(key)
        guard let data = try? await client.get(stationsURL, headers: ["Accept": "application/geo+json"]),
              let pick = Self.nwsStationPick(data: data, id: verifyingID, near: point,
                                             cityElevationM: cityElevationM, at: now()) else {
            await benchmark.noteUSStationSeedFailure(key: key, until: now().addingTimeInterval(Self.usStationSeedNegativeCache))
            return
        }
        await benchmark.seedStation(pick, key: key)
        if let cityElevationM { await benchmark.seedCityElevation(cityElevationM, key: key) }
    }

    /// Decode distance / elevation for one NWS station id from the gridpoint stations GeoJSON.
    /// Private to ForecastVerifier (allowed file); avoids changing off-limits Observations.swift.
    /// Elevation: accept only `wmoUnit:m` (Fix 3 / CR 4); missing or unknown unit → elevation nil.
    static func nwsStationPick(data: Data, id: String, near point: Coordinate,
                               cityElevationM: Double?, at pickedAt: Date) -> MetarStationPick? {
        struct List: Decodable {
            struct Geom: Decodable { var coordinates: [Double]? }
            struct Elev: Decodable {
                var value: Double?
                var unitCode: String?
            }
            struct P: Decodable {
                var stationIdentifier: String?
                var name: String?
                var elevation: Elev?
            }
            struct F: Decodable { var properties: P; var geometry: Geom? }
            var features: [F]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        guard let f = list.features.first(where: { ($0.properties.stationIdentifier ?? "").uppercased() == id.uppercased() }),
              let coords = f.geometry?.coordinates, coords.count >= 2 else { return nil }
        let coord = Coordinate(latitude: coords[1], longitude: coords[0])
        let dist = NexradStation.distanceKm(point, coord)
        let elev: Double?
        if let e = f.properties.elevation, let v = e.value, e.unitCode == "wmoUnit:m" {
            elev = v
        } else {
            elev = nil
        }
        let delta = cityElevationM.flatMap { c in elev.map { $0 - c } }
        return MetarStationPick(stationID: id, name: f.properties.name, coordinate: coord,
                                elevationM: elev, distanceKm: dist, elevationDeltaM: delta, pickedAt: pickedAt)
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
        if let data = try? Data(contentsOf: directory.appendingPathComponent("sync-reset.json")) {
            if let r = try? Self.decoder.decode(AccuracyReset.self, from: data) {
                accuracyReset = r
            } else if let r = try? Self.decoder.decode([String: Date].self, from: data), let at = r["resetAt"] {
                accuracyReset = AccuracyReset(generation: 1, at: at) // build-31 file
            }
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
