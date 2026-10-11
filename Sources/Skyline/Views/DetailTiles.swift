import SwiftUI
import SkylineCore

struct DetailTilesGrid: View {
    let report: WeatherReport
    let units: UnitPreference

    private let columns = [GridItem(.adaptive(minimum: 175), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            UVTile(report: report)
            SunTile(report: report)
            WindTile(report: report, units: units)
            PrecipitationTile(report: report, units: units)
            FeelsLikeTile(report: report, units: units)
            HumidityTile(report: report, units: units)
            VisibilityTile(report: report, units: units)
            PressureTile(report: report, units: units)
            if let aq = report.airQuality { AirQualityTile(airQuality: aq) }
            ConfidenceTile(report: report, units: units)
        }
    }
}

struct UVTile: View {
    let report: WeatherReport
    var body: some View {
        let uv = report.current.uvIndex ?? 0
        Tile(title: "UV Index", systemImage: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 6) {
                TileValue(value: "\(Int(uv.rounded()))", label: UVScale.category(uv))
                ScaleBar(fraction: uv / 11, colors: [.green, .yellow, .orange, .red, .purple])
                if let max = report.today?.uvIndexMax {
                    Text("Today’s max: \(Int(max.rounded())) (\(UVScale.category(max)))").font(.caption).opacity(0.85)
                }
            }
        }
    }
}

struct SunTile: View {
    let report: WeatherReport
    var body: some View {
        let now = Date()
        let tz = report.timeZone
        let today = report.daily.first
        let tomorrow = report.daily.dropFirst().first
        let next: (String, Date?, String, Date?) = {
            if let rise = today?.sunrise, now < rise { return ("Sunrise", rise, "Sunset", today?.sunset) }
            if let set = today?.sunset, now < set { return ("Sunset", set, "Sunrise", tomorrow?.sunrise) }
            return ("Sunrise", tomorrow?.sunrise, "Sunset", tomorrow?.sunset)
        }()
        Tile(title: next.0, systemImage: next.0 == "Sunrise" ? "sunrise.fill" : "sunset.fill") {
            TileValue(value: next.1.map { Fmt.time($0, tz) } ?? "--",
                      detail: next.3.map { "\(next.2): \(Fmt.time($0, tz))" } ?? daylightText(today))
        }
    }

    private func daylightText(_ day: DailyForecast?) -> String? {
        guard let rise = day?.sunrise, let set = day?.sunset else { return nil }
        let minutes = Int(set.timeIntervalSince(rise) / 60)
        return "Daylight: \(minutes / 60)h \(minutes % 60)m"
    }
}

struct WindTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let c = report.current
        Tile(title: "Wind", systemImage: "wind") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Int(units.speed(c.windSpeed).rounded()))")
                        .font(.system(size: 30, weight: .medium))
                    Text(units.speedUnit).font(.headline)
                    Spacer(minLength: 0)
                    if let gust = c.windGust {
                        Text("Gusts \(units.speedString(gust))").font(.caption).opacity(0.85)
                    }
                    Text("From \(Compass.abbreviation(c.windDirection))").font(.caption).opacity(0.85)
                }
                Spacer(minLength: 0)
                CompassView(degrees: c.windDirection)
            }
        }
    }
}

struct PrecipitationTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let next24 = report.upcomingHours(count: 24).compactMap(\.precipitation).reduce(0, +)
        let chance = report.today?.precipitationProbability
        Tile(title: "Precipitation", systemImage: "drop.fill") {
            TileValue(value: units.precipitationString(next24),
                      label: "Next 24h",
                      detail: report.nowcastSummary
                        ?? chance.map { "\(Int($0.rounded()))% chance today." }
                        ?? "No precipitation expected.")
        }
    }
}

struct FeelsLikeTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let c = report.current
        let delta = c.apparentTemperature - c.temperature
        let detail: String = {
            if abs(delta) < 1.5 { return "Similar to the actual temperature." }
            if delta < 0 { return c.windSpeed > 10 ? "Wind is making it feel colder." : "It feels colder than the actual temperature." }
            return c.humidity > 60 ? "Humidity is making it feel warmer." : "It feels warmer than the actual temperature."
        }()
        Tile(title: "Feels Like", systemImage: "thermometer.medium") {
            TileValue(value: units.temperatureString(c.apparentTemperature),
                      detail: detail)
        }
    }
}

struct HumidityTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let c = report.current
        Tile(title: "Humidity", systemImage: "humidity.fill") {
            TileValue(value: "\(Int(c.humidity.rounded()))%",
                      detail: c.dewPoint.map { "The dew point is \(units.temperatureString($0)) right now." })
        }
    }
}

struct VisibilityTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let v = report.current.visibility
        let detail: String = {
            guard let v else { return "" }
            switch v {
            case 16_000...: return "Perfectly clear view."
            case 8_000..<16_000: return "Mostly clear view."
            case 2_000..<8_000: return "Haze or precipitation is reducing visibility."
            default: return "Fog or heavy precipitation is limiting visibility."
            }
        }()
        Tile(title: "Visibility", systemImage: "eye.fill") {
            TileValue(value: units.visibilityString(v), detail: detail)
        }
    }
}

struct PressureTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let p = report.current.pressure
        let detail: String = {
            guard let p else { return "" }
            if p < 1005 { return "Low pressure: unsettled weather is likely." }
            if p > 1022 { return "High pressure: settled weather is likely." }
            return "Near-normal pressure."
        }()
        Tile(title: "Pressure", systemImage: "gauge.with.dots.needle.33percent") {
            TileValue(value: units.pressureString(p), detail: detail)
        }
    }
}

struct AirQualityTile: View {
    let airQuality: AirQuality
    var body: some View {
        Tile(title: "Air Quality", systemImage: "aqi.medium") {
            VStack(alignment: .leading, spacing: 6) {
                TileValue(value: "\(airQuality.usAQI)", label: airQuality.category)
                ScaleBar(fraction: Double(airQuality.usAQI) / 300,
                         colors: [.green, .yellow, .orange, .red, .purple, Color(red: 0.5, green: 0, blue: 0.15)])
                if let pm = airQuality.pm25 {
                    Text("PM2.5: \(Int(pm.rounded())) µg/m³").font(.caption).opacity(0.85)
                }
            }
        }
    }
}

/// Skyline-only: how much the sources agree, so you know how much to trust the forecast.
struct ConfidenceTile: View {
    let report: WeatherReport
    let units: UnitPreference
    var body: some View {
        let spread = report.today?.highSpread
        let level: String = {
            guard let spread else { return "—" }
            if spread <= 2 { return "High" }
            if spread <= 4 { return "Medium" }
            return "Low"
        }()
        Tile(title: "Confidence", systemImage: "checkmark.seal.fill") {
            TileValue(value: level,
                      label: spread.map { "Sources agree within ±\(Int((units.temperatureDelta($0) / 2).rounded()))°" },
                      detail: "\(report.sources.count) sources blended")
        }
    }
}
