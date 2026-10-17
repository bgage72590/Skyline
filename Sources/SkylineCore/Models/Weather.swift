import Foundation

// All values are stored in metric/SI-ish units (°C, km/h, mm, hPa, metres) and converted
// for display by `UnitPreference` at the edge. Every model is a value type and Sendable.

public struct CurrentConditions: Codable, Hashable, Sendable {
    public var time: Date
    public var temperature: Double          // °C
    public var apparentTemperature: Double  // °C
    public var humidity: Double             // %
    public var dewPoint: Double?            // °C
    public var weatherCode: Int             // WMO code
    public var isDay: Bool
    public var precipitation: Double        // mm in the last interval
    public var cloudCover: Double?          // %
    public var pressure: Double?            // hPa (MSL)
    public var windSpeed: Double            // km/h
    public var windDirection: Double?       // degrees (from)
    public var windGust: Double?            // km/h
    public var visibility: Double?          // metres
    public var uvIndex: Double?

    public init(time: Date, temperature: Double, apparentTemperature: Double, humidity: Double,
                dewPoint: Double?, weatherCode: Int, isDay: Bool, precipitation: Double,
                cloudCover: Double?, pressure: Double?, windSpeed: Double, windDirection: Double?,
                windGust: Double?, visibility: Double?, uvIndex: Double?) {
        self.time = time; self.temperature = temperature; self.apparentTemperature = apparentTemperature
        self.humidity = humidity; self.dewPoint = dewPoint; self.weatherCode = weatherCode
        self.isDay = isDay; self.precipitation = precipitation; self.cloudCover = cloudCover
        self.pressure = pressure; self.windSpeed = windSpeed; self.windDirection = windDirection
        self.windGust = windGust; self.visibility = visibility; self.uvIndex = uvIndex
    }

    public var condition: WeatherCondition { WeatherCondition(wmoCode: weatherCode) }
}

public struct HourlyForecast: Codable, Hashable, Identifiable, Sendable {
    public var time: Date
    public var temperature: Double               // °C (blended)
    public var apparentTemperature: Double?      // °C
    public var precipitationProbability: Double? // %
    public var precipitation: Double?            // mm
    public var weatherCode: Int
    public var isDay: Bool
    public var uvIndex: Double?
    public var windSpeed: Double?                // km/h
    public var windDirection: Double?
    public var humidity: Double?
    /// Max − min temperature across contributing sources (°C). Small = high confidence.
    public var temperatureSpread: Double?
    public var dewPoint: Double?                 // °C
    public var pressure: Double?                 // hPa
    public var visibility: Double?               // metres
    public var windGust: Double?                 // km/h
    /// Max − min rain chance across contributing sources (percentage points). Large = sources disagree
    /// on whether/when it rains (used for "Models disagree on rain timing", T11).
    public var precipitationProbabilitySpread: Double?
    /// Blended snowfall in the hour (cm of snow, Open-Meteo's unit; 7 cm ≈ 10 mm of water). T13.
    public var snowfall: Double?

    public var id: Date { time }
    public var condition: WeatherCondition { WeatherCondition(wmoCode: weatherCode) }

    public init(time: Date, temperature: Double, apparentTemperature: Double? = nil,
                precipitationProbability: Double? = nil, precipitation: Double? = nil,
                weatherCode: Int, isDay: Bool, uvIndex: Double? = nil, windSpeed: Double? = nil,
                windDirection: Double? = nil, humidity: Double? = nil, temperatureSpread: Double? = nil,
                dewPoint: Double? = nil, pressure: Double? = nil, visibility: Double? = nil,
                windGust: Double? = nil) {
        self.windGust = windGust
        self.time = time; self.temperature = temperature; self.apparentTemperature = apparentTemperature
        self.precipitationProbability = precipitationProbability; self.precipitation = precipitation
        self.weatherCode = weatherCode; self.isDay = isDay; self.uvIndex = uvIndex
        self.windSpeed = windSpeed; self.windDirection = windDirection; self.humidity = humidity
        self.temperatureSpread = temperatureSpread
        self.dewPoint = dewPoint; self.pressure = pressure; self.visibility = visibility
    }
}

