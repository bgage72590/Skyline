import Foundation
#if canImport(os)
import os
#endif

/// Accuracy PR 2 — pure per-city additive temperature bias correction.
/// Gate, estimate, clamp, rate limit, siting, out-of-sample auto-off, and `apply`.
/// Learning always uses uncorrected blend values; display applies the persisted offset.
public enum BiasCorrection {
    public static let clampC = 2.0
    public static let rampPerDayC = 0.5
    public static let shrink = 40.0
    public static let halfLifeDays = 14.0
    public static let edgeRampHours = 3.0
    public static let maxEdgeStepC = 0.35
    public static let autoOffHysteresisC = 0.05
    public static let autoOffWindowDays = 14
    public static let autoOffReenableDays = 7
    public static let maxStationDistanceKm = 25.0
    public static let maxElevationDeltaM = 100.0
    public static let unknownCityMaxDistanceKm = 15.0
    public static let trainingRetentionDays = 180.0
    public static let trainingCapPerCityTarget = 200
    public static let trainingMaxBytes = 2 * 1024 * 1024
    public static let correctionsMaxBytes = 64 * 1024
    public static let minLeadHoursForLearning = 1.0
    /// Gate thresholds (shared by `gate` and `statusLine`). Values unchanged.
    public static let hourlyGateDays = 7
    public static let hourlyGatePairs = 300
    public static let dailyGateDays = 14
    public static let dailyGatePairs = 20

    #if canImport(os)
    private static let log = Logger(subsystem: "com.briangage.Skyline", category: "accuracy")
    #endif

    public static func accuracyLog(_ message: String) {
        #if canImport(os)
        log.info("\(message, privacy: .public)")
        #endif
    }

    // MARK: Kill switch / QA override

