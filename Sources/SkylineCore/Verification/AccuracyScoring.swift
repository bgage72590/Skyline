import Foundation

/// Error statistics for one source (optionally within one lead bucket). Sums are age-weighted
/// (recent pairs count more), so the derived metrics are "recent" by construction.
public struct SourceScore: Codable, Hashable, Sendable {
    public var source: VerificationSource
    public var tempN = 0.0, tempAbs = 0.0, tempBias = 0.0
    public var windN = 0.0, windAbs = 0.0
    public var hits = 0.0, misses = 0.0, falseAlarms = 0.0, correctNegatives = 0.0
    public var brierN = 0.0, brierSum = 0.0
    /// Rain judged the same way for every source (amount ≥ 0.2 mm in the hour, which every model gives):
    /// the learned rain weight compares like with like. Age-weighted count of hours and of wrong calls.
    public var amountRainN = 0.0, amountRainWrong = 0.0
    /// Distinct UTC days with a verified pair, per kind. Hours from one afternoon are strongly correlated,
    /// so learning requires several *days* of evidence per bucket and source, not just many hours.
    public var tempDays: Set<Int> = [], windDays: Set<Int> = [], rainDays: Set<Int> = []
    /// Real (unweighted) hour counts, for wording like "41 of 48 rainy hours" and sample-size checks.
    public var tempHours = 0, wetHours = 0, wetHoursCaught = 0

    public init(source: VerificationSource) { self.source = source }

    public var tempMAE: Double? { tempN > 0 ? tempAbs / tempN : nil }
    /// Forecast minus observed (°C): positive = forecasts run warm.
    public var tempBiasMean: Double? { tempN > 0 ? tempBias / tempN : nil }
    public var windMAE: Double? { windN > 0 ? windAbs / windN : nil }
    public var rainN: Double { hits + misses + falseAlarms + correctNegatives }
    /// Probability of detection: share of wet hours that were forecast wet.
    public var hitRate: Double? { hits + misses > 0 ? hits / (hits + misses) : nil }
    /// Share of "rain" calls that stayed dry.
    public var falseAlarmRatio: Double? { hits + falseAlarms > 0 ? falseAlarms / (hits + falseAlarms) : nil }
    /// Share of all hours called correctly (wet or dry).
    public var rainAccuracy: Double? { rainN > 0 ? (hits + correctNegatives) / rainN : nil }
    public var brier: Double? { brierN > 0 ? brierSum / brierN : nil }

    mutating func add(_ f: SourceValues, _ o: ObservedHour, weight: Double, day: Int = 0) {
        if let ft = f.t, let ot = o.t {
            tempN += weight; tempAbs += weight * abs(ft - ot); tempBias += weight * (ft - ot)
            tempDays.insert(day)
            tempHours += 1
        }
        if let fw = f.w, let ow = o.w {
            windN += weight; windAbs += weight * abs(fw - ow)
            windDays.insert(day)
        }
        if let wet = o.wet, let amount = f.p {
            amountRainN += weight
            if (amount >= 0.2) != wet { amountRainWrong += weight }
            rainDays.insert(day)
        }
        if let wet = o.wet, let call = f.callsRain {
            if wet { wetHours += 1; if call { wetHoursCaught += 1 } }
            switch (call, wet) {
            case (true, true): hits += weight
            case (false, true): misses += weight
            case (true, false): falseAlarms += weight
            case (false, false): correctNegatives += weight
            }
            if let pop = f.pop {
                let pr = min(max(pop / 100, 0), 1)
                brierN += weight; brierSum += weight * (pr - (wet ? 1 : 0)) * (pr - (wet ? 1 : 0))
            }
        }
    }
}

public enum AccuracyScorer {
    /// Age half-life for weighting verified pairs. 0 = no decay.
    public static let defaultHalfLifeDays = 14.0

