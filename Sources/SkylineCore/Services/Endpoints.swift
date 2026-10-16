import Foundation

/// URL builders for every free API Skyline uses. None require keys.
public enum Endpoints {
    static let hourlyVars = "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,is_day,uv_index,wind_speed_10m,wind_direction_10m,relative_humidity_2m,dew_point_2m,pressure_msl,visibility,wind_gusts_10m,snowfall"
    static let dailyVars = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,snowfall_sum,sunrise,sunset,uv_index_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant"
    static let currentVars = "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility,uv_index,dew_point_2m"

    public static func openMeteoForecast(_ c: Coordinate, models: [ForecastModel]) -> URL {
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", c.longitude)),
            .init(name: "current", value: currentVars),
            .init(name: "hourly", value: hourlyVars),
            .init(name: "daily", value: dailyVars),
            .init(name: "minutely_15", value: "precipitation"),
            .init(name: "forecast_minutely_15", value: "8"),
            .init(name: "models", value: models.map(\.rawValue).joined(separator: ",")),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "10"),
            .init(name: "wind_speed_unit", value: "kmh"),
        ]
        return u.url!
    }

    public static func openMeteoAirQuality(_ c: Coordinate) -> URL {
        var u = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        u.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", c.longitude)),
            .init(name: "current", value: "us_aqi,pm2_5,pm10,ozone"),
            .init(name: "hourly", value: "us_aqi"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto"),
        ]
        return u.url!
    }

    public static func geocoding(_ query: String, count: Int = 8) -> URL {
        var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        u.queryItems = [
            .init(name: "name", value: query),
            .init(name: "count", value: String(count)),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        return u.url!
    }

    public static func nwsPoint(_ c: Coordinate) -> URL {
        URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f", c.latitude, c.longitude))!
    }

    /// Forecast-zone metadata incl. its outline geometry (e.g. https://api.weather.gov/zones/forecast/NYZ072).
    public static func nwsZone(_ url: URL) -> URL? {
        guard url.host == "api.weather.gov" else { return nil }
        return url
    }

    public static func nwsAlerts(_ c: Coordinate) -> URL {
        URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", c.latitude, c.longitude))!
    }

    /// Latest Area Forecast Discussions issued by an NWS office (e.g. "OKX").
    public static func nwsAFDList(office: String) -> URL? {
        guard office.count <= 4, office.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return URL(string: "https://api.weather.gov/products/types/AFD/locations/\(office.uppercased())")
    }

    /// One NWS text product by id.
    public static func nwsProduct(id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return URL(string: "https://api.weather.gov/products/\(id)")
    }

    /// SPC categorical convective outlook (GeoJSON), day 1 or 2.
    public static func spcOutlook(day: Int) -> URL {
        URL(string: "https://www.spc.noaa.gov/products/outlook/day\(day)otlk_cat.lyr.geojson")!
    }
    /// Run time of the newest HRRR on IEM (future radar; REFP precip-type product).
    public static let iemHRRRLatest = URL(string: "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refp_0000.json")!

    public static let rainViewerMaps = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
    public static let iemLatest = URL(string: "https://mesonet.agron.iastate.edu/data/gis/images/4326/USCOMP/n0q_0.json")!
    /// Latest NEXRAD storm attributes (GeoJSON) for storm-motion arrows.
    public static let iemNexradAttr = URL(string: "https://mesonet.agron.iastate.edu/geojson/nexrad_attr.py")!
}