/// One source's take on a day (shown in the Confidence detail).
public struct SourceReading: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var high: Double?
    public var low: Double?
    public var weight: Double
    /// Share (0…1) of the blended high / low this row carries, from the blend's own per-field dedupe:
    /// a NOAA-family row equal to another on that field only shares one vote (review L3). nil = not computed.
    public var highShare: Double?
    public var lowShare: Double?
    public var id: String { name }
    public init(name: String, high: Double?, low: Double?, weight: Double) {
        self.name = name; self.high = high; self.low = low; self.weight = weight
    }

    /// Per-field shares like the blend counts them. `family[i]`: row i is a NOAA-family forecast, whose
    /// equal values on a field are one vote (the largest weight counts, the rest 0).
    public static func withShares(_ rows: [SourceReading], family: [Bool]) -> [SourceReading] {
        var out = rows
        for field in [\SourceReading.high, \SourceReading.low] {
            var counted = rows.map { $0[keyPath: field] == nil ? 0 : $0.weight }
            var best: [Double: Int] = [:]
            for (i, r) in rows.enumerated() where family[i] {
                guard let v = r[keyPath: field] else { continue }
                if let j = best[v] {
                    if counted[i] > counted[j] { counted[j] = 0; best[v] = i } else { counted[i] = 0 }
                } else { best[v] = i }
            }
            let total = counted.reduce(0, +)
            for i in out.indices where rows[i][keyPath: field] != nil {
                let share = total > 0 ? counted[i] / total : 0
                if field == \SourceReading.high { out[i].highShare = share } else { out[i].lowShare = share }
            }
        }
        return out
    }
}

public struct DailyForecast: Codable, Hashable, Identifiable, Sendable {
    /// Local midnight of the forecast day.
    public var date: Date
    public var weatherCode: Int
    public var high: Double                       // °C (blended)
    public var low: Double                        // °C (blended)
    public var precipitationProbability: Double?  // %
    public var precipitationSum: Double?          // mm
    public var sunrise: Date?
    public var sunset: Date?
    public var uvIndexMax: Double?
    public var windSpeedMax: Double?              // km/h
    public var windGustMax: Double?               // km/h
    public var windDirectionDominant: Double?
    /// Official NWS text for the daytime period, when available.
    public var summary: String?
    /// Spread of the daily high across sources (°C).
    public var highSpread: Double?
    /// Per-source highs/lows that went into the blend.
    public var sources: [SourceReading] = []
    /// Blended snowfall for the day (cm of snow). T13.
    public var snowfallSum: Double?

    public var id: Date { date }
    /// Worth showing a snow total (≥ 0.5 cm, about 0.2 in).
    public var hasSnow: Bool { (snowfallSum ?? 0) >= 0.5 }
    public var condition: WeatherCondition { WeatherCondition(wmoCode: weatherCode) }

    public init(date: Date, weatherCode: Int, high: Double, low: Double,
                precipitationProbability: Double? = nil, precipitationSum: Double? = nil,
                sunrise: Date? = nil, sunset: Date? = nil, uvIndexMax: Double? = nil,
                windSpeedMax: Double? = nil, windGustMax: Double? = nil,
                windDirectionDominant: Double? = nil, summary: String? = nil, highSpread: Double? = nil) {
        self.date = date; self.weatherCode = weatherCode; self.high = high; self.low = low
        self.precipitationProbability = precipitationProbability; self.precipitationSum = precipitationSum
        self.sunrise = sunrise; self.sunset = sunset; self.uvIndexMax = uvIndexMax
        self.windSpeedMax = windSpeedMax; self.windGustMax = windGustMax
        self.windDirectionDominant = windDirectionDominant; self.summary = summary; self.highSpread = highSpread
    }