    public struct Scores: Sendable, Equatable {
        public var overall: [VerificationSource: SourceScore] = [:]
        public var byBucket: [LeadBucket: [VerificationSource: SourceScore]] = [:]
        /// Unweighted number of verified forecast hours.
        public var pairs = 0
        /// Span of verified valid times, in days.
        public var days = 0.0
        public var samplesByBucket: [LeadBucket: Int] = [:]
    }

    public static func score(_ records: [VerifiedRecord], now: Date, halfLifeDays: Double = defaultHalfLifeDays,
                             since: Date? = nil, dedupe: Bool = true) -> Scores {
        var s = Scores()
        let used = records.filter { since == nil || $0.r.valid >= since! }
        s.pairs = used.count
        if let lo = used.map(\.r.valid).min(), let hi = used.map(\.r.valid).max() {
            s.days = hi.timeIntervalSince(lo) / 86400
        }
        for raw in used {
            // Duplicate NOAA columns are one source (also for records saved before de-duplication).
            let rec = VerifiedRecord(raw.r.dedupingNOAAFamily(dropDuplicates: dedupe), raw.o)
            let ageDays = max(0, now.timeIntervalSince(rec.r.valid) / 86400)
            let weight = halfLifeDays > 0 ? pow(0.5, ageDays / halfLifeDays) : 1
            let bucket = rec.r.bucket
            let day = Int((rec.r.valid.timeIntervalSince1970 / 86400).rounded(.down))
            s.samplesByBucket[bucket, default: 0] += 1
            for (key, values) in rec.r.f {
                guard let source = VerificationSource(rawValue: key) else { continue }
                s.overall[source, default: SourceScore(source: source)].add(values, rec.o, weight: weight, day: day)
                s.byBucket[bucket, default: [:]][source, default: SourceScore(source: source)]
                    .add(values, rec.o, weight: weight, day: day)
            }
        }
        return s
    }
}

/// Per-location multipliers on the blender's base weights, learned from verification.
public struct BlendWeights: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case temperature, wind, rain }

    /// kind → bucket → source → multiplier (missing = 1).
    public var multipliers: [Kind: [LeadBucket: [VerificationSource: Double]]] = [:]

    public init(multipliers: [Kind: [LeadBucket: [VerificationSource: Double]]] = [:]) { self.multipliers = multipliers }

    public static let neutral = BlendWeights()
    public var isNeutral: Bool { multipliers.values.allSatisfy { $0.values.allSatisfy(\.isEmpty) } }

    public func multiplier(_ kind: Kind, _ source: VerificationSource, leadHours: Double) -> Double {
        multipliers[kind]?[LeadBucket(leadHours: leadHours)]?[source] ?? 1
    }

    /// Multiplier for a forecast variable name (Open-Meteo naming); 1 for variables that aren't verified.
    public func multiplier(variable: String, _ source: VerificationSource, leadHours: Double) -> Double {
        guard let kind = Self.kind(of: variable) else { return 1 }
        return multiplier(kind, source, leadHours: leadHours)
    }

    static func kind(of variable: String) -> Kind? {
        switch variable {
        case "temperature_2m", "apparent_temperature", "dew_point_2m", "temperature_2m_max", "temperature_2m_min": .temperature
        case "wind_speed_10m", "wind_gusts_10m", "wind_speed_10m_max", "wind_gusts_10m_max": .wind
        case "precipitation_probability", "precipitation", "precipitation_probability_max", "precipitation_sum": .rain
        default: nil
        }
    }
}

