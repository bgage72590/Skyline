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
        .filter { s in let st = s.state.trimmingCharacters(in: .whitespaces); return !st.isEmpty && !["AK", "HI", "PR", "GU"].contains(st) }
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
    /// Picker title for the automatic choice: "Nearest (KOKX)".
    public static func nearestLabel(_ station: NexradStation?) -> String {
        station.map { "Nearest (\($0.icao))" } ?? "Nearest"
    }

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

    /// IEM's archived scan raster, without extension (`.png` palette image, `.wld` world file).
    public static func rasterBase(site: String, time: Date) -> String {
        let d = utcFormatter("yyyy/MM/dd").string(from: time), t = utcFormatter("yyyyMMddHHmm").string(from: time)
        return "https://mesonet.agron.iastate.edu/archive/data/\(d)/GIS/ridge/\(site)/\(product)/\(site)_\(product)_\(t)"
    }

    /// Picks scans for the loop: the newest, then walking back, each at least `stepMinutes − 1` earlier
    /// than the last kept one, within the range. Same frame budget as the composite loop.
    /// The same frames with only the newest drawn from IEM's tile (its raster isn't archived yet).
    public static func newestBlocky(_ frames: [RadarFrame], site: String) -> [RadarFrame] {
        guard let last = frames.last else { return frames }
        var out = frames
        out[out.count - 1] = RadarFrame(time: last.time, urlTemplate: tileTemplate(site: site, time: last.time))
        return out
    }

    /// The newest frame is a site scan waiting for its raster while older ones are smooth: poll and swap.
    public static func isPendingSmooth(_ frames: [RadarFrame]) -> Bool {
        let observed = frames.filter { !$0.isForecast }
        guard let last = observed.last, observed.count > 1, last.urlTemplate.contains("ridge::"),
              !last.urlTemplate.contains("#raw=") else { return false }
        return observed[observed.count - 2].urlTemplate.contains("#raw=")
    }

    /// Only the newest observed frame changed, blocky → smooth (same times otherwise): swap in place,
    /// without restarting the loop's loading progress.
    public static func isNewestUpgrade(from old: [RadarFrame], to new: [RadarFrame]) -> Bool {
        guard old.count == new.count, !old.isEmpty, zip(old, new).allSatisfy({ $0.time == $1.time }) else { return false }
        let changed = old.indices.filter { old[$0] != new[$0] }
        guard changed.count == 1, let i = changed.first, !new[i].isForecast else { return false }
        return !old[i].urlTemplate.contains("#raw=") && new[i].urlTemplate.contains("#raw=")
            && new[i].urlTemplate.hasPrefix(old[i].urlTemplate)
    }

    public static func frames(site: String, scans: [Date], range: RadarRange, smooth: Bool = true) -> [RadarFrame] {
        guard let latest = scans.last else { return [] }
        let earliest = latest.addingTimeInterval(-Double(range.totalMinutes * 60))
        let minGap = Double((range.stepMinutes - 1) * 60)
        var kept: [Date] = []
        for t in scans.reversed() where t >= earliest {
            if let last = kept.last, last.timeIntervalSince(t) < minGap { continue }
            kept.append(t)
        }
        // Item 4: render from the scan's raster (smooth); IEM's tile stays the fallback.
        return kept.reversed().map {
            RadarFrame(time: $0, urlTemplate: tileTemplate(site: site, time: $0) + (smooth ? "#raw=" + rasterBase(site: site, time: $0) : ""))
        }
    }
}
