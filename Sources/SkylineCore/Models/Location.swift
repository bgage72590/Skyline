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

    /// Rounded to 2 decimals (~1.1 km): plenty for weather (HRRR is 3 km, NWS grid 2.5 km) and
    /// doesn't pinpoint a house. Used for the device location before it leaves the Mac or is stored.
    public var coarse: Coordinate {
        Coordinate(latitude: (latitude * 100).rounded() / 100,
                   longitude: (longitude * 100).rounded() / 100)
    }

    /// True when the point is inside NWS coverage (lower 48, Alaska, Hawaii, Puerto Rico / USVI, Guam).
    /// Border-following outlines (`USCoverage`), so Toronto or Monterrey no longer count; NWS 404s are
    /// still handled (and remembered) for edge cases.
    public var isLikelyInNWSCoverage: Bool { USCoverage.isInNWSArea(self) }

    /// True inside the HRRR / NEXRAD mosaic footprint (lower 48 only).
    public var isInCONUS: Bool { USCoverage.isInCONUS(self) }
}

/// A place the user follows (saved in the sidebar) or the device's current location.
public struct WeatherLocation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var region: String?
    public var country: String?
    /// ISO 3166 code ("US", "CA"). Preferred over `country`, whose name is localized ("Vereinigte
    /// Staaten") when it comes from Apple's place lookup. Nil for cities saved by older builds.
    public var countryCode: String?
    public var coordinate: Coordinate
    public var timeZoneIdentifier: String?
    public var isCurrentLocation: Bool

    public init(id: String? = nil, name: String, region: String? = nil, country: String? = nil,
                coordinate: Coordinate, timeZoneIdentifier: String? = nil, isCurrentLocation: Bool = false,
                countryCode: String? = nil) {
        self.countryCode = countryCode
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

/// My Location results (forecast, place name) apply only while they're for where the Mac is now; a
/// slower answer for an earlier fix is dropped (L4). Compared at ~1 km, the same cell sent to the
/// weather services, so a GPS fix jittering a few metres doesn't discard a successful load.
public enum CurrentLocationGuard {
    public static func isCurrent(_ requested: Coordinate, current: Coordinate?) -> Bool {
        guard let current else { return false }
        return requested.coarse == current.coarse
    }
}