/// Inverse-error weighting with shrinkage, a floor and a cap.
///
/// v1 writes multipliers only for temperature. Wind and rain stay at 1, so precip / PoP stay on the
/// blender's base weights. For each lead bucket, eligible sources get
/// `m = (1/err) / mean(1/err)` (the eligible sources average 1), shrunk toward 1 by
/// `n / (n + shrink)` and clamped to [`floor`, `cap`]. Ineligible sources and buckets keep 1,
/// which is exactly the fixed hand-tuned weighting.
///
/// Eligibility is per bucket. `0-6h` keeps `minSamples` / `minDays` (20 and 3). When
/// `longLeadStricterGates` is set (USA / NWS coverage only), `6-24h`, `day2` and `day3+` require
/// `longLeadMinSamples` / `longLeadMinDays` (40 and 7). Global `minDays` stays 3 so the short-lead
/// bucket is not tightened. The overall early-exit is still `scores.days >= minDays`. A bucket
/// moves only when at least two sources clear its gate.
///
/// Locations outside NWS coverage leave `longLeadStricterGates` off, so they keep the tip
/// eligibility (n≥20, distinct UTC days≥3) and do not use the applied-multiplier rate limit.
public enum AdaptiveWeighting {
    /// Largest step of an applied temperature multiplier on a new city-local calendar day.
    public static let maxDailyMultiplierDelta = 0.25

    public struct Config: Sendable {
        public var minDays = 3.0
        public var minSamples = 20.0
        public var shrink = 40.0
        public var floor = 0.35
        /// Temperature multiplier ceiling. Raised 2.5 → 3.0 by the cap amend; wind and rain stay at 1.
        public var cap = 3.0
        /// Kinds allowed to leave 1. v1 is temperature only.
        public var kinds: [BlendWeights.Kind] = [.temperature]
        /// USA long-lead buckets use `longLeadMinSamples` / `longLeadMinDays` instead of the globals.
        public var longLeadStricterGates = false
        public var longLeadMinSamples = 40.0
        public var longLeadMinDays = 7.0
        public init() {}
    }

    public static func weights(from scores: AccuracyScorer.Scores, config: Config = Config()) -> BlendWeights {
        guard scores.days >= config.minDays else { return .neutral }
        // v1: temperature only, even if `kinds` also lists wind or rain.
        guard config.kinds.contains(.temperature) else { return .neutral }
        let kind = BlendWeights.Kind.temperature
        var out = BlendWeights()
        for (bucket, bySource) in scores.byBucket {
            let gate = eligibility(bucket, config)
            var errors: [VerificationSource: (err: Double, n: Double)] = [:]
            for source in VerificationSource.inputs {
                guard let sc = bySource[source], let e = error(kind, sc) else { continue }
                // The same age-weighted n the Accuracy screen's "ready" uses (see `isReady`), and
                // evidence from several distinct days in this bucket, not one correlated afternoon.
                if e.n >= gate.samples, Double(distinctDays(kind, sc)) >= gate.days { errors[source] = e }
            }
            guard errors.count >= 2 else { continue }
            let inverse = errors.mapValues { 1 / $0.err }
            let mean = inverse.values.reduce(0, +) / Double(inverse.count)
            var m: [VerificationSource: Double] = [:]
            for (source, inv) in inverse {
                let raw = inv / mean
                let n = errors[source]!.n
                let shrunk = 1 + (raw - 1) * n / (n + config.shrink)
                let clamped = min(max(shrunk, config.floor), config.cap)
                if clamped.isFinite { m[source] = clamped }
            }
            if !m.isEmpty { out.multipliers[kind, default: [:]][bucket] = m }
        }
        return out
    }

    /// Age-weighted sample count and distinct-UTC-day count a bucket must clear before m≠1.
    static func eligibility(_ bucket: LeadBucket, _ config: Config) -> (samples: Double, days: Double) {
        if config.longLeadStricterGates, bucket != .h0to6 {
            return (config.longLeadMinSamples, config.longLeadMinDays)
        }
        return (config.minSamples, config.minDays)
    }

    /// True when the learned weights are actually in use: some temperature bucket has at least two
    /// eligible sources. The Accuracy screen's "ready" uses this, so it agrees with non-neutral
    /// temperature multipliers (wind and rain are not required to move).
    public static func isReady(_ scores: AccuracyScorer.Scores, config: Config = Config()) -> Bool {
        !weights(from: scores, config: config).isNeutral
    }

