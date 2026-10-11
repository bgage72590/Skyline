import Foundation

/// Display unit preference. Internal values are always metric.
public enum UnitPreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, imperial, metric
    public var id: String { rawValue }

    public var label: String {
        switch self { case .system: "System"; case .imperial: "°F, mph, in"; case .metric: "°C, km/h, mm" }
    }

    /// Resolves `.system` against a locale.
    public func resolved(locale: Locale = .current) -> UnitPreference {
        guard self == .system else { return self }
        #if canImport(Darwin)
        return locale.measurementSystem == .us ? .imperial : .metric
        #else
        let region = locale.identifier.split(separator: "_").last.map(String.init) ?? ""
        return ["US", "LR", "MM"].contains(region) ? .imperial : .metric
        #endif
    }

    var isImperial: Bool { resolved() == .imperial }

    // Formatting goes through `DisplayUnits` (per-dimension units); these keep the preset shorthand.
    public func temperatureString(_ celsius: Double?) -> String { units.temperatureString(celsius) }
    public func speedString(_ kmh: Double?) -> String { units.speedString(kmh) }
    public func precipitationString(_ mm: Double?) -> String { units.precipitationString(mm) }
    public func visibilityString(_ metres: Double?) -> String { units.visibilityString(metres) }
    public func pressureString(_ hPa: Double?) -> String { units.pressureString(hPa) }
}

public enum Compass {
    /// 16-point compass abbreviation for a bearing in degrees.
    public static func abbreviation(_ degrees: Double?) -> String {
        guard let degrees else { return "--" }
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized / 22.5).rounded()) % 16]
    }

    /// Parses NWS-style direction strings ("NNE") into degrees.
    public static func degrees(_ abbreviation: String) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard let i = points.firstIndex(of: abbreviation.uppercased()) else { return nil }
        return Double(i) * 22.5
    }
}

public enum UVScale {
    public static func category(_ uv: Double?) -> String {
        guard let uv else { return "--" }
        switch uv {
        case ..<3: return "Low"
        case ..<6: return "Moderate"
        case ..<8: return "High"
        case ..<11: return "Very High"
        default: return "Extreme"
        }
    }
}
