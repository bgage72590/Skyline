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
public struct OpenMeteoResponse: Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timezone: String
    public var utcOffsetSeconds: Int
    /// Terrain elevation (m). Optional; fixtures without it still decode. Accuracy PR 2 narrow amendment.
    public var elevation: Double?
    public var current: Current?
    public var hourly: [String: [Double?]]?
    public var daily: [String: [Double?]]?
    public var minutely15: [String: [Double?]]?

    public struct Current: Codable, Sendable {
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
        case latitude, longitude, timezone, elevation, current, hourly, daily
        case utcOffsetSeconds = "utc_offset_seconds"
        case minutely15 = "minutely_15"
    }

    public static func decode(_ data: Data) throws -> OpenMeteoResponse {
        try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }

    /// Encode for MockHTTPClient pair halves and tests. Keys match Open-Meteo's wire names.
    public static func encode(_ response: OpenMeteoResponse) throws -> Data {
        try JSONEncoder().encode(response)
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

    /// Local calendar midnights for each `daily.time` entry in this response's IANA `timezone`.
    ///
    /// Open-Meteo (`timeformat=unixtime`) applies one fixed `utc_offset_seconds` to every daily row.
    /// After a fall-back DST change that skews later days onto 23:00 the previous evening. Recover the
    /// intended Y-M-D from the UTC calendar day of `(unix + utc_offset_seconds)`, then take
    /// `Calendar(tz).startOfDay` (which may be 01:00 in a midnight-transition zone). Raw `daily["time"]`
    /// is never mutated — cache / `pairConsistent` / `mergePair` keep comparing the wire arrays.
    public var dailyTimes: [Date] {
        guard let raw = daily?["time"] else { return [] }
        guard let tz = TimeZone(identifier: timezone) else {
            return raw.compactMap { $0.map { Date(timeIntervalSince1970: $0) } }
        }
        return raw.compactMap { t in
            t.map { Self.localDailyDate(unixTime: $0, utcOffsetSeconds: utcOffsetSeconds, timeZone: tz) }
        }
    }

    /// Intended local start-of-day for one Open-Meteo daily unixtime (see `dailyTimes`).
    public static func localDailyDate(unixTime: TimeInterval, utcOffsetSeconds: Int, timeZone: TimeZone) -> Date {
        let shifted = Date(timeIntervalSince1970: unixTime + TimeInterval(utcOffsetSeconds))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let y = utc.component(.year, from: shifted)
        let m = utc.component(.month, from: shifted)
        let d = utc.component(.day, from: shifted)
        // Noon UTC on that Y-M-D sits inside the local calendar day for any civil offset.
        let utcNoon = utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.startOfDay(for: utcNoon)
    }

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

    // MARK: A+B pair merge (CR M1 / M2)

    /// Max storedAt gap for two cached halves to count as one pair.
    public static let pairStoredAtSlack: TimeInterval = 120

    /// Hourly columns taken from B as bare (best_match) keys.
    public static let pairHourlyFromB = ["is_day", "wind_direction_10m"]
    /// Daily columns taken from B as bare (best_match) keys.
    public static let pairDailyFromB = ["weather_code", "sunrise", "sunset", "uv_index_max", "wind_direction_10m_dominant"]

    /// True when cached halves may be merged: storedAt ≤ 120 s apart and hourly/daily `time`,
    /// `timezone`, and `utc_offset_seconds` equal. A mismatch is a pair miss, never a decode error.
    public static func pairConsistent(_ a: OpenMeteoResponse, storedAtA: Date,
                                      _ b: OpenMeteoResponse, storedAtB: Date) -> Bool {
        abs(storedAtA.timeIntervalSince(storedAtB)) <= pairStoredAtSlack
            && a.timezone == b.timezone
            && a.utcOffsetSeconds == b.utcOffsetSeconds
            && a.hourly?["time"] == b.hourly?["time"]
            && a.daily?["time"] == b.daily?["time"]
    }

    /// Content-only pair check (Form4b): timezone, utc offset, and hourly/daily `time` axes.
    /// No storedAt slack and no lat/lon (A and B may snap to different grids; location is keyA/keyB).
    public static func pairContentConsistent(_ a: OpenMeteoResponse, _ b: OpenMeteoResponse) -> Bool {
        a.timezone == b.timezone
            && a.utcOffsetSeconds == b.utcOffsetSeconds
            && a.hourly?["time"] == b.hourly?["time"]
            && a.daily?["time"] == b.daily?["time"]
    }

    /// Merge A+B into one response. lat/lon/elevation/timezone/utc_offset from A; `current`,
    /// `minutely_15`, and the 7 bare B columns from B (CR M2).
    public static func mergePair(a: OpenMeteoResponse, b: OpenMeteoResponse) -> OpenMeteoResponse {
        var hourly = a.hourly ?? [:]
        if let bt = b.hourly?["time"] { hourly["time"] = bt }
        for key in pairHourlyFromB {
            if let col = Self.column(b.hourly, key, .bestMatch) { hourly[key] = col }
        }
        var daily = a.daily ?? [:]
        if let bt = b.daily?["time"] { daily["time"] = bt }
        for key in pairDailyFromB {
            if let col = Self.column(b.daily, key, .bestMatch) { daily[key] = col }
        }
        return OpenMeteoResponse(
            latitude: a.latitude, longitude: a.longitude, timezone: a.timezone,
            utcOffsetSeconds: a.utcOffsetSeconds, elevation: a.elevation,
            current: b.current, hourly: hourly, daily: daily, minutely15: b.minutely15)
    }

    public init(latitude: Double, longitude: Double, timezone: String, utcOffsetSeconds: Int,
                elevation: Double? = nil, current: Current? = nil,
                hourly: [String: [Double?]]? = nil, daily: [String: [Double?]]? = nil,
                minutely15: [String: [Double?]]? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.timezone = timezone
        self.utcOffsetSeconds = utcOffsetSeconds; self.elevation = elevation
        self.current = current; self.hourly = hourly; self.daily = daily; self.minutely15 = minutely15
    }

    /// Split a multi-model fixture into A/B halves for golden-report / merge tests.
    public func splitPairHalves() -> (a: OpenMeteoResponse, b: OpenMeteoResponse) {
        let aHourlyKeys: Set<String> = [
            "temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation",
            "weather_code", "uv_index", "wind_speed_10m", "relative_humidity_2m", "dew_point_2m",
            "pressure_msl", "visibility", "wind_gusts_10m", "snowfall"
        ]
        let aDailyKeys: Set<String> = [
            "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max",
            "precipitation_sum", "snowfall_sum", "wind_speed_10m_max", "wind_gusts_10m_max"
        ]
        var aHourly: [String: [Double?]] = [:]
        if let hourly {
            for (k, v) in hourly {
                if k == "time" { aHourly[k] = v; continue }
                if aHourlyKeys.contains(Self.stripModelSuffix(k)) { aHourly[k] = v }
            }
        }
        var aDaily: [String: [Double?]] = [:]
        if let daily {
            for (k, v) in daily {
                if k == "time" { aDaily[k] = v; continue }
                if aDailyKeys.contains(Self.stripModelSuffix(k)) { aDaily[k] = v }
            }
        }
        let a = OpenMeteoResponse(latitude: latitude, longitude: longitude, timezone: timezone,
                                  utcOffsetSeconds: utcOffsetSeconds, elevation: elevation,
                                  current: nil, hourly: aHourly, daily: aDaily, minutely15: nil)
        var bHourly: [String: [Double?]] = ["time": hourly?["time"] ?? []]
        for key in Self.pairHourlyFromB {
            if let col = hourlyColumn(key, model: .bestMatch) { bHourly[key] = col }
        }
        var bDaily: [String: [Double?]] = ["time": daily?["time"] ?? []]
        for key in Self.pairDailyFromB {
            if let col = dailyColumn(key, model: .bestMatch) { bDaily[key] = col }
        }
        var bMinutely = minutely15
        if var m = bMinutely, m["precipitation"] == nil,
           let bm = Self.column(m, "precipitation", .bestMatch) {
            m["precipitation"] = bm
            // Drop per-model minutely columns — B is best_match only.
            bMinutely = ["time": m["time"] ?? [], "precipitation": bm]
        } else if let m = bMinutely {
            bMinutely = ["time": m["time"] ?? [],
                         "precipitation": m["precipitation"] ?? Self.column(m, "precipitation", .bestMatch) ?? []]
        }
        // Deliberately different lat/lon/elevation so merge-source tests prove A's win.
        let b = OpenMeteoResponse(latitude: latitude + 0.01, longitude: longitude + 0.01,
                                  timezone: timezone, utcOffsetSeconds: utcOffsetSeconds,
                                  elevation: (elevation ?? 0) + 10, current: current,
                                  hourly: bHourly, daily: bDaily, minutely15: bMinutely)
        return (a, b)
    }

    static func stripModelSuffix(_ key: String) -> String {
        for m in ForecastModel.allCases {
            let suffix = "_" + m.rawValue
            if key.hasSuffix(suffix) { return String(key.dropLast(suffix.count)) }
        }
        return key
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
        public var feature_code: String?
    }
    public var results: [Result]?

    public static func decode(_ data: Data) throws -> [PlaceSearchResult] {
        let r = try JSONDecoder().decode(OpenMeteoGeocodingResponse.self, from: data)
        return (r.results ?? []).map {
            PlaceSearchResult(id: $0.id, name: $0.name, admin1: $0.admin1, country: $0.country,
                              countryCode: $0.country_code,
                              coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude),
                              timeZoneIdentifier: $0.timezone, population: $0.population,
                              featureCode: $0.feature_code)
        }
    }
}
