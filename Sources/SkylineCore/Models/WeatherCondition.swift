import Foundation

/// Broad visual category used to pick backgrounds and symbols.
public enum SkyCategory: String, Codable, Sendable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, thunderstorm
}

/// Maps WMO weather interpretation codes (used by Open-Meteo) to text and SF Symbols.
public struct WeatherCondition: Hashable, Sendable {
    public let wmoCode: Int

    public init(wmoCode: Int) { self.wmoCode = wmoCode }

    public var category: SkyCategory {
        switch wmoCode {
        case 0, 1: .clear
        case 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .fog
        case 51...57: .drizzle
        case 61...67, 80...82: .rain
        case 71...77, 85, 86: .snow
        case 95...99: .thunderstorm
        default: .cloudy
        }
    }

    public var description: String {
        switch wmoCode {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45: "Fog"
        case 48: "Freezing Fog"
        case 51: "Light Drizzle"
        case 53: "Drizzle"
        case 55: "Heavy Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61: "Light Rain"
        case 63: "Rain"
        case 65: "Heavy Rain"
        case 66, 67: "Freezing Rain"
        case 71: "Light Snow"
        case 73: "Snow"
        case 75: "Heavy Snow"
        case 77: "Snow Grains"
        case 80: "Light Showers"
        case 81: "Showers"
        case 82: "Heavy Showers"
        case 85: "Snow Showers"
        case 86: "Heavy Snow Showers"
        case 95: "Thunderstorms"
        case 96, 99: "Thunderstorms with Hail"
        default: "Unknown"
        }
    }

    /// SF Symbol name (multicolor-friendly) for this condition.
    public func symbolName(isDay: Bool) -> String {
        switch wmoCode {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: isDay ? "sun.max.fill" : "moon.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81, 82: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95: "cloud.bolt.rain.fill"
        case 96, 99: "cloud.bolt.fill"
        default: "cloud.fill"
        }
    }

    public var isPrecipitation: Bool {
        switch category {
        case .drizzle, .rain, .snow, .thunderstorm: true
        default: false
        }
    }
}
