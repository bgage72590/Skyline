import Foundation
import SwiftUI
import SkylineCore

/// Cached, timezone-aware date formatting (DateFormatter creation is expensive).
@MainActor
enum Fmt {
    private static var cache: [String: DateFormatter] = [:]

    static func string(_ date: Date, template: String, timeZone: TimeZone) -> String {
        let key = template + "|" + timeZone.identifier
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(template)
            formatter.timeZone = timeZone
            cache[key] = formatter
        }
        return formatter.string(from: date)
    }

    /// "3 PM" / "15"
    static func hour(_ date: Date, _ tz: TimeZone) -> String { string(date, template: "j", timeZone: tz) }
    /// "3:42 PM"
    static func time(_ date: Date, _ tz: TimeZone) -> String { string(date, template: "jmm", timeZone: tz) }
    /// "Mon"
    static func weekday(_ date: Date, _ tz: TimeZone) -> String { string(date, template: "EEE", timeZone: tz) }
    /// "Mon 3:42 PM"
    static func dayTime(_ date: Date, _ tz: TimeZone) -> String { string(date, template: "EEEjmm", timeZone: tz) }
    /// "2:10 PM" today, else "Sat 2:10 PM" (Mac's time zone): when shown data was downloaded.
    static func dataTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time(date, .current) : dayTime(date, .current)
    }
}

/// Apple-Weather-like sky gradients. Static (no animation) to keep the GPU idle.
enum SkyPalette {
    static func colors(_ category: SkyCategory, isDay: Bool) -> [Color] {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch (category, isDay) {
        case (.clear, true): return [c(0.19, 0.46, 0.86), c(0.42, 0.70, 0.97)]
        case (.clear, false): return [c(0.03, 0.06, 0.19), c(0.14, 0.20, 0.40)]
        case (.partlyCloudy, true): return [c(0.27, 0.50, 0.80), c(0.56, 0.71, 0.88)]
        case (.partlyCloudy, false): return [c(0.07, 0.10, 0.22), c(0.22, 0.27, 0.42)]
        case (.cloudy, true): return [c(0.40, 0.48, 0.58), c(0.62, 0.68, 0.76)]
        case (.cloudy, false): return [c(0.12, 0.15, 0.21), c(0.27, 0.31, 0.38)]
        case (.fog, true): return [c(0.50, 0.53, 0.58), c(0.71, 0.73, 0.76)]
        case (.fog, false): return [c(0.18, 0.19, 0.22), c(0.33, 0.35, 0.38)]
        case (.drizzle, true), (.rain, true): return [c(0.25, 0.33, 0.45), c(0.45, 0.53, 0.63)]
        case (.drizzle, false), (.rain, false): return [c(0.07, 0.10, 0.16), c(0.20, 0.25, 0.33)]
        case (.snow, true): return [c(0.52, 0.60, 0.73), c(0.78, 0.83, 0.90)]
        case (.snow, false): return [c(0.16, 0.19, 0.27), c(0.33, 0.37, 0.46)]
        case (.thunderstorm, _): return [c(0.15, 0.15, 0.25), c(0.32, 0.29, 0.41)]
        }
    }

    static func gradient(_ category: SkyCategory, isDay: Bool) -> LinearGradient {
        LinearGradient(colors: colors(category, isDay: isDay), startPoint: .top, endPoint: .bottom)
    }

    static func gradient(for report: WeatherReport?) -> LinearGradient {
        gradient(report?.current.condition.category ?? .partlyCloudy, isDay: report?.current.isDay ?? true)
    }
}

enum TemperatureColors {
    /// Blue → teal → green → yellow → orange → red across roughly −10…38 °C.
    static func color(_ celsius: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (-10, (0.35, 0.45, 1.00)), (0, (0.30, 0.70, 1.00)), (10, (0.30, 0.85, 0.75)),
            (18, (0.55, 0.90, 0.35)), (24, (1.00, 0.85, 0.25)), (30, (1.00, 0.58, 0.20)), (38, (1.00, 0.30, 0.25)),
        ]
        if celsius <= stops[0].0 { let v = stops[0].1; return Color(red: v.0, green: v.1, blue: v.2) }
        for i in 1..<stops.count where celsius <= stops[i].0 {
            let (t0, a) = stops[i - 1], (t1, b) = stops[i]
            let f = (celsius - t0) / (t1 - t0)
            return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
        }
        let v = stops[stops.count - 1].1
        return Color(red: v.0, green: v.1, blue: v.2)
    }
}
