import Foundation

/// One answer to "is it raining, and when does that change?" (dropdown review, Oct 17). The headline,
/// the dropdown's rain card, the radar header and the main window all format this one result, so they
/// can never name different times (before: the headline used PoP < 40 % and the hour's start, the card
/// PoP < 30 % and the hour's end, and they said "8 PM" and "12 AM" for the same data).
///
/// Rules:
/// * The 15-minute nowcast wins when it has a line ("Rain stopping in about 20 min").
/// * When the nowcast covers the next 2 hours and has no line (dry, or a single blip), hours that start
///   inside those 2 hours are not used: the nowcast is the better source there.
/// * An hour is wet when its chance is at least `wetPoP` or its icon is precipitation; rain "ends" only
///   when `dryHoursToEnd` dry hours follow in a row (a one-hour lull before 50 % isn't the end).
/// * Hours are named by their END time, the same as the hourly row's columns (Brian, Oct 17): an hourly
///   value at T covers the hour ending at T, so "ending around 11 PM" means the 11 PM column is the last
///   wet one, and "likely around 10 PM" names the 10 PM column.
public enum RainTiming {
    public static let wetPoP = 30.0
    public static let likelyPoP = 40.0
    public static let dryHoursToEnd = 2
    public static let horizonHours = 12.0

    public enum Kind: Equatable, Sendable {
        case nowcast(String)
        /// Raining now; the last wet hour ends at `at`.
        case ending(at: Date)
        /// Raining now, but the hour under way is already dry by the hourly forecast.
        case endingSoon
        case continuing
        /// Not raining now; `at` is the end of the first likely hour.
        case starting(at: Date, pop: Int, kind: String)
        /// The hour under way is already likely.
        case likelyNow(pop: Int, kind: String)
        case chance(peak: Int)
        case none
    }

    public struct Result: Equatable, Sendable {
        public var kind: Kind
        /// "Rain", "Light Drizzle"… (the current condition, for the raining-now wording).
        public var condition: String
        /// True for the rain sentences (nowcast, ending, continuing, starting, likely now); false for the
        /// "small chance" / "no rain" lines, which the headline replaces with its sky-change sentence.
        public var isRain: Bool {
            switch kind {
            case .chance, .none: false
            default: true
            }
        }
    }

    static func isWet(_ h: HourlyForecast) -> Bool {
        (h.precipitationProbability ?? 0) >= wetPoP || h.condition.isPrecipitation
    }

    /// True when the nowcast has at least 2 hours of quarters ahead of `now`.
    static func nowcastCoversTwoHours(_ minutely: [MinutelyPrecipitation], now: Date) -> Bool {
        Nowcast.quarters(minutely, now: now).last.map { $0.time >= now.addingTimeInterval(2 * 3600) } ?? false
    }

    /// nil when there's no nowcast line and no hourly data at all.
    public static func next(_ report: WeatherReport, now: Date) -> Result? {
        let condition = report.current.condition.description
        if let s = report.nowcastSummary(at: now) { return Result(kind: .nowcast(s), condition: condition) }
        let horizon = nowcastCoversTwoHours(report.minutely, now: now) ? now.addingTimeInterval(2 * 3600) : now
        let ahead = report.hourly.filter { $0.time > now && $0.time <= now.addingTimeInterval(horizonHours * 3600) }
            .sorted { $0.time < $1.time }
        guard !ahead.isEmpty else { return nil }
        if report.current.condition.isPrecipitation {
            // The nowcast covers the next 2 hours, has no line, and the quarter under way is dry: it's easing.
            if horizon > now { return Result(kind: .endingSoon, condition: condition) }
            for i in ahead.indices where !isWet(ahead[i]) {
                let run = ahead[i..<min(ahead.count, i + dryHoursToEnd)]
                guard run.allSatisfy({ !isWet($0) }) else { continue }
                if i == 0 { return Result(kind: .endingSoon, condition: condition) }
                return Result(kind: .ending(at: ahead[i - 1].time), condition: condition)
            }
            return Result(kind: .continuing, condition: condition)
        }
        let usable = horizon > now ? ahead.filter { $0.time.addingTimeInterval(-3600) >= horizon.addingTimeInterval(-1) } : ahead
        if let wet = usable.first(where: { ($0.precipitationProbability ?? 0) >= likelyPoP }) {
            let pop = Int((wet.precipitationProbability ?? 0).rounded())
            let c = wet.condition
            let kind = c.category == .snow ? "Snow" : (c.category == .thunderstorm ? "Storms" : "Rain")
            if wet.time.addingTimeInterval(-3600) <= now { return Result(kind: .likelyNow(pop: pop, kind: kind), condition: condition) }
            return Result(kind: .starting(at: wet.time, pop: pop, kind: kind), condition: condition)
        }
        let peak = Int((usable.compactMap(\.precipitationProbability).max() ?? 0).rounded())
        return Result(kind: peak >= HourlyDisplay.popCutoff ? .chance(peak: peak) : .none, condition: condition)
    }

    /// The one sentence (no final period), e.g. "Rain ending around 11 PM".
    public static func sentence(_ r: Result, hourLabel: (Date) -> String) -> String {
        switch r.kind {
        case .nowcast(let s): s
        case .ending(let at): "\(r.condition) ending around \(hourLabel(at))"
        case .endingSoon: "\(r.condition) ending soon"
        case .continuing: "\(r.condition) continuing for the next 12 hours"
        case let .starting(at, pop, kind): "\(kind) likely around \(hourLabel(at)) (\(pop)%)"
        case let .likelyNow(pop, kind): "\(kind) likely now (\(pop)%)"
        case .chance(let peak): "Small chance of rain (\(peak)%) in the next 12 hours"
        case .none: "No rain expected in the next 12 hours"
        }
    }

    public static func text(_ report: WeatherReport, now: Date, hourLabel: (Date) -> String) -> String? {
        next(report, now: now).map { sentence($0, hourLabel: hourLabel) }
    }
}

/// When a precipitation chance is printed (hourly row and daily rows): one cutoff for the number and
/// for the icon. `ForecastBlender.reconcile` drops a precipitation icon below the same cutoff, and a
/// precipitation icon always gets its number, so you never see a rain icon without a % (dropdown review).
public enum HourlyDisplay {
    public static let popCutoff = 20

    public static func popText(probability: Double?, isPrecipitationIcon: Bool) -> String? {
        guard let probability else { return nil }
        let p = Int(probability.rounded())
        return p >= popCutoff || isPrecipitationIcon ? "\(p)%" : nil
    }

    public static func popText(_ hour: HourlyForecast) -> String? {
        popText(probability: hour.precipitationProbability, isPrecipitationIcon: hour.condition.isPrecipitation)
    }

    public static func popText(_ day: DailyForecast) -> String? {
        popText(probability: day.precipitationProbability, isPrecipitationIcon: day.condition.isPrecipitation)
    }
}
