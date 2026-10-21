import Foundation

/// Everything Skyline verifies: its own blend plus each contributing source.
public enum VerificationSource: String, Codable, CaseIterable, Sendable, Comparable {
    case blend
    case nws
    case bestMatch = "best_match"
    case hrrr = "gfs_hrrr"
    case ecmwf = "ecmwf_ifs025"
    case gfs = "gfs_seamless"
    case icon = "icon_seamless"

    public init(_ model: ForecastModel) {
        switch model {
        case .bestMatch: self = .bestMatch
        case .hrrr: self = .hrrr
        case .ecmwf: self = .ecmwf
        case .gfs: self = .gfs
        case .icon: self = .icon
        }
    }

    public init(_ source: ForecastBlender.Source) {
        switch source {
        case .nws: self = .nws
        case .model(let m): self.init(m)
        }
    }

    public var displayName: String {
        switch self {
        case .blend: "Skyline blend"
        case .nws: "NWS"
        case .bestMatch: "Best Match"
        case .hrrr: "HRRR"
        case .ecmwf: "ECMWF"
        case .gfs: "GFS"
        case .icon: "ICON"
        }
    }

    /// Inputs to the blend (everything except the blend itself).
    public static var inputs: [VerificationSource] { allCases.filter { $0 != .blend } }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Forecast lead-time buckets used for scoring and for adaptive weights.
public enum LeadBucket: String, Codable, CaseIterable, Sendable, Comparable {
    case h0to6 = "0-6h", h6to24 = "6-24h", day2 = "day2", day3plus = "day3+"

    public init(leadHours h: Double) {
        if h < 6 { self = .h0to6 } else if h < 24 { self = .h6to24 } else if h < 48 { self = .day2 } else { self = .day3plus }
    }

