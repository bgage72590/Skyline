import Foundation

/// Error statistics for one source (optionally within one lead bucket). Sums are age-weighted
/// (recent pairs count more), so the derived metrics are "recent" by construction.
public struct SourceScore: Codable, Hashable, Sendable {
    public var source: VerificationSource
    public var tempN = 0.0, tempAbs = 0.0, tempBias = 0.0
    public var windN = 0.0, windAbs = 0.0
    public var hits = 0.0, misses = 0.0, falseAlarms = 0.0, correctNegatives = 0.0
    public var brierN = 0.0, brierSum = 0.0

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

    mutating func add(_ f: SourceValues, _ o: ObservedHour, weight: Double) {
        if let ft = f.t, let ot = o.t {
            tempN += weight; tempAbs += weight * abs(ft - ot); tempBias += weight * (ft - ot)
        }
        if let fw = f.w, let ow = o.w {
            windN += weight; windAbs += weight * abs(fw - ow)
        }
        if let wet = o.wet, let call = f.callsRain {
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
                             since: Date? = nil) -> Scores {
        var s = Scores()
        let used = records.filter { since == nil || $0.r.valid >= since! }
        s.pairs = used.count
        if let lo = used.map(\.r.valid).min(), let hi = used.map(\.r.valid).max() {
            s.days = hi.timeIntervalSince(lo) / 86400
        }
        for rec in used {
            let ageDays = max(0, now.timeIntervalSince(rec.r.valid) / 86400)
            let weight = halfLifeDays > 0 ? pow(0.5, ageDays / halfLifeDays) : 1
            let bucket = rec.r.bucket
            s.samplesByBucket[bucket, default: 0] += 1
            for (key, values) in rec.r.f {
                guard let source = VerificationSource(rawValue: key) else { continue }
                s.overall[source, default: SourceScore(source: source)].add(values, rec.o, weight: weight)
                s.byBucket[bucket, default: [:]][source, default: SourceScore(source: source)].add(values, rec.o, weight: weight)
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
/// For each lead bucket, sources with at least `minSamples` (age-weighted) pairs get
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
                    if e.n >= config.minSamples { errors[source] = e }
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

    /// The error each kind is weighted on (lower is better), with a small floor so a lucky streak of
    /// perfect scores can't produce an infinite weight.
    static func error(_ kind: BlendWeights.Kind, _ s: SourceScore) -> (err: Double, n: Double)? {
        switch kind {
        case .temperature: return s.tempMAE.map { (max($0, 0.3), s.tempN) }
        case .wind: return s.windMAE.map { (max($0, 1.0), s.windN) }
        case .rain:
            // One metric for every source (not all of them issue probabilities): the share of hours
            // called wrong (misses + false alarms), with +1/+2 smoothing.
            guard s.rainN > 0 else { return nil }
            return (max((s.misses + s.falseAlarms + 1) / (s.rainN + 2), 0.02), s.rainN)
        }
    }
}
