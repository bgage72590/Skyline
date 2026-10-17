import Foundation

/// Plain-language bits for the menu-bar dropdown (polish 3), kept here so they're testable.
public enum MenuSummary {
    /// The rain card's line: the shared `RainTiming` sentence (the headline and radar header use the same
    /// one). Nil when there's no nowcast line and no hourly data at all.
    public static func rainTiming(_ report: WeatherReport, now: Date, hourLabel: (Date) -> String) -> String? {
        RainTiming.text(report, now: now, hourLabel: hourLabel)
    }

    /// Radar-header "Forecast" line: the exact same string as the menu bar. Never derived from HRRR tiles.
    public static func radarForecastLine(_ report: WeatherReport?, now: Date, hourLabel: (Date) -> String) -> String? {
        guard let report else { return nil }
        return rainTiming(report, now: now, hourLabel: hourLabel)
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

    /// "Feels like 72°" only when it differs from the air temperature by at least 3° in the units shown,
    /// compared before rounding (67.4 vs 67.6 °F printed "67°" and "Feels like 68°"). nil otherwise.
    public static let feelsLikeMinDifference = 3.0
    public static func feelsLikeText(temperature: Double, apparent: Double, units: DisplayUnits) -> String? {
        abs(units.temperatureDelta(apparent - temperature)) >= feelsLikeMinDifference
            ? "Feels like \(units.temperatureString(apparent))" : nil
    }

    /// The wind tile's gust: the highest gust in the next 24 hours, labelled as such (it read as now).
    public static func gustCaption(_ peakGust: String) -> String { "24-h peak gust \(peakGust)" }

    /// The dropdown's amber row: SPC's Day-1 outlook at level 2 (Slight) or higher, still in force.
    /// "Severe storms possible tonight · level 2 of 5".
    public static let severeRowMinLevel = 2
    public static func severeRow(_ report: WeatherReport, now: Date) -> String? {
        guard let o = report.severeOutlooks
                .filter({ $0.day == 1 && $0.validUntil > now && ($0.risk.level ?? 0) >= severeRowMinLevel })
                .max(by: { $0.risk < $1.risk }),
              let level = o.risk.level else { return nil }
        return "Severe storms possible \(o.when(now: now, timeZone: report.timeZone)) · level \(level) of 5"
    }

    /// How old another city's row is, shown once it's stale ("45 min", "2 h"); nil while fresh.
    public static func rowAge(_ report: WeatherReport, now: Date, staleAfter: TimeInterval) -> String? {
        let age = report.dataAge(at: now)
        guard age >= staleAfter else { return nil }
        return age < 3600 ? "\(Int(age / 60)) min" : (age < 86400 ? "\(Int(age / 3600)) h" : "\(Int(age / 86400)) d")
    }

    /// Opening the dropdown refreshes (bypassing the 10-minute guard and the HTTP cache) when it's raining
    /// or rain is due within 2 hours and the data is at least `rainingRefreshAge` old: the nowcast changes fast.
    public static let rainingRefreshAge: TimeInterval = 5 * 60
    /// At most one forced refresh-on-open per this long, whether the last one worked or failed (CR #11
    /// M1: a source that keeps failing must not turn every open into a full refetch).
    public static let forcedOpenCooldown: TimeInterval = 3 * 60

    /// - Parameter lastForcedAttempt: when the last forced refresh-on-open for this place started.
    public static func refreshOnOpen(_ report: WeatherReport, now: Date, lastForcedAttempt: Date? = nil) -> Bool {
        if let last = lastForcedAttempt, now.timeIntervalSince(last) < forcedOpenCooldown { return false }
        let raining = report.current.condition.isPrecipitation || Briefing.rainDueSoon(report, now: now)
        return raining && primaryForecastAge(report, now: now) >= rainingRefreshAge
    }

    /// Age of the Open-Meteo forecast (the primary source), not the oldest input: an NWS copy kept from
    /// cache after a failure would otherwise make the report look old forever (CR #11 M1).
    public static func primaryForecastAge(_ report: WeatherReport, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(report.forecastAsOf ?? report.dataAsOf))
    }
}
