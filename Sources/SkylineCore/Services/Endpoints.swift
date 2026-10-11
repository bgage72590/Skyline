import Foundation

/// URL builders for every free API Skyline uses. None require keys.
public enum Endpoints {
    static let hourlyVars = "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,is_day,uv_index,wind_speed_10m,wind_direction_10m,relative_humidity_2m"
    static let dailyVars = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,precipitation_sum,sunrise,sunset,uv_index_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant"
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

    public static func nwsAlerts(_ c: Coordinate) -> URL {
        URL(string: String(format: "https://api.weather.gov/alerts/active?point=%.4f,%.4f", c.latitude, c.longitude))!
    }

    public static let rainViewerMaps = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
    public static let iemLatest = URL(string: "https://mesonet.agron.iastate.edu/data/gis/images/4326/USCOMP/n0q_0.json")!
}