    /// Default ON. Hidden defaults / `-SkylineAccuracyCorrection NO`.
    public enum Switch {
        public static let defaultsKey = "SkylineAccuracyCorrection"
        public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
            DefaultsFlag.value(defaults, defaultsKey, default: true)
        }
    }

    /// Launch-arg only, never persisted: `-SkylineCorrectionQAOverride 1.0`.
    /// Reads the process arguments only, never UserDefaults (a `defaults write` must not enable it).
    /// Finite values only, clamped to ±2 °C (review fix H1).
    public enum QAOverride {
        public static let argument = "-SkylineCorrectionQAOverride"
        /// Never read; kept so tests can prove a persisted value is ignored.
        public static let defaultsKey = "SkylineCorrectionQAOverride"
        public static func celsius(arguments: [String] = ProcessInfo.processInfo.arguments) -> Double? {
            guard let i = arguments.lastIndex(of: argument), arguments.indices.contains(i + 1),
                  let v = Double(arguments[i + 1].trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
            return clamp(v)
        }
    }

    // MARK: Siting (c2)

    /// Exclude when distance > 25 km or |Δz| > 100 m. Unknown station elevation → exclude.
    /// Unknown city elevation → distance-only rule ≤ 15 km.
    public static func sitingPasses(distanceKm: Double?, stationElevationM: Double?,
                                    cityElevationM: Double?) -> Bool {
        guard let d = distanceKm, d.isFinite, d >= 0 else { return false }
        if let cityZ = cityElevationM {
            guard let stZ = stationElevationM, stZ.isFinite, cityZ.isFinite else { return false }
            return d <= maxStationDistanceKm && abs(stZ - cityZ) <= maxElevationDeltaM
        }
        return d <= unknownCityMaxDistanceKm
    }

    // MARK: Gate (B6)

    public static func gate(rows: [TrainingRow], target: CorrectionTarget,
                            sitingOK: Bool, switchOn: Bool, measurementOn: Bool) -> Bool {
        guard switchOn, measurementOn, sitingOK else { return false }
        let days = Set(rows.map { Int($0.localDay.timeIntervalSince1970) }).count
        let pairs = rows.reduce(0) { $0 + max(0, $1.n) }
        switch target {
        case .dailyHigh, .dailyLow:
            return days >= dailyGateDays && pairs >= dailyGatePairs
        case .h0to6, .h6to24, .day2, .day3plus:
            return pairs >= hourlyGatePairs && days >= hourlyGateDays
        }
    }

    public static func dayThreshold(for target: CorrectionTarget) -> Int {
        switch target {
        case .dailyHigh, .dailyLow: return dailyGateDays
        case .h0to6, .h6to24, .day2, .day3plus: return hourlyGateDays
        }
    }

    public static func pairThreshold(for target: CorrectionTarget) -> Int {
        switch target {
        case .dailyHigh, .dailyLow: return dailyGatePairs
        case .h0to6, .h6to24, .day2, .day3plus: return hourlyGatePairs
        }
    }

    // MARK: Estimate (B7)

    /// Age-weighted mean error e (forecast − observed, half-life 14 d) × n/(n+40), clamped to ±2 °C.
    /// `rows` must already be filtered to localDay < asOf (no leakage).
    public static func estimate(rows: [TrainingRow], asOf: Date,
                                halfLifeDays: Double = halfLifeDays) -> (targetC: Double, n: Int) {
        let n = Set(rows.map { Int($0.localDay.timeIntervalSince1970) }).count
        guard n > 0 else { return (0, 0) }
        var wSum = 0.0, weSum = 0.0
        for r in rows {
            let meanE = r.n > 0 ? r.sumE / Double(r.n) : r.sumE
            let ageDays = max(0, asOf.timeIntervalSince(r.localDay) / 86400)
            let w = halfLifeDays > 0 ? pow(0.5, ageDays / halfLifeDays) : 1
            wSum += w
            weSum += w * meanE
        }
        guard wSum > 0 else { return (0, n) }
        let mean = weSum / wSum
        let shrunk = mean * Double(n) / (Double(n) + shrink)
        return (clamp(shrunk), n)
    }

    /// ±2 °C; non-finite input → 0 (review fix M5).
    public static func clamp(_ c: Double) -> Double {
        guard c.isFinite else { return 0 }
        return min(max(c, -clampC), clampC)
    }

    /// Applied offset moves toward `targetC` by at most 0.5 °C per city-local day.
    /// Kill switch / auto-off → 0 immediately. Re-enabling ramps back up.
    public static func rateLimited(previous: Double, targetC: Double, sameLocalDay: Bool,
                                   forceZero: Bool) -> Double {
        if forceZero { return 0 }
        // Inputs and output clamped: a stale/corrupt persisted `previous` can't bypass ±2 °C (M5).
        let p = clamp(previous)
        let t = clamp(targetC)
        if sameLocalDay { return p }
        let delta = t - p
        if abs(delta) <= rampPerDayC { return t }
        return clamp(p + (delta > 0 ? rampPerDayC : -rampPerDayC))
    }

    // MARK: Hourly offset with edge ramp (B8)

    /// Lead < first bucket uses the first bucket's offset. ±3 h linear ramp at 6 / 24 / 48 h edges.
    public static func hourlyOffset(leadHours h: Double, offsets: [CorrectionTarget: Double]) -> Double {
        let h = max(0, h)
        let o0 = offsets[.h0to6] ?? 0
        let o1 = offsets[.h6to24] ?? 0
        let o2 = offsets[.day2] ?? 0
        let o3 = offsets[.day3plus] ?? 0
        let r = edgeRampHours
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
            a + (b - a) * min(1, max(0, t))
        }
        if h <= 6 - r { return o0 }
        if h < 6 + r { return lerp(o0, o1, (h - (6 - r)) / (2 * r)) }
        if h <= 24 - r { return o1 }
        if h < 24 + r { return lerp(o1, o2, (h - (24 - r)) / (2 * r)) }
        if h <= 48 - r { return o2 }
        if h < 48 + r { return lerp(o2, o3, (h - (48 - r)) / (2 * r)) }
        return o3
    }

    // MARK: Apply (B8 / B9)

    /// Applies additive °C offsets to temperature (and knock-ons). Mutates in place.
    /// `issued` is the report's "now" for lead-hour math. Daily offsets use local calendar days.
    public static func apply(hourly: inout [HourlyForecast], daily: inout [DailyForecast],
                             current: inout CurrentConditions, issued: Date, timeZone: TimeZone,
                             offsets rawOffsets: [CorrectionTarget: Double]) {
        // Non-finite → 0 and every offset clamped to ±2 °C before use (M5).
        let offsets = rawOffsets.mapValues { clamp($0) }
        guard offsets.values.contains(where: { abs($0) > 1e-12 }) else { return }
        let rawHourly = hourly
        for i in hourly.indices {
            let lead = hourly[i].time.timeIntervalSince(issued) / 3600
            let dT = hourlyOffset(leadHours: lead, offsets: offsets)
            guard abs(dT) > 1e-12 else { continue }
            hourly[i].temperature += dT
            if let a = hourly[i].apparentTemperature { hourly[i].apparentTemperature = a + dT }
            if let dp = hourly[i].dewPoint { hourly[i].dewPoint = min(dp, hourly[i].temperature) }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        for i in daily.indices {
            let hi = offsets[.dailyHigh] ?? 0
            let lo = offsets[.dailyLow] ?? 0
            let rawHigh = daily[i].high, rawLow = daily[i].low
            daily[i].high += hi
            daily[i].low += lo
            // Keep high ≥ corrected hourly max / low ≤ corrected hourly min only where PR 1 already satisfied
            // that (lock B8), and never let low exceed high where PR 1 had low ≤ high.
            func inDay(_ h: HourlyForecast) -> Bool { h.time >= daily[i].date && cal.isDate(h.time, inSameDayAs: daily[i].date) }
            let rawDay = rawHourly.filter(inDay).map(\.temperature)
            let dayHours = hourly.filter(inDay).map(\.temperature)
            if let rmx = rawDay.max(), rawHigh >= rmx, let mx = dayHours.max(), daily[i].high < mx { daily[i].high = mx }
            if let rmn = rawDay.min(), rawLow <= rmn, let mn = dayHours.min(), daily[i].low > mn { daily[i].low = mn }
            if rawLow <= rawHigh, daily[i].low > daily[i].high { daily[i].low = daily[i].high }
        }
        // Current conditions get the lead-0 offset (same as the first hours), so the headline moves by exactly
        // the offset even when the headline line can't interpolate; feels-like keeps its offset (B8).
        let dNow = hourlyOffset(leadHours: current.time.timeIntervalSince(issued) / 3600, offsets: offsets)
        if abs(dNow) > 1e-12 {
            current.temperature += dNow
            current.apparentTemperature += dNow
        }
        if let dp = current.dewPoint { current.dewPoint = min(dp, current.temperature) }
    }

    // MARK: Like-for-like daily observed slots (B2)

    /// One temperature per local hour: nearest sample to that hour's :00 within ±20 min.
    /// Never uses 5-minute spikes that aren't near the hour mark.
    public static func hourlySlotTemps(temps: [(Date, Double)], day: Date,
                                       timeZone: TimeZone) -> [Double] {
        let w = LocalDayAggregator.window(forDay: day, timeZone: timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var out: [Double] = []
        var cursor = w.start
        while cursor < w.end {
            let slot = temps.filter { abs($0.0.timeIntervalSince(cursor)) <= ObservationAggregator.instantTolerance }
                .min { abs($0.0.timeIntervalSince(cursor)) < abs($1.0.timeIntervalSince(cursor)) }
            if let t = slot?.1, t.isFinite { out.append(t) }
            guard let next = cal.date(byAdding: .hour, value: 1, to: cursor) else { break }
            if next <= cursor { break }
            cursor = next
        }
        return out
    }

    public static func hourlySlotExtremes(temps: [(Date, Double)], day: Date, timeZone: TimeZone,
                                          now: Date) -> (high: Double, low: Double, slots: Int)? {
        let w = LocalDayAggregator.window(forDay: day, timeZone: timeZone)
        guard LocalDayAggregator.isComplete(w, now: now) else { return nil }
        let slots = hourlySlotTemps(temps: temps, day: day, timeZone: timeZone)
        guard slots.count >= LocalDayAggregator.minDistinctHours,
              let hi = slots.max(), let lo = slots.min() else { return nil }
        return (hi, lo, slots.count)
    }

    // MARK: Auto-off replay (B5 / B12)

    /// Out-of-sample: for each of the last `window` scored days, train on earlier days only,
    /// compare corrected vs uncorrected MAE. Returns (correctedMAE, uncorrectedMAE).
    public static func outOfSampleMAEs(rows: [TrainingRow], window: Int = autoOffWindowDays) -> (corrected: Double, uncorrected: Double)? {
        let sorted = rows.sorted { $0.localDay < $1.localDay }
        guard sorted.count >= 2 else { return nil }
        let recent = Array(sorted.suffix(window))
        guard recent.count >= 3 else { return nil }
        var cSum = 0.0, uSum = 0.0, n = 0
        for day in recent {
            let prior = sorted.filter { $0.localDay < day.localDay }
            guard !prior.isEmpty else { continue }
            let (rawTarget, _) = estimate(rows: prior, asOf: day.localDay)
            // Applied correction would be −bias (warm forecasts → negative offset).
            let offset = -rawTarget
            let e = day.n > 0 ? day.sumE / Double(day.n) : day.sumE
            // Uncorrected error magnitude ≈ |e|; corrected ≈ |e + offset| when e = F−O and offset≈−bias.
            uSum += abs(e)
            cSum += abs(e + offset)
            n += 1
        }
        guard n > 0 else { return nil }
        return (cSum / Double(n), uSum / Double(n))
    }

    /// Sticky auto-off with hysteresis. Returns updated entry + optional log line.
    public static func evaluateAutoOff(entry: CorrectionEntry, rows: [TrainingRow],
                                       asOf: Date) -> (CorrectionEntry, CorrectionLogEntry?) {
        var e = entry
        guard let maes = outOfSampleMAEs(rows: rows) else { return (e, nil) }
        if e.autoOff {
            // Re-enable after ≥ 7 new scored days AND corrected better by ≥ 0.05 °C.
            let newDays = rows.filter { $0.localDay > (e.autoOffAt ?? .distantPast) }.count
            if newDays >= autoOffReenableDays, maes.uncorrected - maes.corrected >= autoOffHysteresisC {
                e.autoOff = false
                e.autoOffReason = nil
                let log = CorrectionLogEntry(state: "on", reason: "hysteresis re-enable",
                                             n: rows.count, correctedMAE: maes.corrected,
                                             uncorrectedMAE: maes.uncorrected, date: asOf)
                accuracyLog("correction auto-on \(e.loc)/\(e.target.rawValue) n=\(rows.count)")
                return (e, log)
            }
            return (e, nil)
        }
        if maes.corrected > maes.uncorrected {
            e.autoOff = true
            e.autoOffReason = "worse on recent days"
            e.autoOffAt = asOf
            let log = CorrectionLogEntry(state: "off", reason: e.autoOffReason ?? "",
                                         n: rows.count, correctedMAE: maes.corrected,
                                         uncorrectedMAE: maes.uncorrected, date: asOf)
            accuracyLog("correction auto-off \(e.loc)/\(e.target.rawValue) cMAE=\(maes.corrected) uMAE=\(maes.uncorrected)")
            return (e, log)
        }
        return (e, nil)
    }

    // MARK: UI copy

    /// Siting failure with no US station pick yet (seed in flight or not yet attempted).
    public static let offStationPending = "off: station (pending)"
    /// Siting failure after back-off or for a non-US / failed key.
    public static let offStation = "off: station"
    /// Copy only. Mirrors evaluateAutoOff's re-enable rule (≥ autoOffReenableDays new scored days AND ≥ hysteresis better).
    public static let autoOffLine = "paused: worse recently · rechecks after \(autoOffReenableDays)+ new days"

    public static func statusLine(entry: CorrectionEntry?, gated: Bool, sitingOK: Bool,
                                  switchOn: Bool, nDays: Int, units: (Double) -> Double,
                                  qaOverride: Bool = false,
                                  target: CorrectionTarget = .dailyHigh,
                                  nPairs: Int = 0,
                                  stationPending: Bool = false) -> String {
        if !switchOn { return "off: switched off" }
        if !sitingOK { return stationPending ? offStationPending : offStation }
        if let e = entry, e.autoOff { return autoOffLine }
        if !gated {
            let needDays = dayThreshold(for: target)
            let needPairs = pairThreshold(for: target)
            return "off (\(nDays)/\(needDays) days · \(nPairs)/\(needPairs) pairs)"
        }
        let applied = entry?.appliedC ?? 0
        let shown = units(applied)
        let qa = qaOverride ? " (QA override)" : ""
        return String(format: "correction in use: %+.1f° (n %d days)%@", shown, nDays, qa)
    }
}

// MARK: - Types

/// Six correction targets: four hourly lead buckets + daily high/low.
public enum CorrectionTarget: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case h0to6 = "0-6h"
    case h6to24 = "6-24h"
    case day2 = "day2"
    case day3plus = "day3+"
    case dailyHigh = "dailyHigh"
    case dailyLow = "dailyLow"

    public init(bucket: LeadBucket) {
        switch bucket {
        case .h0to6: self = .h0to6
        case .h6to24: self = .h6to24
        case .day2: self = .day2
        case .day3plus: self = .day3plus
        }
    }

    public var isDaily: Bool { self == .dailyHigh || self == .dailyLow }
    public var isHourly: Bool { !isDaily }

    public var displayName: String {
        switch self {
        case .h0to6: "0–6 h"
        case .h6to24: "6–24 h"
        case .day2: "Day 2"
        case .day3plus: "Day 3+"
        case .dailyHigh: "Daily high"
        case .dailyLow: "Daily low"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Compact training row: one per city × local day × target (c1).
public struct TrainingRow: Codable, Hashable, Sendable {
    public var loc: String
    public var localDay: Date
    public var target: CorrectionTarget
    /// Sum of (forecast − observed) over deduped pairs that day (hourly) or the single daily error.
    public var sumE: Double
    /// Deduped pair count (hourly) or 1 (daily).
    public var n: Int
    /// Distinct hourly slots contributing (hourly targets); nil for daily.
    public var distinct: Int?

    public init(loc: String, localDay: Date, target: CorrectionTarget, sumE: Double, n: Int,
                distinct: Int? = nil) {
        self.loc = loc; self.localDay = localDay; self.target = target
        self.sumE = sumE; self.n = n; self.distinct = distinct
    }

    public var key: String {
        "\(loc)|\(Int(localDay.timeIntervalSince1970))|\(target.rawValue)"
    }
}

public struct CorrectionEntry: Codable, Hashable, Sendable {
    public var loc: String
    public var target: CorrectionTarget
    /// Currently applied offset (°C), rate-limited.
    public var appliedC: Double
    /// Clamped estimate target (°C) for the current local day.
    public var targetC: Double
    /// City-local date when `appliedC` was last stepped.
    public var appliedOn: Date?
    public var autoOff: Bool
    public var autoOffReason: String?
    public var autoOffAt: Date?
    public var n: Int

    public init(loc: String, target: CorrectionTarget, appliedC: Double = 0, targetC: Double = 0,
                appliedOn: Date? = nil, autoOff: Bool = false, autoOffReason: String? = nil,
                autoOffAt: Date? = nil, n: Int = 0) {
        self.loc = loc; self.target = target; self.appliedC = appliedC; self.targetC = targetC
        self.appliedOn = appliedOn; self.autoOff = autoOff; self.autoOffReason = autoOffReason
        self.autoOffAt = autoOffAt; self.n = n
    }

    public var key: String { "\(loc)|\(target.rawValue)" }
}

public struct CorrectionLogEntry: Codable, Hashable, Sendable {
    public var state: String
    public var reason: String
    public var n: Int
    public var correctedMAE: Double?
    public var uncorrectedMAE: Double?
    public var date: Date
    public var loc: String?
    public var target: CorrectionTarget?

    public init(state: String, reason: String, n: Int, correctedMAE: Double? = nil,
                uncorrectedMAE: Double? = nil, date: Date, loc: String? = nil,
                target: CorrectionTarget? = nil) {
        self.state = state; self.reason = reason; self.n = n
        self.correctedMAE = correctedMAE; self.uncorrectedMAE = uncorrectedMAE
        self.date = date; self.loc = loc; self.target = target
    }
}

public struct CorrectionsFile: Codable, Hashable, Sendable {
    public var entries: [CorrectionEntry]
    public var log: [CorrectionLogEntry]

    public init(entries: [CorrectionEntry] = [], log: [CorrectionLogEntry] = []) {
        self.entries = entries; self.log = log
    }

    public mutating func upsert(_ entry: CorrectionEntry) {
        if let i = entries.firstIndex(where: { $0.key == entry.key }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func appendLog(_ e: CorrectionLogEntry) {
        log.append(e)
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    public func entry(loc: String, target: CorrectionTarget) -> CorrectionEntry? {
        entries.first { $0.loc == loc && $0.target == target }
    }
}

/// UI / test surface for one city × target correction line.
public struct CorrectionStatus: Codable, Hashable, Sendable {
    public var loc: String
    public var target: CorrectionTarget
    public var line: String
    public var appliedC: Double
    public var nDays: Int
    public var nPairs: Int
    public var gated: Bool
    public var autoOff: Bool
    public var sitingOK: Bool

    public init(loc: String, target: CorrectionTarget, line: String, appliedC: Double = 0,
                nDays: Int = 0, nPairs: Int = 0, gated: Bool = false, autoOff: Bool = false, sitingOK: Bool = true) {
        self.loc = loc; self.target = target; self.line = line; self.appliedC = appliedC
        self.nDays = nDays; self.nPairs = nPairs; self.gated = gated; self.autoOff = autoOff; self.sitingOK = sitingOK
    }
}