    /// One applied temperature multiplier. Same city-local day keeps a finite previous value.
    /// A new local day moves at most `maxDailyMultiplierDelta` from that previous value (1 when
    /// there is none). Non-finite proposal or previous falls back to the other, or to 1.
    public static func rateLimited(previous: Double?, proposed: Double, sameLocalDay: Bool) -> Double {
        let prior: Double
        if let previous, previous.isFinite { prior = previous } else { prior = 1 }
        guard proposed.isFinite else { return prior }
        if sameLocalDay, let previous, previous.isFinite { return previous }
        let delta = proposed - prior
        if abs(delta) <= maxDailyMultiplierDelta { return proposed }
        return prior + (delta > 0 ? maxDailyMultiplierDelta : -maxDailyMultiplierDelta)
    }

    /// Applied temperature multipliers after the same-day freeze and the per-day step.
    /// Values that land on 1 are omitted (neutral). Wind and rain on `proposal` are ignored.
    public static func rateLimitedTemperatureWeights(
        proposal: BlendWeights,
        previous: [LeadBucket: [VerificationSource: Double]]?,
        sameLocalDay: Bool
    ) -> [LeadBucket: [VerificationSource: Double]] {
        if sameLocalDay {
            return finiteTemperature(previous ?? [:])
        }
        let prior = previous ?? [:]
        var buckets = Set(prior.keys)
        if let proposed = proposal.multipliers[.temperature] { buckets.formUnion(proposed.keys) }
        var out: [LeadBucket: [VerificationSource: Double]] = [:]
        for bucket in buckets {
            var row: [VerificationSource: Double] = [:]
            for source in VerificationSource.inputs {
                let proposed = proposal.multipliers[.temperature]?[bucket]?[source] ?? 1
                let m = rateLimited(previous: prior[bucket]?[source], proposed: proposed, sameLocalDay: false)
                if m.isFinite, abs(m - 1) > 1e-12 { row[source] = m }
            }
            if !row.isEmpty { out[bucket] = row }
        }
        return out
    }

    static func finiteTemperature(_ raw: [LeadBucket: [VerificationSource: Double]])
        -> [LeadBucket: [VerificationSource: Double]] {
        var out: [LeadBucket: [VerificationSource: Double]] = [:]
        for (bucket, row) in raw {
            var kept: [VerificationSource: Double] = [:]
            for (source, m) in row where m.isFinite && abs(m - 1) > 1e-12 { kept[source] = m }
            if !kept.isEmpty { out[bucket] = kept }
        }
        return out
    }

    static func blendWeights(temperature: [LeadBucket: [VerificationSource: Double]]) -> BlendWeights {
        var w = BlendWeights()
        if !temperature.isEmpty { w.multipliers[.temperature] = temperature }
        return w
    }

    static func distinctDays(_ kind: BlendWeights.Kind, _ s: SourceScore) -> Int {
        switch kind {
        case .temperature: s.tempDays.count
        case .wind: s.windDays.count
        case .rain: s.rainDays.count
        }
    }

    /// The error each kind is weighted on (lower is better), with a small floor so a lucky streak of
    /// perfect scores can't produce an infinite weight.
    static func error(_ kind: BlendWeights.Kind, _ s: SourceScore) -> (err: Double, n: Double)? {
        switch kind {
        case .temperature: return s.tempMAE.map { (max($0, 0.3), s.tempN) }
        case .wind: return s.windMAE.map { (max($0, 1.0), s.windN) }
        case .rain:
            // The same call for every source: forecast amount >= 0.2 mm vs. observed wet hour. (Mixing
            // "probability >= 50 %" for some sources with "amount" for others compared different things.)
            // Share of hours called wrong, with +1/+2 smoothing. Sources without amounts (NWS) keep 1x.
            guard s.amountRainN > 0 else { return nil }
            return (max((s.amountRainWrong + 1) / (s.amountRainN + 2), 0.02), s.amountRainN)
        }
    }
}

