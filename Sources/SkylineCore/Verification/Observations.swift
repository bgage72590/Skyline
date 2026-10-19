import Foundation

/// One NWS station observation (api.weather.gov `/stations/{id}/observations`).
public struct StationObservation: Hashable, Sendable {
    public var time: Date
    public var temperatureC: Double?
    public var windKmh: Double?
    /// Precipitation for the last hour (mm), reported only by some (hourly) METARs.
    public var precipLastHourMM: Double?
    /// True when present weather includes falling precipitation (rain, drizzle, snow, storms, ice…).
    public var precipitating: Bool

    public init(time: Date, temperatureC: Double?, windKmh: Double?, precipLastHourMM: Double?, precipitating: Bool) {
        self.time = time; self.temperatureC = temperatureC; self.windKmh = windKmh
        self.precipLastHourMM = precipLastHourMM; self.precipitating = precipitating
    }
}

public enum NWSObservationParser {
    struct Raw: Decodable {
        struct Value: Decodable { var value: Double?; var unitCode: String? }
        struct Weather: Decodable { var weather: String? }
        struct Props: Decodable {
            var timestamp: String
            var temperature: Value?
            var windSpeed: Value?
            var precipitationLastHour: Value?
            var presentWeather: [Weather]?
        }
        struct Feature: Decodable { var properties: Props }
        var features: [Feature]
    }

    static let precipitationKinds: Set<String> = [
        "rain", "drizzle", "snow", "snow_grains", "ice_crystals", "ice_pellets", "hail", "small_hail",
        "snow_pellets", "thunderstorms", "rain_showers", "snow_showers", "unknown_precipitation", "freezing_rain",
        "freezing_drizzle",
    ]

    /// Oldest first. Wind in m/s or knots is converted to km/h.
    public static func decode(_ data: Data) throws -> [StationObservation] {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.features.compactMap { f -> StationObservation? in
            let p = f.properties
            guard let time = NWSDate.parse(p.timestamp) else { return nil }
            var wind = p.windSpeed?.value
            if let w = wind, let unit = p.windSpeed?.unitCode {
                if unit.hasSuffix("m_s-1") { wind = w * 3.6 } else if unit.hasSuffix("kn") || unit.hasSuffix("knot") { wind = w * 1.852 }
            }
            let precipitating = (p.presentWeather ?? []).contains { w in
                guard let kind = w.weather else { return false }
                return precipitationKinds.contains(kind) || kind.contains("rain") || kind.contains("snow") || kind.contains("drizzle")
            }
            return StationObservation(time: time, temperatureC: p.temperature?.value, windKmh: wind,
                                      precipLastHourMM: p.precipitationLastHour?.value, precipitating: precipitating)
        }
        .sorted { $0.time < $1.time }
    }

    struct GridpointStation {
        var id: String
        var name: String?
        var provider: String?
        var coordinate: Coordinate?
    }

    /// First station id from a gridpoint `/stations` list. Kept for the no-ASOS fallback.
    public static func firstStation(_ data: Data) throws -> (id: String, name: String?)? {
        let list = try gridpointStations(data)
        return list.first.map { ($0.id, $0.name) }
    }

    /// Nearest ASOS airport on the gridpoint list (great-circle to `point`).
    /// An ASOS airport has an ICAO-style METAR id, an NWS provider of `ASOS` / `ASOS-…`, and an airport name.
    /// When none is present, returns the first station — the previous behavior.
    public static func verificationStation(_ data: Data, near point: Coordinate?) throws -> (id: String, name: String?)? {
        let list = try gridpointStations(data)
        guard let first = list.first else { return nil }
        let airports = list.filter { isASOSAirport($0) }
        guard let point, !airports.isEmpty else { return (first.id, first.name) }
        let located = airports.filter { $0.coordinate != nil }
        let pool = located.isEmpty ? airports : located
        let best = pool.min { a, b in
            guard let ac = a.coordinate, let bc = b.coordinate else { return false }
            return NexradStation.distanceKm(point, ac) < NexradStation.distanceKm(point, bc)
        }
        let chosen = best ?? first
        return (chosen.id, chosen.name)
    }