    /// Hours of `hourly` that fall on this day in `timeZone`.
    public func hours(from hourly: [HourlyForecast], timeZone: TimeZone) -> [HourlyForecast] {
        let end = date.addingTimeInterval(36 * 3600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return hourly.filter { $0.time >= date && $0.time < end && cal.isDate($0.time, inSameDayAs: date) }
    }
}

public struct MinutelyPrecipitation: Codable, Hashable, Sendable {
    public var time: Date
    public var precipitation: Double // mm per 15 min
    public init(time: Date, precipitation: Double) { self.time = time; self.precipitation = precipitation }
}

public enum AlertSeverity: String, Codable, Sendable, Comparable, CaseIterable {
    case unknown = "Unknown", minor = "Minor", moderate = "Moderate", severe = "Severe", extreme = "Extreme"

    private var rank: Int {
        switch self { case .unknown: 0; case .minor: 1; case .moderate: 2; case .severe: 3; case .extreme: 4 }
    }
    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool { lhs.rank < rhs.rank }
}

public struct WeatherAlert: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var event: String
    public var headline: String?
    public var severity: AlertSeverity
    public var urgency: String?
    public var areaDescription: String?
    public var description: String?
    public var instruction: String?
    public var effective: Date?
    public var expires: Date?
    public var ends: Date?
    public var senderName: String?
    /// Outline(s) of the warned area: storm-based polygons from the alert itself, or the affected
    /// forecast zones' shapes (filled in by `WeatherService`). Each ring is a list of coordinates.
    public var polygons: [[Coordinate]] = []
    /// NWS forecast-zone URLs, used to look up an outline when the alert has no polygon of its own.
    public var affectedZones: [URL] = []
    /// True when `polygons` are the affected forecast zones' outlines (filled in by `WeatherService`),
    /// not the alert's own storm-based polygon. Zone-based alerts already cover the queried point.
    public var outlineIsZone = false
    /// Ids of earlier messages this one updates or replaces (NWS `references`).
    public var references: [String] = []
    /// VTEC event keys still in force ("KOKX.FL.W.0006"): the same warning keeps its key across updates.
    public var trackingKeys: [String] = []
    /// A cancellation/expiry statement (it keeps the event name, e.g. "Tornado Warning").
    public var isCancellation = false

    public init(id: String, event: String, headline: String?, severity: AlertSeverity, urgency: String?,
                areaDescription: String?, description: String?, instruction: String?,
                effective: Date?, expires: Date?, ends: Date?, senderName: String?) {
        self.id = id; self.event = event; self.headline = headline; self.severity = severity
        self.urgency = urgency; self.areaDescription = areaDescription; self.description = description
        self.instruction = instruction; self.effective = effective; self.expires = expires
        self.ends = ends; self.senderName = senderName
    }

    /// When the hazard is over: `ends` if given, else when the message `expires`. Nil = open-ended.
    public var endTime: Date? { ends ?? expires }

    /// False once the alert has ended (an expired warning must never stay on screen), and for a
    /// cancellation/expiry statement (CAN/EXP): the warning it ends is over, so nothing shows it as
    /// active (banner, menu bar, sidebar, radar outline, briefing, widget, intents; QA batch 5 #1).
    public func isActive(at now: Date) -> Bool { !isCancellation && (endTime.map { $0 > now } ?? true) }

    enum CodingKeys: String, CodingKey {
        case id, event, headline, severity, urgency, areaDescription, description, instruction, effective, expires, ends,
             senderName, polygons, affectedZones, outlineIsZone, references, trackingKeys, isCancellation
    }

