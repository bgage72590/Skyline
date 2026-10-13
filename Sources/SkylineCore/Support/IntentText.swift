import Foundation

/// Sentences the Shortcuts / Siri intents speak (L22). Pure, so they're tested on any platform.
public enum IntentText {
    /// "Fairfield: 64°, Partly Cloudy. High 70°, low 55°. Rain likely from 3 PM (70%). Flood Warning in effect."
    public static func weather(_ report: WeatherReport, name: String, units: DisplayUnits, now: Date) -> String {
        var parts = ["\(name): \(units.temperatureString(report.current.temperature)), \(report.current.condition.description)."]
        if let t = report.today {
            parts.append("High \(units.temperatureString(t.high)), low \(units.temperatureString(t.low)).")
        }
        let tz = report.timeZone
        let f = DateFormatter(); f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h a"
        parts.append(Briefing.headline(report, now: now, hourLabel: { f.string(from: $0) },
                                       delta: { Int(units.temperatureDelta($0).rounded()) }))
        if let a = report.activeAlerts(at: now).filter({ !$0.isCancellation }).max(by: { $0.severity < $1.severity }) {
            parts.append("\(a.event) in effect.")
        }
        return parts.joined(separator: " ")
    }

    /// Uses the same 15-minute rule as the rain notification and the briefing; falls back to the hourly
    /// chance where there's no 15-minute data.
    public static func rain(_ report: WeatherReport, name: String, now: Date) -> String {
        if let s = report.nowcastSummary(at: now) { return "\(name): \(s)." }
        if report.minutely.contains(where: { $0.time > now }) {
            return report.current.condition.isPrecipitation
                ? "\(name): \(report.current.condition.description) continuing for the next 2 hours."
                : "\(name): no rain expected in the next 2 hours."
        }
        let next = report.hourly.filter { $0.time > now && $0.time <= now.addingTimeInterval(2 * 3600) }
        let p = next.compactMap(\.precipitationProbability).max() ?? 0
        return "\(name): \(Int(p.rounded()))% chance of rain in the next 2 hours."
    }
}
