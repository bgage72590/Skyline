import Foundation

/// Plain-language bits for the menu-bar dropdown (polish 3), kept here so they're testable.
public enum MenuSummary {
    /// When rain is next expected: the 15-minute nowcast first ("Rain starting in 20 min"), else the
    /// first hour in the next 12 with a 40 %+ chance ("Rain likely around 3 PM · 70%"), else
    /// "No rain expected in the next 12 hours". Nil when there's no hourly data at all.
    public static func rainTiming(_ report: WeatherReport, now: Date, hourLabel: (Date) -> String) -> String? {
        if let s = report.nowcastSummary(at: now) { return s }
        let next = report.hourly.filter { $0.time > now.addingTimeInterval(-1800) && $0.time <= now.addingTimeInterval(12 * 3600) }
        guard !next.isEmpty else { return nil }
        if report.current.condition.isPrecipitation {
            if let dry = next.first(where: { !$0.condition.isPrecipitation && ($0.precipitationProbability ?? 0) < 30 && $0.time > now }) {
                return "\(report.current.condition.description) easing around \(hourLabel(dry.time))"
            }
            return "\(report.current.condition.description) for the next several hours"
        }
        if let wet = next.first(where: { $0.time > now && ($0.precipitationProbability ?? 0) >= 40 }) {
            let kind = wet.condition.isPrecipitation ? wet.condition.description : "Rain"
            return "\(kind) likely around \(hourLabel(wet.time)) · \(Int((wet.precipitationProbability ?? 0).rounded()))%"
        }
        let peak = next.compactMap(\.precipitationProbability).max() ?? 0
        return peak >= 20 ? "Small chance of rain (\(Int(peak.rounded()))%) in the next 12 hours"
                          : "No rain expected in the next 12 hours"
    }

    /// The next sunrise or sunset after `now` (today's or tomorrow's).
    public static func nextSunEvent(_ report: WeatherReport, now: Date) -> (isSunrise: Bool, time: Date)? {
        let events = report.daily.prefix(3).flatMap { d -> [(Bool, Date)] in
            [d.sunrise.map { (true, $0) }, d.sunset.map { (false, $0) }].compactMap { $0 }
        }
        return events.filter { $0.1 > now }.min { $0.1 < $1.1 }.map { (isSunrise: $0.0, time: $0.1) }
    }

    /// Plain words for relative humidity via the dew point (what people feel), e.g. "Muggy".
    public static func comfort(dewPointC: Double?) -> String? {
        guard let d = dewPointC else { return nil }
        switch d {
        case ..<10: return "Dry"
        case ..<16: return "Comfortable"
        case ..<20: return "Sticky"
        default: return "Muggy"
        }
    }
}