    public var label: String {
        switch self {
        case .h0to6: "Next 6 h"
        case .h6to24: "6–24 h"
        case .day2: "Day 2"
        case .day3plus: "Day 3+"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// One source's forecast for one valid hour. Units: °C, %, mm (hour ending at valid time), km/h.
public struct SourceValues: Codable, Hashable, Sendable {
    public var t: Double?
    public var pop: Double?
    public var p: Double?
    public var w: Double?

    /// Non-finite values (NaN/Inf from a bad upstream number) are dropped (M3): they would make every
    /// JSON encode of the record throw.
    public init(t: Double? = nil, pop: Double? = nil, p: Double? = nil, w: Double? = nil) {
        func ok(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }
        self.t = ok(t); self.pop = ok(pop); self.p = ok(p); self.w = ok(w)
    }

    public var isEmpty: Bool { t == nil && pop == nil && p == nil && w == nil }

    /// Categorical rain call: probability ≥ 50 % when the source gives one, else ≥ 0.2 mm in the hour.
    public var callsRain: Bool? {
        if let pop { return pop >= 50 }
        if let p { return p >= 0.2 }
        return nil
    }
}

/// A forecast Skyline issued: all sources' values for one location and valid hour.
public struct ForecastRecord: Codable, Hashable, Sendable {
    public var loc: String
    public var issued: Date
    public var valid: Date
    public var f: [String: SourceValues]

    public init(loc: String, issued: Date, valid: Date, f: [String: SourceValues]) {
        self.loc = loc; self.issued = issued; self.valid = valid; self.f = f
    }

    public var leadHours: Double { valid.timeIntervalSince(issued) / 3600 }
    public var bucket: LeadBucket { LeadBucket(leadHours: leadHours) }
    public func values(_ s: VerificationSource) -> SourceValues? { f[s.rawValue] }
}

/// What actually happened at a station for one valid hour.
public struct ObservedHour: Codable, Hashable, Sendable {
    /// Temperature (°C) at the valid time.
    public var t: Double?
    /// Wind speed (km/h) near the valid time.
    public var w: Double?
    /// Precipitation fell in the hour ending at the valid time.
    public var wet: Bool?
    /// Measured precipitation (mm) for that hour, when the station reports it.
    public var p: Double?

    /// Non-finite values are dropped (M3, see `SourceValues.init`).
    public init(t: Double? = nil, w: Double? = nil, wet: Bool? = nil, p: Double? = nil) {
        func ok(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }
        self.t = ok(t); self.w = ok(w); self.wet = wet; self.p = ok(p)
    }
}

/// A forecast paired with its observation.
public struct VerifiedRecord: Codable, Hashable, Sendable {
    public var r: ForecastRecord
    public var o: ObservedHour

    public init(_ r: ForecastRecord, _ o: ObservedHour) { self.r = r; self.o = o }
}

// MARK: Accuracy PR 1 — measurement-only types (never a VerificationSource case)

/// Kill switch for measurement (default ON). Hidden defaults / `-SkylineAccuracyMeasurement NO`.
public enum AccuracyMeasurement {
    public static let defaultsKey = "SkylineAccuracyMeasurement"
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Forecast sources compared on the Accuracy "Skyline vs other forecasts" section.
/// Not a `VerificationSource`: MET Norway must never enter AdaptiveWeighting / accuracy.json.
public enum BenchmarkForecastKind: String, Codable, CaseIterable, Sendable, Comparable {
    case skyline
    case nws
    case bestMatch = "best_match"
    case metNorway = "met_norway"

    public var displayName: String {
        switch self {
        case .skyline: "Skyline"
        case .nws: "NWS"
        case .bestMatch: "Best Match"
        case .metNorway: "MET Norway"
        }
    }

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Nearest METAR station pick for a city (isolated benchmark store).
public struct MetarStationPick: Codable, Hashable, Sendable {
    public var stationID: String
    public var name: String?
    public var coordinate: Coordinate
    public var elevationM: Double?
    public var distanceKm: Double
    public var elevationDeltaM: Double?
    public var pickedAt: Date

    public init(stationID: String, name: String? = nil, coordinate: Coordinate, elevationM: Double? = nil,
                distanceKm: Double, elevationDeltaM: Double? = nil, pickedAt: Date) {
        self.stationID = stationID; self.name = name; self.coordinate = coordinate
        self.elevationM = elevationM; self.distanceKm = distanceKm
        self.elevationDeltaM = elevationDeltaM; self.pickedAt = pickedAt
    }
}

/// One METAR observation row kept in the isolated benchmark store (not verified.jsonl).
public struct MetarObservationRecord: Codable, Hashable, Sendable {
    public var loc: String
    public var stationID: String
    public var time: Date
    public var temperatureC: Double?
    public var windKmh: Double?
    public var wet: Bool?
    public var raw: String?

    public init(loc: String, stationID: String, time: Date, temperatureC: Double?, windKmh: Double?,
                wet: Bool?, raw: String? = nil) {
        self.loc = loc; self.stationID = stationID; self.time = time
        self.temperatureC = temperatureC; self.windKmh = windKmh; self.wet = wet; self.raw = raw
    }
}

/// Forecast daily high/low issued for a city's local calendar day (benchmark store).
public struct DailyForecastIssue: Codable, Hashable, Sendable {
    public var loc: String
    public var issued: Date
    /// Local midnight of the forecast day (city IANA zone).
    public var localDay: Date
    public var timeZoneIdentifier: String
    public var highs: [String: Double]
    public var lows: [String: Double]

    public init(loc: String, issued: Date, localDay: Date, timeZoneIdentifier: String,
                highs: [String: Double], lows: [String: Double]) {
        self.loc = loc; self.issued = issued; self.localDay = localDay
        self.timeZoneIdentifier = timeZoneIdentifier; self.highs = highs; self.lows = lows
    }
}

/// Observed daily extremes after a local day has fully ended (≥ 20 distinct hourly slots).
public struct DailyObservedExtremes: Codable, Hashable, Sendable {
    public var loc: String
    public var localDay: Date
    public var timeZoneIdentifier: String
    public var highC: Double
    public var lowC: Double
    public var distinctHours: Int
    public var stationID: String?
    public var source: String

    public init(loc: String, localDay: Date, timeZoneIdentifier: String, highC: Double, lowC: Double,
                distinctHours: Int, stationID: String? = nil, source: String) {
        self.loc = loc; self.localDay = localDay; self.timeZoneIdentifier = timeZoneIdentifier
        self.highC = highC; self.lowC = lowC; self.distinctHours = distinctHours
        self.stationID = stationID; self.source = source
    }
}

/// Cached MET Norway compact forecast (honours Expires / If-Modified-Since).
public struct MetNorwayCacheEntry: Codable, Hashable, Sendable {
    public var loc: String
    public var fetchedAt: Date
    public var lastModified: String?
    public var expires: Date?
    public var body: Data
    public var hourly: [MetNorwayHour]

    public init(loc: String, fetchedAt: Date, lastModified: String?, expires: Date?, body: Data,
                hourly: [MetNorwayHour]) {
        self.loc = loc; self.fetchedAt = fetchedAt; self.lastModified = lastModified
        self.expires = expires; self.body = body; self.hourly = hourly
    }
}

public struct MetNorwayHour: Codable, Hashable, Sendable {
    public var time: Date
    public var temperatureC: Double?
    public var windKmh: Double?
    public var precipMM: Double?
    public var highC: Double?
    public var lowC: Double?

    public init(time: Date, temperatureC: Double? = nil, windKmh: Double? = nil, precipMM: Double? = nil,
                highC: Double? = nil, lowC: Double? = nil) {
        self.time = time; self.temperatureC = temperatureC; self.windKmh = windKmh
        self.precipMM = precipMM; self.highC = highC; self.lowC = lowC
    }
}

/// Summary row for the Accuracy "Skyline vs other forecasts" section (cached; view reads only this).
public struct BenchmarkSummary: Codable, Hashable, Sendable, Equatable {
    public struct Row: Codable, Hashable, Sendable, Equatable {
        public var kind: BenchmarkForecastKind
        public var tempMAE: Double?
        public var highMAE: Double?
        public var lowMAE: Double?
        public var n: Int
        public var dailyN: Int

        public init(kind: BenchmarkForecastKind, tempMAE: Double? = nil, highMAE: Double? = nil,
                    lowMAE: Double? = nil, n: Int = 0, dailyN: Int = 0) {
            self.kind = kind; self.tempMAE = tempMAE; self.highMAE = highMAE; self.lowMAE = lowMAE
            self.n = n; self.dailyN = dailyN
        }

        /// Rows with fewer than 20 samples stay hidden in the UI.
        public var isVisible: Bool { max(n, dailyN) >= 20 }
    }

    public var rows: [Row]
    public var stationID: String?
    public var stationName: String?
    public var stationDistanceKm: Double?
    public var metNorwayAttribution: String

    public init(rows: [Row], stationID: String? = nil, stationName: String? = nil,
                stationDistanceKm: Double? = nil,
                metNorwayAttribution: String = "Data: MET Norway, CC BY 4.0") {
        self.rows = rows; self.stationID = stationID; self.stationName = stationName
        self.stationDistanceKm = stationDistanceKm; self.metNorwayAttribution = metNorwayAttribution
    }
}

extension ForecastRecord {
    /// One model, one score: Open-Meteo's `best_match`, `gfs_seamless` and `gfs_hrrr` often carry the very
    /// same NOAA numbers, and scoring each copy as its own source would triple-count one model in the
    /// accuracy tracker and the learned weights. For each variable, a NOAA-family value equal to that of a
    /// higher-weighted family member is dropped (the blender collapses them the same way), and HRRR's
    /// "probability" (really the GFS-family one) is never scored as HRRR. Applied when recording and when
    /// scoring, so history saved before this rule is scored the same way.
    /// - Parameter dropDuplicates: false keeps every member's values (only HRRR's borrowed probability is
    ///   removed). Used when storing records and for learning weights: dropping a member whenever it equals
    ///   a higher-weighted one scores it only on the hours it disagrees, which biases its learned weight.
    public func dedupingNOAAFamily(dropDuplicates: Bool = true) -> ForecastRecord {
        let lead = leadHours
        let family: [ForecastModel] = [.hrrr, .bestMatch, .gfs]
        var out = self
        if var h = out.f[VerificationSource.hrrr.rawValue] {
            h.pop = nil
            out.f[VerificationSource.hrrr.rawValue] = h.isEmpty ? nil : h
        }
        guard dropDuplicates else { return out }
        func dedupe(_ path: WritableKeyPath<SourceValues, Double?>, variable: String) {
            let ranked = family.enumerated().sorted { a, b in
                let wa = ForecastBlender.weight(.model(a.element), variable: variable, leadHours: lead)
                let wb = ForecastBlender.weight(.model(b.element), variable: variable, leadHours: lead)
                return wa == wb ? a.offset < b.offset : wa > wb
            }.map(\.element)
            var seen: Set<Double> = []
            for m in ranked {
                let key = VerificationSource(m).rawValue
                guard var v = out.f[key], let value = v[keyPath: path] else { continue }
                if seen.contains(value) {
                    v[keyPath: path] = nil
                    out.f[key] = v.isEmpty ? nil : v
                } else {
                    seen.insert(value)
                }
            }
        }
        dedupe(\.t, variable: "temperature_2m")
        dedupe(\.pop, variable: "precipitation_probability")
        dedupe(\.p, variable: "precipitation")
        dedupe(\.w, variable: "wind_speed_10m")
        return out
    }
}