    /// Tolerant: fields added after batch 4 (references, tracking keys, cancellation, outlines) default
    /// when missing, so an older cached alert still decodes (QA batch 5 #4).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        event = try c.decode(String.self, forKey: .event)
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        severity = (try? c.decodeIfPresent(AlertSeverity.self, forKey: .severity)) ?? .unknown
        urgency = try c.decodeIfPresent(String.self, forKey: .urgency)
        areaDescription = try c.decodeIfPresent(String.self, forKey: .areaDescription)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        effective = try c.decodeIfPresent(Date.self, forKey: .effective)
        expires = try c.decodeIfPresent(Date.self, forKey: .expires)
        ends = try c.decodeIfPresent(Date.self, forKey: .ends)
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName)
        polygons = (try? c.decodeIfPresent([[Coordinate]].self, forKey: .polygons)) ?? []
        affectedZones = (try? c.decodeIfPresent([URL].self, forKey: .affectedZones)) ?? []
        outlineIsZone = (try? c.decodeIfPresent(Bool.self, forKey: .outlineIsZone)) ?? false
        references = (try? c.decodeIfPresent([String].self, forKey: .references)) ?? []
        trackingKeys = (try? c.decodeIfPresent([String].self, forKey: .trackingKeys)) ?? []
        isCancellation = (try? c.decodeIfPresent(Bool.self, forKey: .isCancellation)) ?? false
    }
}

/// One timestamped value of an hourly series (AQI forecast etc.).
public struct HourlyValue: Codable, Hashable, Sendable, Identifiable {
    public var time: Date
    public var value: Double
    public var id: Date { time }
    public init(time: Date, value: Double) { self.time = time; self.value = value }
}

public struct AirQuality: Codable, Hashable, Sendable {
    public var usAQI: Int
    public var pm25: Double?
    public var pm10: Double?
    public var ozone: Double?
    /// Hourly US AQI forecast (next ~2 days), when available.
    public var hourly: [HourlyValue] = []

    public init(usAQI: Int, pm25: Double?, pm10: Double?, ozone: Double?) {
        self.usAQI = usAQI; self.pm25 = pm25; self.pm10 = pm10; self.ozone = ozone
    }

    public var category: String { Self.category(usAQI) }

    public static func category(_ usAQI: Int) -> String {
        switch usAQI {
        case ..<51: "Good"
        case ..<101: "Moderate"
        case ..<151: "Unhealthy for Sensitive Groups"
        case ..<201: "Unhealthy"
        case ..<301: "Very Unhealthy"
        default: "Hazardous"
        }
    }
}

/// Everything the UI needs for one location, produced by `WeatherService`.
public struct WeatherReport: Codable, Hashable, Sendable {
    public var location: WeatherLocation
    public var fetchedAt: Date
    public var timeZoneIdentifier: String
    public var current: CurrentConditions
    public var hourly: [HourlyForecast]
    public var daily: [DailyForecast]
    public var minutely: [MinutelyPrecipitation]
    public var alerts: [WeatherAlert]
    public var airQuality: AirQuality?
    /// Human-readable list of data sources that contributed.
    public var sources: [String]
    /// NWS forecast office / city label when NWS contributed.
    public var nwsOffice: String?
    /// When the forecast data was actually downloaded (the oldest forecast input). Differs from
    /// `fetchedAt` (when this report was assembled) whenever cached data was used.
    public var dataAsOf: Date
    /// True when the network failed and the forecast came from Skyline's offline cache.
    public var isOfflineFallback: Bool
    /// When the primary (Open-Meteo) forecast was downloaded; nil in reports saved by older builds.
    public var forecastAsOf: Date?
    /// NWS forecast office (e.g. "OKX") when the location is in NWS coverage; used for Forecaster's notes.
    public var nwsGridID: String?
    /// The forecast Skyline showed for this place about 12 h earlier (for "why the forecast changed", T11).
    public var earlierOutlook: ForecastSnapshot?
    /// SPC convective outlooks covering the place (Day 1 / Day 2, marginal risk or higher; US only). L20.
    public var severeOutlooks: [SevereOutlook] = []
    /// Each model's hourly temperature next to the blend, for the model comparison chart (L18).
    public var modelSeries: [ModelSeries] = []

