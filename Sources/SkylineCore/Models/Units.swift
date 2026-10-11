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
    /// Whether values are shown in US customary units.
    public var isImperialDisplay: Bool { isImperial }

    public func temperature(_ celsius: Double) -> Double {
        isImperial ? celsius * 9 / 5 + 32 : celsius
    }

    /// Rounded temperature with a degree sign, e.g. "62°".
    public func temperatureString(_ celsius: Double?) -> String {
        guard let celsius else { return "--" }
        let v = Int(temperature(celsius).rounded())
        return "\(v)°"
    }

    /// Converts a temperature *difference*.
    public func temperatureDelta(_ celsius: Double) -> Double { isImperial ? celsius * 9 / 5 : celsius }

    public func speed(_ kmh: Double) -> Double { isImperial ? kmh / 1.609344 : kmh }
    public var speedUnit: String { isImperial ? "mph" : "km/h" }
    public func speedString(_ kmh: Double?) -> String {
        guard let kmh else { return "--" }
        return "\(Int(speed(kmh).rounded())) \(speedUnit)"
    }

    public func precipitation(_ mm: Double) -> Double { isImperial ? mm / 25.4 : mm }
    public var precipitationUnit: String { isImperial ? "in" : "mm" }
    public func precipitationString(_ mm: Double?) -> String {
        guard let mm else { return "--" }
        let v = precipitation(mm)
        return isImperial ? String(format: "%.2f\"", v) : String(format: "%.1f mm", v)
    }

    public func distance(_ metres: Double) -> Double { isImperial ? metres / 1609.344 : metres / 1000 }
    public var distanceUnit: String { isImperial ? "mi" : "km" }
    public func visibilityString(_ metres: Double?) -> String {
        guard let metres else { return "--" }
        let v = distance(metres)
        return v >= 10 ? "\(Int(v.rounded())) \(distanceUnit)" : String(format: "%.1f %@", v, distanceUnit)
    }

    public func pressureString(_ hPa: Double?) -> String {
        guard let hPa else { return "--" }
        return isImperial ? String(format: "%.2f inHg", hPa * 0.0295299830714) : "\(Int(hPa.rounded())) hPa"
    }
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
