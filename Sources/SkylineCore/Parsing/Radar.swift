import Foundation

/// A radar source the map can display.
public enum RadarProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Iowa Environmental Mesonet NEXRAD N0Q composite (US, ~1 km, 5-min frames).
    case nexrad
    /// RainViewer global composite (free tier: zoom ≤ 7, 10-min frames).
    case rainViewer

    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .nexrad: "NEXRAD (US)"; case .rainViewer: "RainViewer (Global)" }
    }
    /// Highest zoom the server provides; the app over-zooms (crops/upscales) beyond this.
    public var maximumNativeZoom: Int {
        switch self { case .nexrad: 10; case .rainViewer: 7 }
    }
    public var attribution: String {
        switch self {
        case .nexrad: "Radar: NOAA NEXRAD via Iowa Environmental Mesonet"
        case .rainViewer: "Radar: RainViewer"
        }
    }

    public static func preferred(for coordinate: Coordinate) -> RadarProvider {
        coordinate.isInCONUS ? .nexrad : .rainViewer
    }

    /// NEXRAD only for the lower 48 (border outlines + the saved city's country); RainViewer elsewhere,
    /// so Toronto or Monterrey get a full global composite instead of a US mosaic with holes (QA 4).
    public static func preferred(for location: WeatherLocation) -> RadarProvider {
        location.isInCONUS ? .nexrad : .rainViewer
    }

    /// The source to show: the user's saved pick in CONUS, RainViewer everywhere else (QA #6).
    public static func resolved(saved: RadarProvider, inCONUS: Bool) -> RadarProvider {
        inCONUS ? saved : .rainViewer
    }
}

/// One animation frame: a timestamp and an XYZ tile URL template with `{z}`, `{x}`, `{y}`.
public struct RadarFrame: Hashable, Sendable, Identifiable {
    public var time: Date
    public var urlTemplate: String
    /// A model forecast (HRRR future radar, RainViewer nowcast), not an observed scan. Labelled as such.
    public var isForecast: Bool
    public var id: String { urlTemplate }

    public init(time: Date, urlTemplate: String, isForecast: Bool = false) {
        self.time = time
        self.urlTemplate = urlTemplate
        self.isForecast = isForecast
    }

    public func url(z: Int, x: Int, y: Int) -> URL? {
        URL(string: urlTemplate
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y)))
    }
}

public enum RainViewerParser {
    struct Raw: Decodable {
        struct Frame: Decodable { var time: Double; var path: String }
        struct Radar: Decodable { var past: [Frame]; var nowcast: [Frame]? }
        var host: String
        var radar: Radar
    }

    /// Color scheme 2 ("Universal Blue") is the one the free tier guarantees; `1_1` = smoothed, snow shown.
    public static func decode(_ data: Data) throws -> [RadarFrame] {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        func frame(_ f: Raw.Frame, forecast: Bool) -> RadarFrame {
            RadarFrame(time: Date(timeIntervalSince1970: f.time),
                       urlTemplate: "\(raw.host)\(f.path)/256/{z}/{x}/{y}/2/1_1.png", isForecast: forecast)
        }
        return (raw.radar.past.map { frame($0, forecast: false) } + (raw.radar.nowcast ?? []).map { frame($0, forecast: true) })
            .sorted { $0.time < $1.time }
    }
}

/// How far back the radar loop goes (NEXRAD only; RainViewer's free tier is fixed at ~2 h).
public enum RadarRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case oneHour, twoHours, threeHours
    public var id: String { rawValue }
    public var label: String {
        switch self { case .oneHour: "1 hr"; case .twoHours: "2 hr"; case .threeHours: "3 hr" }
    }
    /// Minutes between frames (keeps every range at ≤ 13 frames, so prefetch memory is the same).
    public var stepMinutes: Int {
        switch self { case .oneHour: 5; case .twoHours: 10; case .threeHours: 15 }
    }
    public var totalMinutes: Int {
        switch self { case .oneHour: 50; case .twoHours: 120; case .threeHours: 180 }
    }
}

public enum IEMNexrad {
    struct Raw: Decodable {
        struct Meta: Decodable { var valid: String }
        var meta: Meta
    }

    /// Latest-scan valid time from `n0q_0.json`.
    public static func latestValidTime(_ data: Data) throws -> Date? {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let f = ISO8601DateFormatter()
        return f.date(from: raw.meta.valid)
    }

    /// The 1-hour loop: 11 frames at 5-minute steps ending at the latest scan.
    public static func frames(latest: Date) -> [RadarFrame] { frames(latest: latest, range: .oneHour) }

