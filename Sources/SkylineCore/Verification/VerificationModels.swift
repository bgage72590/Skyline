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

    public init(t: Double? = nil, pop: Double? = nil, p: Double? = nil, w: Double? = nil) {
        self.t = t; self.pop = pop; self.p = p; self.w = w
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

    public init(t: Double? = nil, w: Double? = nil, wet: Bool? = nil, p: Double? = nil) {
        self.t = t; self.w = w; self.wet = wet; self.p = p
    }
}

/// A forecast paired with its observation.
public struct VerifiedRecord: Codable, Hashable, Sendable {
    public var r: ForecastRecord
    public var o: ObservedHour

    public init(_ r: ForecastRecord, _ o: ObservedHour) { self.r = r; self.o = o }
}
