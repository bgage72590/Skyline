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

    /// IEM keeps 11 cached composites at 5-minute steps: `m50m` (oldest) … `m05m`, then the bare layer.
    /// A `?v=<latest>` cache-buster is appended because each layer name is a *relative* time slot
    /// whose content changes every 5 minutes.
    public static func frames(latest: Date) -> [RadarFrame] {
        let version = Int(latest.timeIntervalSince1970)
        return stride(from: 50, through: 0, by: -5).map { minutesAgo in
            let layer = minutesAgo == 0 ? "nexrad-n0q-900913" : String(format: "nexrad-n0q-900913-m%02dm", minutesAgo)
            return RadarFrame(time: latest.addingTimeInterval(-Double(minutesAgo) * 60),
                              urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/\(layer)/{z}/{x}/{y}.png?v=\(version)")
        }
    }
}
