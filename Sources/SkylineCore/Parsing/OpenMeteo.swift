import Foundation

/// Forecast models requested from Open-Meteo. `best_match` is Open-Meteo's own per-location
/// composite (it already picks the best regional model); the others feed the blend.
public enum ForecastModel: String, CaseIterable, Codable, Sendable {
    case bestMatch = "best_match"
    case hrrr = "gfs_hrrr"          // NOAA HRRR 3 km, CONUS, ~48 h, hourly updates
    case ecmwf = "ecmwf_ifs025"     // ECMWF IFS 0.25°, global, 10+ days
    case gfs = "gfs_seamless"       // NOAA GFS (+HRRR seamless), global
    case icon = "icon_seamless"     // DWD ICON (2 km in Europe), global

    public var displayName: String {
        switch self {
        case .bestMatch: "Open-Meteo Best Match"
        case .hrrr: "NOAA HRRR"
        case .ecmwf: "ECMWF IFS"
        case .gfs: "NOAA GFS"
        case .icon: "DWD ICON"
        }
    }

    /// Models worth requesting for a coordinate.
    public static func models(for coordinate: Coordinate) -> [ForecastModel] { models(inCONUS: coordinate.isInCONUS) }

    /// HRRR only covers the lower 48.
    public static func models(inCONUS: Bool) -> [ForecastModel] {
        inCONUS ? [.bestMatch, .hrrr, .ecmwf, .gfs, .icon] : [.bestMatch, .ecmwf, .gfs, .icon]
    }
}

/// Raw Open-Meteo `/v1/forecast` response with `timeformat=unixtime` and one or more `models`.
/// With multiple models every hourly/daily/minutely key is suffixed with `_<model>`; with a single
/// model the keys are bare. `current` is always bare.
public struct OpenMeteoResponse: Decodable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timezone: String
    public var utcOffsetSeconds: Int
    public var current: Current?
    public var hourly: [String: [Double?]]?
    public var daily: [String: [Double?]]?
    public var minutely15: [String: [Double?]]?

    public struct Current: Decodable, Sendable {
        public var time: Double
        public var temperature_2m: Double?
        public var relative_humidity_2m: Double?
        public var apparent_temperature: Double?
        public var is_day: Double?
        public var precipitation: Double?
        public var weather_code: Double?
        public var cloud_cover: Double?
        public var pressure_msl: Double?
        public var wind_speed_10m: Double?
        public var wind_direction_10m: Double?
        public var wind_gusts_10m: Double?
        public var visibility: Double?
        public var uv_index: Double?
        public var dew_point_2m: Double?
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, timezone, current, hourly, daily
        case utcOffsetSeconds = "utc_offset_seconds"
        case minutely15 = "minutely_15"
    }

    public static func decode(_ data: Data) throws -> OpenMeteoResponse {
        try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }

    // MARK: Column access

    /// Returns the column for `variable` from `model`, accepting both suffixed and bare keys.
    static func column(_ table: [String: [Double?]]?, _ variable: String, _ model: ForecastModel) -> [Double?]? {
        guard let table else { return nil }
        if let c = table["\(variable)_\(model.rawValue)"] { return c }
        if model == .bestMatch, let c = table[variable] { return c }
        return nil
    }

    public func hourlyColumn(_ variable: String, model: ForecastModel) -> [Double?]? {
        Self.column(hourly, variable, model)
    }

    public func dailyColumn(_ variable: String, model: ForecastModel) -> [Double?]? {
        Self.column(daily, variable, model)
    }

    public var hourlyTimes: [Date] { (hourly?["time"] ?? []).compactMap { $0.map { Date(timeIntervalSince1970: $0) } } }
    public var dailyTimes: [Date] { (daily?["time"] ?? []).compactMap { $0.map { Date(timeIntervalSince1970: $0) } } }

    /// Models that actually returned at least one non-null hourly temperature.
    public var modelsWithData: [ForecastModel] {
        ForecastModel.allCases.filter { m in
            hourlyColumn("temperature_2m", model: m)?.contains { $0 != nil } ?? false
        }
    }

    public func currentConditions() -> CurrentConditions? {
        guard let c = current, let t = c.temperature_2m else { return nil }
        return CurrentConditions(
            time: Date(timeIntervalSince1970: c.time),
            temperature: t,
            apparentTemperature: c.apparent_temperature ?? t,
            humidity: c.relative_humidity_2m ?? 0,
            dewPoint: c.dew_point_2m,
            weatherCode: Int(c.weather_code ?? 3),
            isDay: (c.is_day ?? 1) >= 1,
            precipitation: c.precipitation ?? 0,
            cloudCover: c.cloud_cover,
            pressure: c.pressure_msl,
            windSpeed: c.wind_speed_10m ?? 0,
            windDirection: c.wind_direction_10m,
            windGust: c.wind_gusts_10m,
            visibility: c.visibility,
            uvIndex: c.uv_index)
    }

    public func minutelyPrecipitation() -> [MinutelyPrecipitation] {
        guard let times = minutely15?["time"],
              let values = Self.column(minutely15, "precipitation", .bestMatch) else { return [] }
        return zip(times, values).compactMap { t, v in
            guard let t, let v else { return nil }
            return MinutelyPrecipitation(time: Date(timeIntervalSince1970: t), precipitation: v)
        }
    }
}

public struct OpenMeteoAirQualityResponse: Decodable, Sendable {
    public struct Current: Decodable, Sendable {
        public var us_aqi: Double?
        public var pm2_5: Double?
        public var pm10: Double?
        public var ozone: Double?
    }
    public struct Hourly: Decodable, Sendable {
        public var time: [Double]?
        public var us_aqi: [Double?]?
    }
    public var current: Current?
    public var hourly: Hourly?

    public static func decode(_ data: Data) throws -> AirQuality? {
        let r = try JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data)
        guard let c = r.current, let aqi = c.us_aqi else { return nil }
        var result = AirQuality(usAQI: Int(aqi.rounded()), pm25: c.pm2_5, pm10: c.pm10, ozone: c.ozone)
        if let times = r.hourly?.time, let values = r.hourly?.us_aqi {
            result.hourly = zip(times, values).compactMap { t, v in
                v.map { HourlyValue(time: Date(timeIntervalSince1970: t), value: $0) }
            }
        }
        return result
    }
}

public struct OpenMeteoGeocodingResponse: Decodable, Sendable {
    public struct Result: Decodable, Sendable {
        public var id: Int
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public var country: String?
        public var country_code: String?
        public var admin1: String?
        public var timezone: String?
        public var population: Int?
    }
    public var results: [Result]?

    public static func decode(_ data: Data) throws -> [PlaceSearchResult] {
        let r = try JSONDecoder().decode(OpenMeteoGeocodingResponse.self, from: data)
        return (r.results ?? []).map {
            PlaceSearchResult(id: $0.id, name: $0.name, admin1: $0.admin1, country: $0.country,
                              countryCode: $0.country_code,
                              coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude),
                              timeZoneIdentifier: $0.timezone, population: $0.population)
        }
    }
}
