import Foundation
import SwiftUI
import SkylineCore

/// Cached, timezone-aware date formatting (DateFormatter creation is expensive).
@MainActor
enum Fmt {
    private static var cache: [String: DateFormatter] = [:]
    /// 12/24-hour choice from Settings (T20); every hour/time template below goes through it.
    static var clock: ClockStyle = .system { didSet { if clock != oldValue { cache.removeAll() } } }

    static func string(_ date: Date, template rawTemplate: String, timeZone: TimeZone) -> String {
        let template = clock.template(rawTemplate)
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
    /// Colours live in SkylineCore (`SkyColors`) so their text contrast is unit-tested (T6).
    static func colors(_ category: SkyCategory, isDay: Bool) -> [Color] {
        SkyColors.stops(category, isDay: isDay).map { Color(red: $0.r, green: $0.g, blue: $0.b) }
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
