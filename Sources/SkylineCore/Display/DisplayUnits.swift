import Foundation

// Per-dimension display units (T20): the old single preset (System / imperial / metric) still picks the
// defaults, and each dimension can be overridden, e.g. °F with hPa. Internal values stay metric
// (°C, km/h, mm, hPa, metres).

public enum TemperatureUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case fahrenheit, celsius
    public var id: String { rawValue }
    public var label: String { self == .fahrenheit ? "°F" : "°C" }
}

public enum SpeedUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case mph, kmh, metresPerSecond, knots
    public var id: String { rawValue }
    public var label: String {
        switch self { case .mph: "mph"; case .kmh: "km/h"; case .metresPerSecond: "m/s"; case .knots: "kn" }
    }
}

public enum PrecipitationUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case inches, millimetres
    public var id: String { rawValue }
    public var label: String { self == .inches ? "in" : "mm" }
}

public enum PressureUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case inHg, hPa
    public var id: String { rawValue }
    public var label: String { self == .inHg ? "inHg" : "hPa" }
}

public enum DistanceUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case miles, kilometres
    public var id: String { rawValue }
    public var label: String { self == .miles ? "mi" : "km" }
}

/// The units every view formats with. Built from a preset plus optional per-dimension overrides.
public struct DisplayUnits: Codable, Hashable, Sendable {
    public var temperature: TemperatureUnit
    public var speed: SpeedUnit
    public var precipitation: PrecipitationUnit
    public var pressure: PressureUnit
    public var distance: DistanceUnit

    public init(temperature: TemperatureUnit, speed: SpeedUnit, precipitation: PrecipitationUnit,
                pressure: PressureUnit, distance: DistanceUnit) {
        self.temperature = temperature; self.speed = speed; self.precipitation = precipitation
        self.pressure = pressure; self.distance = distance
    }

    public static let imperial = DisplayUnits(temperature: .fahrenheit, speed: .mph, precipitation: .inches,
                                              pressure: .inHg, distance: .miles)
    public static let metric = DisplayUnits(temperature: .celsius, speed: .kmh, precipitation: .millimetres,
                                            pressure: .hPa, distance: .kilometres)

    /// The preset's units with any overrides applied (nil = follow the preset).
    public init(preset: UnitPreference, locale: Locale = .current, temperature: TemperatureUnit? = nil,
                speed: SpeedUnit? = nil, precipitation: PrecipitationUnit? = nil, pressure: PressureUnit? = nil,
                distance: DistanceUnit? = nil) {
        var base = preset.resolved(locale: locale) == .imperial ? Self.imperial : Self.metric
        if let temperature { base.temperature = temperature }
        if let speed { base.speed = speed }
        if let precipitation { base.precipitation = precipitation }
        if let pressure { base.pressure = pressure }
        if let distance { base.distance = distance }
        self = base
    }

    // MARK: Temperature

    public func temperature(_ celsius: Double) -> Double {
        temperature == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    /// Rounded temperature with a degree sign, e.g. "62°".
    public func temperatureString(_ celsius: Double?) -> String {
        guard let celsius else { return "--" }
        return "\(Int(temperature(celsius).rounded()))°"
    }

    /// Converts a temperature *difference*.
    public func temperatureDelta(_ celsius: Double) -> Double { temperature == .fahrenheit ? celsius * 9 / 5 : celsius }

    // MARK: Wind

    public func speed(_ kmh: Double) -> Double {
        switch speed {
        case .mph: kmh / 1.609344
        case .kmh: kmh
        case .metresPerSecond: kmh / 3.6
        case .knots: kmh / 1.852
        }
    }
    public var speedUnit: String { speed.label }
    public func speedString(_ kmh: Double?) -> String {
        guard let kmh else { return "--" }
        return "\(Int(speed(kmh).rounded())) \(speedUnit)"
    }

    // MARK: Precipitation

    public func precipitation(_ mm: Double) -> Double { precipitation == .inches ? mm / 25.4 : mm }
    public var precipitationUnit: String { precipitation.label }
    public func precipitationString(_ mm: Double?) -> String {
        guard let mm else { return "--" }
        let v = precipitation(mm)
        return precipitation == .inches ? String(format: "%.2f\"", v) : String(format: "%.1f mm", v)
    }

    /// Snow depth from cm of snowfall: inches with the inch/imperial setting, else cm.
    /// "0.4 in" / "3 in" / "1.5 cm" / "12 cm" (whole units from 1 in or 10 cm up).
    public func snowString(_ cm: Double?) -> String {
        guard let cm else { return "--" }
        if precipitation == .inches {
            let inches = cm / 2.54
            return inches < 1 ? String(format: "%.1f in", inches) : "\(Int(inches.rounded())) in"
        }
        return cm < 10 ? String(format: "%.1f cm", cm) : "\(Int(cm.rounded())) cm"
    }

    // MARK: Distance

    public func distance(_ metres: Double) -> Double { distance == .miles ? metres / 1609.344 : metres / 1000 }
    public var distanceUnit: String { distance.label }
    public func visibilityString(_ metres: Double?) -> String {
        guard let metres else { return "--" }
        let v = distance(metres)
        return v >= 10 ? "\(Int(v.rounded())) \(distanceUnit)" : String(format: "%.1f %@", v, distanceUnit)
    }

    // MARK: Pressure

    public func pressure(_ hPa: Double) -> Double { pressure == .inHg ? hPa * 0.0295299830714 : hPa }
    public var pressureUnit: String { pressure.label }
    /// The number alone: "29.92" or "1013".
    public func pressureNumber(_ hPa: Double) -> String {
        pressure == .inHg ? String(format: "%.2f", pressure(hPa)) : "\(Int(hPa.rounded()))"
    }
    public func pressureString(_ hPa: Double?) -> String {
        guard let hPa else { return "--" }
        return pressureNumber(hPa) + " " + pressureUnit
    }
    /// A sensible chart step for pressure in these units.
    public var pressureStep: Double { pressure == .inHg ? 0.2 : 6 }
}

/// 12- or 24-hour clock for every time Skyline shows (T20). `.system` follows the Mac's setting.
public enum ClockStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, twelveHour, twentyFourHour
    public var id: String { rawValue }

    public var label: String {
        switch self { case .system: "System"; case .twelveHour: "12-hour"; case .twentyFourHour: "24-hour" }
    }

    /// Rewrites a date-format template's hour symbol: "j" (locale's choice) becomes "h" (12-hour) or "H"
    /// (24-hour); other fields are untouched. Explicit "h"/"H" in the template are rewritten too.
    public func template(_ template: String) -> String {
        switch self {
        case .system: return template
        case .twelveHour: return String(template.map { $0 == "j" || $0 == "H" ? "h" : $0 })
        case .twentyFourHour: return String(template.map { $0 == "j" || $0 == "h" ? "H" : $0 })
        }
    }
}

extension UnitPreference {
    /// The preset's full set of units (no overrides).
    public var units: DisplayUnits { DisplayUnits(preset: self) }
}
