import Foundation

/// Where the US-only sources work: NWS (forecasts, warnings, discussions), the NEXRAD mosaic and HRRR.
///
/// The old checks were bounding boxes, and the CONUS box (24–50°N) took in Toronto, Montreal, Ottawa,
/// Vancouver and Monterrey: they got US radar with holes, an HRRR request and a failing NWS `/points`
/// call on every refresh (QA 4). These are simplified outlines that follow the borders closely enough
/// for cities (a few km), plus the saved city's country when it's known.
public enum USCoverage {
    /// Lower 48 outline (latitude, longitude), following the 49th parallel, the Great Lakes / St Lawrence
    /// border, Maine, the Atlantic and Gulf a little offshore, the Rio Grande and the Mexican border.
    static let conus: [Coordinate] = [
        (49.00, -123.32), (49.00, -95.15), (48.60, -93.40), (48.10, -89.60), (48.30, -88.40), (47.40, -86.40),
        (46.95, -84.80), (46.48, -84.25), (45.95, -83.45), (45.30, -82.50), (43.60, -82.15), (43.00, -82.42),
        (42.62, -82.52), (42.45, -82.70), (42.35, -82.95), (42.05, -83.12), (41.68, -82.68), (42.00, -81.20),
        (42.40, -79.90), (42.80, -79.00), (42.88, -78.91), (43.10, -79.06), (43.26, -79.06), (43.58, -78.70),
        (43.62, -76.80), (44.10, -76.42), (44.35, -75.90), (44.62, -75.55), (44.73, -75.47),
        (44.98, -74.98), (45.00, -74.70), (45.00, -71.50), (45.30, -71.08),
        (46.40, -70.05), (47.43, -69.22), (47.35, -68.35), (47.06, -67.79), (45.93, -67.78), (45.60, -67.43),
        (45.15, -67.30), (44.80, -66.95), (44.50, -66.50), (41.00, -68.50), (35.00, -74.50), (31.00, -79.00),
        (25.60, -79.40), (24.40, -80.40), (24.30, -81.80), (24.40, -83.00), (25.96, -96.95), (25.96, -97.14),
        (25.85, -97.40), (25.88, -97.55), (26.05, -97.85), (26.20, -98.30), (26.40, -99.00), (27.00, -99.45), (27.49, -99.50), (28.20, -100.30),
        (28.70, -100.50), (29.40, -101.00), (29.80, -101.40), (29.75, -102.40), (29.20, -102.90), (28.97, -103.15),
        (29.50, -104.35), (30.00, -104.60), (30.60, -105.00), (31.10, -105.60), (31.78, -106.53), (31.78, -108.21),
        (31.33, -108.21), (31.33, -111.07), (32.49, -114.81), (32.72, -114.72), (32.535, -117.12), (32.30, -119.50),
        (34.00, -121.50), (40.00, -125.50), (48.40, -125.00), (48.30, -123.90), (48.22, -123.25), (48.45, -123.20),
        (48.75, -123.00), (49.00, -123.32),
    ].map { Coordinate(latitude: $0.0, longitude: $0.1) }

    /// Mainland Alaska west of 141°W, plus the panhandle (Juneau in, Whitehorse and Prince Rupert out).
    static let alaskaPanhandle: [Coordinate] = [
        (60.35, -141.0), (59.95, -138.9), (59.80, -136.5), (59.65, -135.1), (58.90, -133.8), (57.90, -133.0),
        (57.00, -132.1), (56.40, -131.0), (55.90, -130.0), (55.00, -130.0), (54.60, -130.7), (54.60, -133.5),
        (56.00, -136.0), (57.50, -137.0), (59.50, -141.0),
    ].map { Coordinate(latitude: $0.0, longitude: $0.1) }

    public static func isInCONUS(_ c: Coordinate) -> Bool { contains(conus, c) }

    public static func isInNWSArea(_ c: Coordinate) -> Bool {
        if isInCONUS(c) { return true }
        if c.latitude >= 51, c.latitude <= 71.6, c.longitude >= -170, c.longitude <= -141 { return true } // Alaska
        if contains(alaskaPanhandle, c) { return true }
        let boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = [
            (18.5, 22.5, -160.5, -154.5),   // Hawaii
            (17.5, 18.6, -67.5, -64.5),     // Puerto Rico / USVI
            (13.0, 15.5, 144.5, 146.0),     // Guam / CNMI
        ]
        return boxes.contains { c.latitude >= $0.minLat && c.latitude <= $0.maxLat
            && c.longitude >= $0.minLon && c.longitude <= $0.maxLon }
    }

    /// Country names (as Open-Meteo's geocoder and Apple's reverse geocoder give them) that are US or
    /// NWS-served territories.
    static let usCountries: Set<String> = [
        "united states", "united states of america", "usa", "us", "u.s.", "puerto rico", "guam",
        "u.s. virgin islands", "us virgin islands", "united states virgin islands", "northern mariana islands",
        "american samoa",
    ]

    /// True when the saved place's country is known and isn't the US (nil/empty = unknown).
    public static func isKnownOutsideUS(country: String?) -> Bool {
        guard let c = country?.trimmingCharacters(in: .whitespaces).lowercased(), !c.isEmpty else { return false }
        return !usCountries.contains(c)
    }

    /// Ray casting on longitude/latitude.
    public static func contains(_ ring: [Coordinate], _ p: Coordinate) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

public extension WeatherLocation {
    /// NEXRAD mosaic, HRRR and future radar apply (lower 48 and the place isn't known to be abroad).
    var isInCONUS: Bool { !USCoverage.isKnownOutsideUS(country: country) && coordinate.isInCONUS }
    /// NWS forecasts, warnings and discussions apply.
    var isLikelyInNWSCoverage: Bool { !USCoverage.isKnownOutsideUS(country: country) && coordinate.isLikelyInNWSCoverage }
}
