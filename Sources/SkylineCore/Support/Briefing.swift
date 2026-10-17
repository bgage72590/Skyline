import Foundation

/// Plain-English one-liners built from a report ("Rain likely from 4 PM. Tomorrow is 6° warmer.").
/// Pure logic (formatting is injected) so it is unit-testable.
public enum Briefing {
    /// - Parameters:
    ///   - hourLabel: formats a time as e.g. "4 PM" in the report's time zone.
    ///   - delta: converts a °C difference to display units (°F or °C), already rounded.
    ///   - includeRain: false where the rain card already shows the `RainTiming` line (the dropdown), so
    ///     the same sentence isn't printed twice. The sky-change sentence still shows when there's no rain.
    ///   - includeSevere: false where the severe risk has its own row (the dropdown's amber row).
    public static func headline(_ report: WeatherReport, now: Date = Date(),
                                hourLabel: (Date) -> String, delta: (Double) -> Int,
                                includeRain: Bool = true, includeSevere: Bool = true) -> String {
        var parts: [String] = []
        if let rain = RainTiming.next(report, now: now), rain.isRain {
            if includeRain { parts.append(RainTiming.sentence(rain, hourLabel: hourLabel) + ".") }
        } else {
            parts.append(nextChange(report, now: now, hourLabel: hourLabel))
        }
        if report.daily.count > 1 {
            let d = report.daily[1].high - report.daily[0].high
            let shown = delta(abs(d))
            if shown >= 3 { parts.append("Tomorrow is \(shown)° \(d > 0 ? "warmer" : "cooler").") }
        }
        if includeSevere, let outlook = activeSevere(report, now: now) {
            parts.append(outlook.sentence(now: now, timeZone: report.timeZone) + ".")
        }
        return parts.joined(separator: " ")
    }

    static func activeSevere(_ report: WeatherReport, now: Date) -> SevereOutlook? {
        report.severeOutlooks.first(where: { $0.day == 1 && $0.isSevere && $0.validUntil > now })
    }

    /// The sky-change sentence for when no rain is expected: "Cloudy now, clear by 3 PM." /
    /// "Cloudy for the next 12 hours." Rain wording comes from `RainTiming`. Hours are named by their END
    /// time, like the hourly row (Brian, Oct 17); the first hour is the one under way, never one that ended.
    static func nextChange(_ report: WeatherReport, now: Date, hourLabel: (Date) -> String) -> String {
        let hours = Array(report.hourly.filter { $0.time > now }.prefix(12))
        guard let first = hours.first else { return report.current.condition.description + "." }
        let category = first.condition.category
        if let change = hours.first(where: { $0.condition.category != category }) {
            return "\(first.condition.description) now, \(change.condition.description.lowercased()) by \(hourLabel(change.time))."
        }
        return "\(first.condition.description) for the next 12 hours."
    }

    /// True when the next-2-hours chart has something to draw: the quarters AHEAD of now are wet (the one
    /// under way, or rain the nowcast says starts). A quarter that already ended, or a single light blip,
    /// no longer shows an empty-looking chart (dropdown review: "Rain easing" over a flat axis).
    public static func rainDueSoon(_ report: WeatherReport, now: Date = Date()) -> Bool {
        let ahead = Nowcast.quarters(report.minutely, now: now).filter { $0.time <= now.addingTimeInterval(2 * 3600 + 900) }
        guard let first = ahead.first else { return false }
        return Nowcast.isWet(first) || Nowcast.rainStart(report.minutely, now: now).map { $0 < now.addingTimeInterval(2 * 3600) } == true
    }

    /// Time and value of the highest value in the next `hours` hours of a series.
    public static func peak(_ series: [(Date, Double)], from now: Date = Date(), hours: Double = 24) -> (time: Date, value: Double)? {
        series.filter { $0.0 >= now.addingTimeInterval(-3600) && $0.0 <= now.addingTimeInterval(hours * 3600) }
            .max { $0.1 < $1.1 }
            .map { (time: $0.0, value: $0.1) }
    }
}