    /// Every loop uses IEM's archived composites, addressed by their UTC scan time
    /// (`ridge::USCOMP-N0Q-YYYYMMDDHHMM`). Those URLs never change content, so they cache well: when a new
    /// scan arrives only the newest frame is new. (The 1-hour loop used IEM's *relative* layers,
    /// `m05m` … `m50m` with `?v=<latest>`, so every scan changed all 11 URLs and the whole loop was
    /// downloaded and decoded again every 5 minutes. IEM publishes the archived name for the latest
    /// scan by the time `n0q_0.json` reports it; checked live Oct 11, 2026.)
    public static func frames(latest: Date, range: RadarRange) -> [RadarFrame] {
        let step = Double(range.stepMinutes * 60)
        let base = (latest.timeIntervalSince1970 / 300).rounded(.down) * 300
        let count = range.totalMinutes / range.stepMinutes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return (0...count).reversed().map { k in
            let t = Date(timeIntervalSince1970: base - Double(k) * step)
            return RadarFrame(time: t, urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::USCOMP-N0Q-\(formatter.string(from: t))/{z}/{x}/{y}.png")
        }
    }
}

/// Future radar (T12): HRRR precipitation-type (REFP) tiles from IEM, appended after "now" and always
/// labelled as a model forecast. REFP (not REFD) so rain / snow / mix paint as separate colours.
/// Uses the archived layer name (`hrrr::REFP-F<minute>-<run>`), so a frame's URL never changes for a
/// given run and caches like the NEXRAD frames.
public enum IEMHRRR {
    struct Raw: Decodable { var model_init_utc: String }

    /// Minutes after the latest scan's quarter hour: finer steps first, out to 2 hours. Six frames, so
    /// the whole loop stays inside the same tile budget.
    public static let offsetsMinutes = [15, 30, 45, 60, 90, 120]
    /// HRRR's sub-hourly products run out at 18 h.
    public static let maxForecastMinute = 18 * 60

    /// Product code in the tile URL (`REFP` = precip type; rain/snow/mix are distinct colours).
    public static let product = "REFP"

    /// Run time of the newest HRRR on IEM (from `refp_0000.json`).
    public static func initTime(_ data: Data) throws -> Date? {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return ISO8601DateFormatter().date(from: raw.model_init_utc)
    }

    /// Forecast frames after the latest observed scan, from the given HRRR run.
    public static func frames(initTime: Date, after latest: Date) -> [RadarFrame] {
        let quarter = (latest.timeIntervalSince1970 / 900).rounded(.down) * 900
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        let run = formatter.string(from: initTime)
        return offsetsMinutes.compactMap { offset in
            let t = Date(timeIntervalSince1970: quarter + Double(offset * 60))
            let minute = Int((t.timeIntervalSince(initTime) / 60).rounded())
            guard t > latest, minute > 0, minute <= maxForecastMinute, minute % 15 == 0 else { return nil }
            return RadarFrame(time: t, urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::\(product)-F\(String(format: "%04d", minute))-\(run)/{z}/{x}/{y}.png",
                              isForecast: true)
        }
    }

    /// Legend stops for REFP precip-type colours (IEM / pyIEM `radar_ptype`): rain, snow, freezing rain, ice pellets.
    public static let legendTypes: [(name: String, hex: UInt32)] = [
        ("Rain", 0x40AA5D),
        ("Snow", 0x3399BB),
        ("Frz rain", 0xF7593F),
        ("Ice", 0x6E58A7),
    ]
}

/// What the radar map shows: the reflectivity loop, or a rainfall-total overlay (L21, US only).
public enum RadarLayer: String, CaseIterable, Codable, Sendable, Identifiable {
    case reflectivity, rain1h, rain24h
    public var id: String { rawValue }
    public var label: String {
        switch self { case .reflectivity: "Radar"; case .rain1h: "1-hr rain"; case .rain24h: "24-hr rain" }
    }
    public var isRainfallTotal: Bool { self != .reflectivity }
}

/// MRMS rainfall totals (radar + gauges) from IEM's free tiles (L21): one still frame, refreshed at most
/// every 10 minutes (the `v` query busts the tile caches).
public enum IEMMRMS {
    public static let refreshMinutes = 10

    public static func frame(_ layer: RadarLayer, now: Date) -> RadarFrame? {
        let product: String
        switch layer {
        case .reflectivity: return nil
        case .rain1h: product = "q2-n1p"
        case .rain24h: product = "q2-p24h"
        }
        let bucket = (now.timeIntervalSince1970 / Double(refreshMinutes * 60)).rounded(.down) * Double(refreshMinutes * 60)
        return RadarFrame(time: Date(timeIntervalSince1970: bucket),
                          urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/\(product)/{z}/{x}/{y}.png?v=\(Int(bucket))")
    }

    /// The IEM MRMS colour ramp (same for 1 h and 24 h), in mm; the legend shows inches or mm.
    public static let legendStops: [(mm: Double, hex: UInt32)] = [
        (2, 0x0030FF), (8, 0x00C0FF), (14, 0x00FE7E), (20, 0x12FE00), (30, 0xA2FE00),
        (45, 0xEAF000), (60, 0xFEA800), (90, 0xFE1800), (125, 0xFE0078),
    ]
}

/// Drops answers to superseded requests (L7: an older radar index response must not replace a newer one).
public struct RequestGeneration: Sendable {
    public private(set) var current = 0
    public init() {}
    /// Starts a request; keep the token and check it when the answer arrives.
    public mutating func next() -> Int { current += 1; return current }
    public func isCurrent(_ token: Int) -> Bool { token == current }
}