    public init(location: WeatherLocation, fetchedAt: Date, timeZoneIdentifier: String,
                current: CurrentConditions, hourly: [HourlyForecast], daily: [DailyForecast],
                minutely: [MinutelyPrecipitation] = [], alerts: [WeatherAlert] = [],
                airQuality: AirQuality? = nil, sources: [String] = [], nwsOffice: String? = nil,
                dataAsOf: Date? = nil, isOfflineFallback: Bool = false) {
        self.location = location; self.fetchedAt = fetchedAt; self.timeZoneIdentifier = timeZoneIdentifier
        self.current = current; self.hourly = hourly; self.daily = daily; self.minutely = minutely
        self.alerts = alerts; self.airQuality = airQuality; self.sources = sources; self.nwsOffice = nwsOffice
        self.dataAsOf = dataAsOf ?? fetchedAt; self.isOfflineFallback = isOfflineFallback
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// How old the forecast data is at `now` (seconds).
    public func dataAge(at now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(dataAsOf)) }

    /// Alerts that haven't ended yet at `now` (display-time filter; the parser already drops ended ones).
    public func activeAlerts(at now: Date = Date()) -> [WeatherAlert] { alerts.filter { $0.isActive(at: now) } }

    /// Hourly entries from the current hour onward.
    public func upcomingHours(from now: Date = Date(), count: Int = 24) -> [HourlyForecast] {
        let start = now.addingTimeInterval(-3600)
        return Array(hourly.filter { $0.time > start }.prefix(count))
    }

    public var today: DailyForecast? { daily.first }

    /// Short nowcast like "Rain stopping in about 30 min", from 15-minute data.
    public var nowcastSummary: String? { nowcastSummary(at: current.time) }
    /// The nowcast line as of `now` (the briefing notification passes the real time, like the rain
    /// notification does, so the two give the same start time).
    public func nowcastSummary(at now: Date) -> String? {
        Nowcast.summary(minutely, now: now, temperature: current.temperature)
    }
}

/// A geocoding search result.
public struct PlaceSearchResult: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var admin1: String?
    public var country: String?
    public var countryCode: String?
    public var coordinate: Coordinate
    public var timeZoneIdentifier: String?
    public var population: Int?
    /// GeoNames feature code ("PPLA2" city, "AIRP" airport, "PCLI"/"PCLIX" country…), when given.
    public var featureCode: String?

    public init(id: Int, name: String, admin1: String?, country: String?, countryCode: String?,
                coordinate: Coordinate, timeZoneIdentifier: String?, population: Int?, featureCode: String? = nil) {
        self.id = id; self.name = name; self.admin1 = admin1; self.country = country
        self.countryCode = countryCode; self.coordinate = coordinate
        self.timeZoneIdentifier = timeZoneIdentifier; self.population = population
        self.featureCode = featureCode
    }

    public var isAirport: Bool { featureCode.map { $0 == "AIRP" || $0 == "AIRF" } ?? false }
    /// A whole country or dependency (PCL*), or a first-order division of one: never a "city".
    public var isCountryLevel: Bool { featureCode.map { $0.hasPrefix("PCL") || $0 == "TERR" || $0 == "ADM0" } ?? false }

    /// "Airport · Sint Maarten", "New York, United States", "Country".
    public var subtitle: String {
        let place = [admin1, country ?? countryCode.flatMap { Locale(identifier: "en_US").localizedString(forRegionCode: $0) }]
            .compactMap { $0 }.joined(separator: ", ")
        let kind = isAirport ? "Airport" : (isCountryLevel ? "Country or territory" : nil)
        return [kind, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: " · ")
    }

    public var asLocation: WeatherLocation {
        WeatherLocation(name: name, region: admin1, country: country, coordinate: coordinate,
                        timeZoneIdentifier: timeZoneIdentifier, countryCode: countryCode)
    }
}
