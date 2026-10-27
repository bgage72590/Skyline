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
/// For each lead bucket, sources with at least `minSamples` (age-weighted) pairs on at least
/// `minDays` distinct days get
/// `m = (1/err) / mean(1/err)` (so the eligible sources average 1), shrunk toward 1 by
/// `n / (n + shrink)` and clamped to [`floor`, `cap`]. Ineligible sources, buckets and kinds keep 1,
/// which is exactly the fixed hand-tuned weighting, so nothing changes until there's enough data.
public enum AdaptiveWeighting {
    public struct Config: Sendable {
        public var minDays = 3.0
        public var minSamples = 20.0
        public var shrink = 40.0
        public var floor = 0.35
        public var cap = 2.5
        public init() {}
    }

    public static func weights(from scores: AccuracyScorer.Scores, config: Config = Config()) -> BlendWeights {
        guard scores.days >= config.minDays else { return .neutral }
        var out = BlendWeights()
        for kind in BlendWeights.Kind.allCases {
            for (bucket, bySource) in scores.byBucket {
                var errors: [VerificationSource: (err: Double, n: Double)] = [:]
                for source in VerificationSource.inputs {
                    guard let sc = bySource[source], let e = error(kind, sc) else { continue }
                    // The same age-weighted n the Accuracy screen's "ready" uses (see `isReady`), and
                    // evidence from several distinct days in this bucket, not one correlated afternoon.
                    if e.n >= config.minSamples, Double(distinctDays(kind, sc)) >= config.minDays { errors[source] = e }
                }
                guard errors.count >= 2 else { continue }
                let inverse = errors.mapValues { 1 / $0.err }
                let mean = inverse.values.reduce(0, +) / Double(inverse.count)
                var m: [VerificationSource: Double] = [:]
                for (source, inv) in inverse {
                    let raw = inv / mean
                    let n = errors[source]!.n
                    let shrunk = 1 + (raw - 1) * n / (n + config.shrink)
                    m[source] = min(max(shrunk, config.floor), config.cap)
                }
                out.multipliers[kind, default: [:]][bucket] = m
            }
        }
        return out
    }

    /// True when the learned weights are actually in use: some bucket and kind has at least two
    /// eligible sources. The Accuracy screen's "ready" uses this, so it can't disagree with the blend.
    public static func isReady(_ scores: AccuracyScorer.Scores, config: Config = Config()) -> Bool {
        !weights(from: scores, config: config).isNeutral
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
    public static func showsMetNorwayRow(_ summary: BenchmarkSummary) -> Bool {
        summary.rows.contains { row in
            row.kind == .metNorway && row.isVisible
                && ((row.tempMAE != nil && row.n >= 20) || row.dailyN >= 20)
        }
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