    /// ICAO-style METAR id (`KNYC`, `KLGA`, `K12N`) whose NWS `provider` is ASOS and whose name is an airport.
    /// Central Park (`KNYC`, ASOS, not an airport) and HADS/RAWS ids (`SFOC1`) do not qualify.
    public static func isASOSAirport(id: String, provider: String?, name: String?) -> Bool {
        let ident = id.uppercased()
        guard ident.range(of: "^[A-Z][A-Z0-9]{3}$", options: .regularExpression) != nil else { return false }
        let prov = (provider ?? "").uppercased()
        guard prov == "ASOS" || prov.hasPrefix("ASOS-") || prov.hasPrefix("ASOS ") else { return false }
        return isAirportName(name ?? "")
    }

    static func isASOSAirport(_ station: GridpointStation) -> Bool {
        isASOSAirport(id: station.id, provider: station.provider, name: station.name)
    }

    /// Airport wording used by api.weather.gov station names (plus naval air stations and airparks).
    static func isAirportName(_ name: String) -> Bool {
        let n = name.lowercased()
        let phrases = ["airport", "airpark", "airfield", "air field", "air force", "air station", "airbase", "air base", "flight"]
        if phrases.contains(where: { n.contains($0) }) { return true }
        let words = n.split { !$0.isLetter }.map(String.init)
        return words.contains("field") || words.contains("afb") || words.contains("aaf")
    }

    static func gridpointStations(_ data: Data) throws -> [GridpointStation] {
        struct List: Decodable {
            struct Geom: Decodable { var coordinates: [Double]? }
            struct F: Decodable {
                struct P: Decodable {
                    var stationIdentifier: String?
                    var name: String?
                    var provider: String?
                }
                var properties: P
                var geometry: Geom?
            }
            var features: [F]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.features.compactMap { f in
            guard let id = f.properties.stationIdentifier, !id.isEmpty else { return nil }
            var coordinate: Coordinate?
            if let c = f.geometry?.coordinates, c.count >= 2 {
                coordinate = Coordinate(latitude: c[1], longitude: c[0])
            }
            return GridpointStation(id: id, name: f.properties.name, provider: f.properties.provider, coordinate: coordinate)
        }
    }
}

/// Turns raw station observations into one `ObservedHour` per forecast valid hour.
public enum ObservationAggregator {
    /// Window used for instantaneous values (temperature, wind) around the valid time.
    public static let instantTolerance: TimeInterval = 20 * 60

    /// - Returns: nil when there are no usable observations near this hour.
    public static func observe(_ obs: [StationObservation], validTime v: Date) -> ObservedHour? {
        func nearest(_ value: (StationObservation) -> Double?) -> Double? {
            obs.filter { abs($0.time.timeIntervalSince(v)) <= instantTolerance && value($0) != nil }
                .min { abs($0.time.timeIntervalSince(v)) < abs($1.time.timeIntervalSince(v)) }
                .flatMap(value)
        }
        let t = nearest(\.temperatureC)
        let w = nearest(\.windKmh)
        // Precipitation for the hour ending at v (Open-Meteo convention).
        let hour = obs.filter { $0.time > v.addingTimeInterval(-3600) && $0.time <= v.addingTimeInterval(10 * 60) }
        let amount = obs.filter { abs($0.time.timeIntervalSince(v)) <= 15 * 60 }.compactMap(\.precipLastHourMM).max()
        var wet: Bool?
        if hour.count >= 3 || amount != nil {
            let fraction = hour.isEmpty ? 0 : Double(hour.filter(\.precipitating).count) / Double(hour.count)
            wet = (amount ?? 0) >= 0.2 || fraction >= 0.25
        }
        guard t != nil || w != nil || wet != nil else { return nil }
        return ObservedHour(t: t, w: w, wet: wet, p: amount)
    }
}
