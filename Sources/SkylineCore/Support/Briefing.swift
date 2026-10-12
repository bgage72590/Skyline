import Foundation

/// Plain-English one-liners built from a report ("Rain likely from 4 PM. Tomorrow is 6° warmer.").
/// Pure logic (formatting is injected) so it is unit-testable.
public enum Briefing {
    /// - Parameters:
    ///   - hourLabel: formats a time as e.g. "4 PM" in the report's time zone.
    ///   - delta: converts a °C difference to display units (°F or °C), already rounded.
    public static func headline(_ report: WeatherReport, now: Date = Date(),
                                hourLabel: (Date) -> String, delta: (Double) -> Int) -> String {
        var parts: [String] = []
        if let nowcast = report.nowcastSummary(at: now) {
            parts.append(nowcast + ".")
        } else {
            parts.append(nextChange(report, now: now, hourLabel: hourLabel))
        }
        if report.daily.count > 1 {
            let d = report.daily[1].high - report.daily[0].high
            let shown = delta(abs(d))
            if shown >= 3 { parts.append("Tomorrow is \(shown)° \(d > 0 ? "warmer" : "cooler").") }
        }
        if let outlook = report.severeOutlooks.first(where: { $0.day == 1 && $0.isSevere && $0.validUntil > now }) {
            parts.append(outlook.sentence(now: now, timeZone: report.timeZone) + ".")
        }
        return parts.joined(separator: " ")
    }

    /// "Rain likely from 4 PM (70%)." / "Clearing by 3 PM." / "Cloudy for the next 12 hours."
    /// An hourly value at T covers the hour *ending* at T, so times are labelled by the hour's start
    /// ("from 3 PM" for the 3–4 PM hour), the same as the confidence card (QA batch 4). The first hour is the
    /// one under way, never one that already ended.
    static func nextChange(_ report: WeatherReport, now: Date, hourLabel: (Date) -> String) -> String {
        let hours = Array(report.hourly.filter { $0.time > now }.prefix(12))
        func start(_ h: HourlyForecast) -> Date { h.time.addingTimeInterval(-3600) }
        func label(_ h: HourlyForecast) -> String { hourLabel(max(start(h), now)) }
        guard let first = hours.first else { return report.current.condition.description + "." }
        let wetNow = report.current.condition.isPrecipitation
        if wetNow {
            if let dry = hours.first(where: { !$0.condition.isPrecipitation && ($0.precipitationProbability ?? 0) < 40 }) {
                return "\(report.current.condition.description) ending around \(label(dry))."
            }
            return "\(report.current.condition.description) for the next 12 hours."
        }
        if let wet = hours.first(where: { ($0.precipitationProbability ?? 0) >= 50 && $0.condition.isPrecipitation }) {
            let kind = wet.condition.category == .snow ? "Snow" : (wet.condition.category == .thunderstorm ? "Storms" : "Rain")
            let pct = Int((wet.precipitationProbability ?? 0).rounded())
            if start(wet) <= now { return "\(kind) likely now (\(pct)%)." }
            return "\(kind) likely from \(label(wet)) (\(pct)%)."
        }
        let category = first.condition.category
        if let change = hours.first(where: { $0.condition.category != category }) {
            return "\(first.condition.description) now, \(change.condition.description.lowercased()) by \(label(change))."
        }
        return "\(first.condition.description) for the next 12 hours."
    }

    /// True when the 15-minute nowcast shows any precipitation in the next two hours.
    public static func rainDueSoon(_ report: WeatherReport, now: Date = Date()) -> Bool {
        report.minutely.contains { $0.time >= now.addingTimeInterval(-15 * 60) && $0.time <= now.addingTimeInterval(2 * 3600)
                                   && $0.precipitation >= Nowcast.threshold }
    }

    /// Time and value of the highest value in the next `hours` hours of a series.
    public static func peak(_ series: [(Date, Double)], from now: Date = Date(), hours: Double = 24) -> (time: Date, value: Double)? {
        series.filter { $0.0 >= now.addingTimeInterval(-3600) && $0.0 <= now.addingTimeInterval(hours * 3600) }
            .max { $0.1 < $1.1 }
            .map { (time: $0.0, value: $0.1) }
    }
}