// MARK: Accuracy PR 1 — benchmark / daily scoring only (AdaptiveWeighting untouched)

/// Scores isolated benchmark and daily-high/low rows. Does not touch `AccuracyScorer.score` or weights.
public enum BenchmarkScorer {
    public static func hourlyMAE(_ pairs: [BenchmarkHourlyPair], kind: BenchmarkForecastKind) -> (mae: Double, n: Int)? {
        let rows = pairs.filter { $0.kind == kind }
        guard !rows.isEmpty else { return nil }
        let abs = rows.reduce(0.0) { $0 + Swift.abs($1.forecastC - $1.observedC) }
        return (abs / Double(rows.count), rows.count)
    }

    public static func dailyMAE(issues: [DailyForecastIssue], obs: [DailyObservedExtremes],
                                kind: BenchmarkForecastKind, high: Bool) -> (mae: Double, n: Int)? {
        let key = kind.rawValue
        var sum = 0.0, n = 0
        for o in obs {
            // Review fix: the latest issue made before the local day began (day-ahead), never a same-day nowcast.
            let issue = issues.filter { $0.loc == o.loc && abs($0.localDay.timeIntervalSince(o.localDay)) < 1 && $0.issued < o.localDay }
                .max(by: { $0.issued < $1.issued })
            guard let issue else { continue }
            let forecast = high ? issue.highs[key] : issue.lows[key]
            guard let forecast else { continue }
            let observed = high ? o.highC : o.lowC
            sum += Swift.abs(forecast - observed)
            n += 1
        }
        guard n > 0 else { return nil }
        return (sum / Double(n), n)
    }

    public static func summary(hourly: [BenchmarkHourlyPair], dailyIssues: [DailyForecastIssue],
                               dailyObs: [DailyObservedExtremes], station: MetarStationPick?) -> BenchmarkSummary {
        var rows: [BenchmarkSummary.Row] = []
        for kind in BenchmarkForecastKind.allCases {
            let h = hourlyMAE(hourly, kind: kind)
            let hi = dailyMAE(issues: dailyIssues, obs: dailyObs, kind: kind, high: true)
            let lo = dailyMAE(issues: dailyIssues, obs: dailyObs, kind: kind, high: false)
            let dailyN = max(hi?.n ?? 0, lo?.n ?? 0)
            rows.append(BenchmarkSummary.Row(kind: kind, tempMAE: h?.mae, highMAE: hi?.mae, lowMAE: lo?.mae,
                                             n: h?.n ?? 0, dailyN: dailyN))
        }
        return BenchmarkSummary(rows: rows, stationID: station?.stationID, stationName: station?.name,
                                stationDistanceKm: station?.distanceKm,
                                metNorwayAttribution: METNorwayClient.attribution)
    }

    /// Fix 4: MET Norway credit and row share one visibility rule.
    /// A summary that has not been recomputed (`pairedHourly == nil`) keeps the raw row/daily rule.
    /// Once `pairedHourly` is set, the hourly credit requires MET in that shared set (n ≥ 20), or a daily score.
    public static func showsMetNorwayRow(_ summary: BenchmarkSummary) -> Bool {
        if let paired = summary.pairedHourly {
            let metHourly = paired.kinds[.metNorway] != nil && paired.n >= 20
            let daily = summary.rows.contains { $0.kind == .metNorway && $0.dailyN >= 20 }
            return metHourly || daily
        }
        return summary.rows.contains { row in
            row.kind == .metNorway && row.isVisible
                && ((row.tempMAE != nil && row.n >= 20) || row.dailyN >= 20)
        }
    }

