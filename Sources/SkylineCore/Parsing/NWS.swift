import Foundation

/// api.weather.gov `/points/{lat},{lon}` metadata.
public struct NWSPoint: Codable, Hashable, Sendable {
    public var forecastURL: URL
    public var forecastHourlyURL: URL
    public var gridID: String
    public var city: String?
    public var state: String?
    public var timeZone: String?
    /// Gridpoint stations list (nearest first), used for forecast verification.
    public var observationStations: URL?

    struct Raw: Decodable {
        struct Props: Decodable {
            var forecast: URL
            var forecastHourly: URL
            var gridId: String
            var timeZone: String?
            var observationStations: URL?
            var relativeLocation: RelLoc?
        }
        struct RelLoc: Decodable {
            struct P: Decodable { var city: String?; var state: String? }
            var properties: P
        }
        var properties: Props
    }

    public static func decode(_ data: Data) throws -> NWSPoint {
        let p = try JSONDecoder().decode(Raw.self, from: data).properties
        return NWSPoint(forecastURL: p.forecast, forecastHourlyURL: p.forecastHourly, gridID: p.gridId,
                        city: p.relativeLocation?.properties.city, state: p.relativeLocation?.properties.state,
                        timeZone: p.timeZone, observationStations: p.observationStations)
    }
}

/// One period of an NWS `/forecast` (12 h day/night) or `/forecast/hourly` response.
public struct NWSPeriod: Codable, Hashable, Sendable {
    public var name: String
    public var startTime: Date
    public var endTime: Date
    public var isDaytime: Bool
    public var temperatureC: Double
    public var probabilityOfPrecipitation: Double?
    public var relativeHumidity: Double?
    public var windSpeedKmh: Double?
    public var windDirection: Double?
    public var shortForecast: String
    public var detailedForecast: String

    struct Raw: Decodable {
        struct Value: Decodable { var value: Double? }
        struct Props: Decodable { var periods: [Period] }
        struct Period: Decodable {
            var name: String?
            var startTime: String
            var endTime: String
            var isDaytime: Bool
            var temperature: Double
            var temperatureUnit: String
            var probabilityOfPrecipitation: Value?
            var relativeHumidity: Value?
            var windSpeed: String?
            var windDirection: String?
            var shortForecast: String?
            var detailedForecast: String?
        }
        var properties: Props
    }

    public static func decodeList(_ data: Data) throws -> [NWSPeriod] {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.properties.periods.compactMap { p in
            guard let start = NWSDate.parse(p.startTime), let end = NWSDate.parse(p.endTime) else { return nil }
            let tempC = p.temperatureUnit.uppercased() == "F" ? (p.temperature - 32) * 5 / 9 : p.temperature
            return NWSPeriod(
                name: p.name ?? "",
                startTime: start, endTime: end, isDaytime: p.isDaytime,
                temperatureC: tempC,
                probabilityOfPrecipitation: p.probabilityOfPrecipitation?.value,
                relativeHumidity: p.relativeHumidity?.value,
                windSpeedKmh: p.windSpeed.flatMap(parseWindSpeedKmh),
                windDirection: p.windDirection.flatMap(Compass.degrees),
                shortForecast: p.shortForecast ?? "",
                detailedForecast: p.detailedForecast ?? "")
        }
    }

    /// Parses "13 mph" or "13 to 17 mph" (takes the upper bound) into km/h.
    public static func parseWindSpeedKmh(_ s: String) -> Double? {
        let numbers = s.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard let v = numbers.max() else { return nil }
        if s.lowercased().contains("km/h") { return v }
        if s.lowercased().contains("kt") { return v * 1.852 }
        return v * 1.609344
    }
}

public enum NWSAlertParser {
    struct Raw: Decodable {
        struct Feature: Decodable { var properties: Props; var geometry: GeoJSONGeometry? }
        struct Props: Decodable {
            var affectedZones: [String]?
            var id: String
            var event: String
            var headline: String?
            var severity: String?
            var urgency: String?
            var areaDesc: String?
            var description: String?
            var instruction: String?
            var effective: String?
            var expires: String?
            var ends: String?
            var senderName: String?
            var status: String?
        }
        var features: [Feature]
    }

    /// Parses `/alerts/active` GeoJSON. Drops test/exercise messages, sorts most severe first.
    public static func decode(_ data: Data) throws -> [WeatherAlert] {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.features
            .filter { ($0.properties.status ?? "Actual") == "Actual" }
            .map { f in
                let p = f.properties
                var alert = WeatherAlert(id: p.id, event: p.event, headline: p.headline,
                             severity: AlertSeverity(rawValue: p.severity ?? "") ?? .unknown,
                             urgency: p.urgency, areaDescription: p.areaDesc,
                             description: p.description, instruction: p.instruction,
                             effective: p.effective.flatMap(NWSDate.parse),
                             expires: p.expires.flatMap(NWSDate.parse),
                             ends: p.ends.flatMap(NWSDate.parse), senderName: p.senderName)
                alert.polygons = f.geometry?.rings ?? []
                alert.affectedZones = (p.affectedZones ?? []).compactMap(URL.init(string:))
                return alert
            }
            .sorted { $0.severity == $1.severity ? ($0.effective ?? .distantPast) > ($1.effective ?? .distantPast)
                                                  : $0.severity > $1.severity }
    }
}

/// Minimal GeoJSON geometry: Polygon / MultiPolygon outer rings as coordinates (holes ignored).
public struct GeoJSONGeometry: Decodable, Sendable {
    public var rings: [[Coordinate]]

    enum CodingKeys: String, CodingKey { case type, coordinates }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func ring(_ points: [[Double]]) -> [Coordinate] {
            points.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[1], longitude: $0[0]) : nil }
        }
        switch type {
        case "Polygon":
            let polygon = try c.decode([[[Double]]].self, forKey: .coordinates)
            rings = polygon.prefix(1).map(ring)
        case "MultiPolygon":
            let multi = try c.decode([[[[Double]]]].self, forKey: .coordinates)
            rings = multi.compactMap { $0.first.map(ring) }
        default:
            rings = []
        }
        rings = rings.map { GeoJSONGeometry.simplify($0, maxPoints: 400) }.filter { $0.count >= 3 }
    }

    /// Keeps every n-th point so detailed zone outlines stay cheap to draw.
    public static func simplify(_ ring: [Coordinate], maxPoints: Int) -> [Coordinate] {
        guard ring.count > maxPoints, maxPoints > 3 else { return ring }
        let step = Double(ring.count) / Double(maxPoints)
        var out: [Coordinate] = []
        var i = 0.0
        while Int(i) < ring.count { out.append(ring[Int(i)]); i += step }
        if let last = ring.last, out.last != last { out.append(last) }
        return out
    }
}

/// `/zones/forecast/{id}` → the zone outline.
public enum NWSZoneParser {
    struct Raw: Decodable { var geometry: GeoJSONGeometry? }
    public static func decode(_ data: Data) throws -> [[Coordinate]] {
        try JSONDecoder().decode(Raw.self, from: data).geometry?.rings ?? []
    }
}

enum NWSDate {
    /// ISO-8601 with offset, e.g. "2026-10-11T09:00:00-04:00". Formatter created per call
    /// (cheap relative to network I/O) to stay Sendable-clean.
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
