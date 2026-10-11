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
}

/// One animation frame: a timestamp and an XYZ tile URL template with `{z}`, `{x}`, `{y}`.
public struct RadarFrame: Hashable, Sendable, Identifiable {
    public var time: Date
    public var urlTemplate: String
    public var id: String { urlTemplate }

    public init(time: Date, urlTemplate: String) {
        self.time = time
        self.urlTemplate = urlTemplate
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
        return (raw.radar.past + (raw.radar.nowcast ?? [])).map {
            RadarFrame(time: Date(timeIntervalSince1970: $0.time),
                       urlTemplate: "\(raw.host)\($0.path)/256/{z}/{x}/{y}/2/1_1.png")
        }
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