    /// One unweighted MAE per source on the hours every included source actually forecast.
    /// Kind order is Skyline, then MET Norway, NWS, Best Match. A later kind is skipped when
    /// intersecting it would leave fewer than `minN` hours.
    public static func pairedHourly(_ pairs: [BenchmarkHourlyPair], loc: String,
                                    minLeadH: Double = 1, minN: Int = 20) -> PairedHourly {
        let empty = PairedHourly(kinds: [:], n: 0, windowDays: BenchmarkStore.retentionDays)
        let minLead = minLeadH * 3600
        let filtered = pairs.filter { pair in
            pair.loc == loc
                && ForecastSampler.isOnTheHour(pair.valid)
                && pair.valid.timeIntervalSince(pair.issued) >= minLead
        }
        struct Dup: Hashable { var kind: BenchmarkForecastKind; var issued: Date; var valid: Date }
        var seen = Set<Dup>()
        let deduped = filtered.filter {
            seen.insert(Dup(kind: $0.kind, issued: $0.issued, valid: $0.valid)).inserted
        }
        struct HourKey: Hashable { var kind: BenchmarkForecastKind; var valid: Date }
        var latest: [HourKey: BenchmarkHourlyPair] = [:]
        for pair in deduped {
            let key = HourKey(kind: pair.kind, valid: pair.valid)
            if let cur = latest[key] {
                if pair.issued > cur.issued { latest[key] = pair }
            } else {
                latest[key] = pair
            }
        }
        var byKind: [BenchmarkForecastKind: [Date: BenchmarkHourlyPair]] = [:]
        for (key, pair) in latest {
            byKind[key.kind, default: [:]][key.valid] = pair
        }
        guard var shared = byKind[.skyline].map({ Set($0.keys) }), shared.count >= minN else { return empty }
        var included: [BenchmarkForecastKind] = [.skyline]
        for kind in [BenchmarkForecastKind.metNorway, .nws, .bestMatch] {
            guard let hours = byKind[kind], !hours.isEmpty else { continue }
            let intersection = shared.intersection(hours.keys)
            guard intersection.count >= minN else { continue }
            shared = intersection
            included.append(kind)
        }
        var maes: [BenchmarkForecastKind: Double] = [:]
        for kind in included {
            let rows = shared.compactMap { byKind[kind]?[$0] }
            guard rows.count == shared.count, !rows.isEmpty else { continue }
            let sum = rows.reduce(0.0) { $0 + abs($1.forecastC - $1.observedC) }
            maes[kind] = sum / Double(rows.count)
        }
        return PairedHourly(kinds: maes, n: shared.count, windowDays: BenchmarkStore.retentionDays)
    }

    // MARK: Accuracy PR 2 — training / gate helpers

    /// Deduped count of (loc, kind, issued, valid) hourly pairs (B1).
    public static func dedupedHourlyCount(_ pairs: [BenchmarkHourlyPair]) -> Int {
        struct K: Hashable { var loc: String; var kind: BenchmarkForecastKind; var issued: Date; var valid: Date }
        return Set(pairs.map { K(loc: $0.loc, kind: $0.kind, issued: $0.issued, valid: $0.valid) }).count
    }

    /// Distinct local days represented in training rows for a target.
    public static func distinctTrainingDays(_ rows: [TrainingRow]) -> Int {
        Set(rows.map { Int($0.localDay.timeIntervalSince1970) }).count
    }
}

/// City-aware station wording for the Accuracy panel. Text only.
public enum AccuracyStationCopy {
    /// US cities name the NWS station; everywhere else names the airport METAR.
    public static func stationPhrase(isUS: Bool) -> String {
        isUS ? "nearest NWS station" : "nearest airport weather station (METAR)"
    }

    /// Shown only for a non-US city that still has no benchmark METAR station.
    public static func collectingUnavailableLine(isUS: Bool, benchmarkStationID: String?) -> String? {
        guard !isUS, benchmarkStationID == nil else { return nil }
        return "No reporting weather station found near this city yet."
    }

    public static func stationLine(name: String?, stationID: String, distanceKm: Double?) -> String {
        let who = name ?? stationID
        if let km = distanceKm {
            return String(format: "Station: %@ (%@) · %.0f km", who, stationID, km)
        }
        return "Station: \(who) (\(stationID))"
    }
}
