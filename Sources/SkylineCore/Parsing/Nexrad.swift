import Foundation

/// One NWS WSR-88D radar site.
public struct NexradStation: Hashable, Sendable, Identifiable, Codable {
    /// IEM site id without the leading K/P/T ("OKX" for KOKX).
    public var id: String
    public var name: String
    public var state: String
    public var latitude: Double
    public var longitude: Double

    public init(id: String, name: String, state: String, latitude: Double, longitude: Double) {
        self.id = id; self.name = name; self.state = state; self.latitude = latitude; self.longitude = longitude
    }

    /// The four-letter ICAO id shown to people ("KOKX").
    public var icao: String { id.count == 3 ? (state == "PR" ? "T" : ["AK", "HI", "GU"].contains(state) ? "P" : "K") + id : id }
    public var label: String { "\(icao) · \(name), \(state)" }
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public static func station(id: String) -> NexradStation? {
        let key = id.uppercased()
        return all.first { $0.id == key || $0.icao == key }
    }

    /// Lower 48 sites (the picker list; RainViewer covers everywhere else).
    public static let conus: [NexradStation] = all
        .filter { !["AK", "HI", "PR", "GU", ""].contains($0.state) }
        .sorted { ($0.state, $0.name) < ($1.state, $1.name) }

    /// Great-circle distance in km.
    public static func distanceKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// The closest lower-48 site within `maxKm` (a WSR-88D's useful reflectivity range is ~460 km).
    public static func nearest(to c: Coordinate, maxKm: Double = 460, among list: [NexradStation] = conus) -> NexradStation? {
        list.map { ($0, distanceKm(c, $0.coordinate)) }
            .filter { $0.1 <= maxKm }
            .min { $0.1 < $1.1 }?.0
    }
}

/// Which NEXRAD view to show. Persisted as a string under "radarSite": "auto", "composite" or a site id.
public enum RadarSiteChoice: Hashable, Sendable {
    /// The site nearest the selected city (the default).
    case auto
    /// IEM's national N0Q mosaic.
    case composite
    case site(String)

    public init(stored: String?) {
        switch stored {
        case nil, "", "auto": self = .auto
        case "composite": self = .composite
        case let s?: self = NexradStation.station(id: s).map { .site($0.id) } ?? .auto
        }
    }

    public var stored: String {
        switch self { case .auto: "auto"; case .composite: "composite"; case .site(let id): id }
    }

    /// The single site to load, or nil for the national composite. Outside the lower 48 nothing applies.
    public func resolvedStation(for coordinate: Coordinate, inCONUS: Bool) -> NexradStation? {
        guard inCONUS else { return nil }
        switch self {
        case .composite: return nil
        case .site(let id): return NexradStation.station(id: id)
        case .auto: return NexradStation.nearest(to: coordinate)
        }
    }
}

/// Single-site RIDGE tiles from IEM. Single sites publish N0B (super-res base reflectivity); IEM's
/// single-site N0Q layers stopped updating in 2023 (their `N0Q_0.json` still says June 2023, and the
/// tiles are blank), so the per-site loop uses N0B. Scans are irregular (4–6 min, VCP dependent), so the
/// frame times come from IEM's scan list, not a fixed 5-minute grid: an archived layer only exists at an
/// exact scan minute.
public enum IEMRidge {
    public static let product = "N0B"

    static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    public static func scanListURL(site: String, start: Date, end: Date) -> URL {
        let f = utcFormatter("yyyy-MM-dd'T'HH:mm'Z'")
        var c = URLComponents(string: "https://mesonet.agron.iastate.edu/json/radar.py")!
        c.queryItems = [
            .init(name: "operation", value: "list"), .init(name: "product", value: product),
            .init(name: "radar", value: site), .init(name: "start", value: f.string(from: start)),
            .init(name: "end", value: f.string(from: end)),
        ]
        return c.url!
    }

    struct Raw: Decodable { struct Scan: Decodable { var ts: String }; var scans: [Scan] }

    public static func decodeScans(_ data: Data) throws -> [Date] {
        let f = utcFormatter("yyyy-MM-dd'T'HH:mm'Z'")
        return try JSONDecoder().decode(Raw.self, from: data).scans.compactMap { f.date(from: $0.ts) }.sorted()
    }

    public static func tileTemplate(site: String, time: Date) -> String {
        "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::\(site)-\(product)-\(utcFormatter("yyyyMMddHHmm").string(from: time))/{z}/{x}/{y}.png"
    }

    /// Picks scans for the loop: the newest, then walking back, each at least `stepMinutes − 1` earlier
    /// than the last kept one, within the range. Same frame budget as the composite loop.
    public static func frames(site: String, scans: [Date], range: RadarRange) -> [RadarFrame] {
        guard let latest = scans.last else { return [] }
        let earliest = latest.addingTimeInterval(-Double(range.totalMinutes * 60))
        let minGap = Double((range.stepMinutes - 1) * 60)
        var kept: [Date] = []
        for t in scans.reversed() where t >= earliest {
            if let last = kept.last, last.timeIntervalSince(t) < minGap { continue }
            kept.append(t)
        }
        return kept.reversed().map { RadarFrame(time: $0, urlTemplate: tileTemplate(site: site, time: $0)) }
    }
}
