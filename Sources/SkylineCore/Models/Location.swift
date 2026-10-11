import Foundation

/// A geographic coordinate in decimal degrees.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Rounded to 4 decimals (~11 m). NWS rejects more precision and it keeps cache keys stable.
    public var rounded: Coordinate {
        Coordinate(latitude: (latitude * 10_000).rounded() / 10_000,
                   longitude: (longitude * 10_000).rounded() / 10_000)
    }

    /// True when the point is inside NWS coverage (CONUS, Alaska, Hawaii, Puerto Rico / USVI, Guam).
    /// Coarse bounding boxes; NWS 404s are still handled gracefully for edge cases.
    public var isLikelyInNWSCoverage: Bool {
        let boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = [
            (24.0, 50.0, -125.5, -66.5),    // CONUS
            (51.0, 71.6, -170.0, -129.0),   // Alaska
            (18.5, 22.5, -160.5, -154.5),   // Hawaii
            (17.5, 18.6, -67.5, -64.5),     // Puerto Rico / USVI
            (13.0, 15.5, 144.5, 146.0),     // Guam / CNMI
        ]
        return boxes.contains { latitude >= $0.minLat && latitude <= $0.maxLat
            && longitude >= $0.minLon && longitude <= $0.maxLon }
    }

    /// True inside the HRRR / NEXRAD mosaic footprint (CONUS only).
    public var isInCONUS: Bool {
        latitude >= 24.0 && latitude <= 50.0 && longitude >= -125.5 && longitude <= -66.5
    }
}

/// A place the user follows (saved in the sidebar) or the device's current location.
public struct WeatherLocation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var region: String?
    public var country: String?
    public var coordinate: Coordinate
    public var timeZoneIdentifier: String?
    public var isCurrentLocation: Bool

    public init(id: String? = nil, name: String, region: String? = nil, country: String? = nil,
                coordinate: Coordinate, timeZoneIdentifier: String? = nil, isCurrentLocation: Bool = false) {
        self.id = id ?? String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        self.name = name
        self.region = region
        self.country = country
        self.coordinate = coordinate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isCurrentLocation = isCurrentLocation
    }

    public static let currentLocationID = "current-location"

    public var subtitle: String {
        [region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}
