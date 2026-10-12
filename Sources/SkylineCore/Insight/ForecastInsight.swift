import Foundation

/// Plain-English confidence and "why the forecast changed" notes (T11), built from the blend's model
/// spread and the snapshot Skyline saved about 12 h earlier. Pure logic; formatting is injected.
public enum ForecastInsight {
    public enum Level: Int, Comparable, Sendable {
        case high = 0, medium, low
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .high: "High confidence"
            case .medium: "Medium confidence"
            case .low: "Low confidence"
            }
        }
    }

    public struct Confidence: Equatable, Sendable {
        public var level: Level
        /// One short reason ("Models disagree on rain chances after 2 PM"), nil if there's nothing to say.
        public var reason: String?
        public var sentence: String { reason.map { "\(level.label): \($0.prefix(1).lowercased() + $0.dropFirst())." } ?? "\(level.label)." }
    }

    /// High spread thresholds (°C): under 2.5 is high confidence, under 4.5 medium, else low.
    static let highSpreadMedium = 2.5, highSpreadLow = 4.5
    /// Hours where the sources' rain chances differ by this much (percentage points) count as disagreement.
    static let popSpreadDisagree = 50.0

    /// - Parameters:
    ///   - hourLabel: "2 PM" in the report's time zone.
    ///   - delta: a °C difference converted to display degrees, rounded.
    public static func confidence(day: DailyForecast, hourly: [HourlyForecast], timeZone: TimeZone, now: Date,
                                  hourLabel: (Date) -> String, delta: (Double) -> Int) -> Confidence {
        var level = Level.high
        var reason: String?
        let highs = day.sources.filter { $0.weight > 0 }.compactMap(\.high)
        if !day.sources.isEmpty, highs.count < 2 {
            // One forecast can't agree with anything: don't claim High (Code Reviewer batch 4, NTH 6).
            level = .medium
            reason = "Only one forecast available for this day"
        } else if let spread = trimmedSpread(highs) ?? day.highSpread {
            let t: Level = spread >= highSpreadLow ? .low : (spread >= highSpreadMedium ? .medium : .high)
            if t > .high { level = t; reason = "Models differ by \(delta(spread))° on the high" }
            else if day.sources.count >= 3 || spread > 0 { reason = "Models agree on the high within \(max(1, delta(spread)))°" }
        }
        // Rain timing: daytime hours (6 AM–midnight local) still ahead where the sources split.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = max(cal.date(bySettingHour: 6, minute: 0, second: 0, of: day.date) ?? day.date, now)
        let end = cal.date(byAdding: .day, value: 1, to: day.date) ?? day.date.addingTimeInterval(86400)
        let split = hourly.filter { $0.time > start && $0.time <= end && ($0.precipitationProbabilitySpread ?? 0) >= popSpreadDisagree }
        if split.count >= 2, let first = split.first {
            let r: Level = split.count >= 6 ? .low : .medium
            if r >= level {
                level = r
                // Rain chance at T covers the hour ending at T, so the disagreement starts an hour earlier.
                reason = "Models disagree on rain chances after \(hourLabel(first.time.addingTimeInterval(-3600)))"
            }
        }
        return Confidence(level: level, reason: reason)
    }

    /// Max − min of the highs, ignoring the single value farthest from the median when there are four or
    /// more: one outlier model shouldn't make the day "Low confidence" on its own.
    static func trimmedSpread(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        var v = values.sorted()
        if v.count >= 4 {
            let median = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
            if abs(v.first! - median) > abs(v.last! - median) { v.removeFirst() } else { v.removeLast() }
        }
        return v.last! - v.first!
    }

    /// "since this morning" / "since last night" / "since yesterday afternoon", for a snapshot time.
    public static func sincePhrase(_ issued: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let h = cal.component(.hour, from: issued)
        if cal.isDate(issued, inSameDayAs: now) {
            switch h {
            case ..<5: return "since last night"
            case ..<12: return "since this morning"
            case ..<17: return "since this afternoon"
            default: return "since this evening"
            }
        }
        switch h {
        case ..<12: return "since yesterday morning"
        case ..<17: return "since yesterday afternoon"
        default: return "since last night"
        }
    }

    /// Up to three notes on how today's and tomorrow's forecast moved since the earlier snapshot:
    /// highs that moved 3° or more (display units) and rain chances that moved 25 points or more.
    public static func changes(_ report: WeatherReport, now: Date, delta: (Double) -> Int) -> [String] {
        guard let earlier = report.earlierOutlook else { return [] }
        let tz = report.timeZone
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let since = sincePhrase(earlier.issued, now: now, timeZone: tz)
        var notes: [String] = []
        for day in report.daily.prefix(3) {
            let name: String
            if cal.isDate(day.date, inSameDayAs: now) {
                // Today's high stops being news once the afternoon is under way.
                guard cal.component(.hour, from: now) < 15 else { continue }
                name = "today"
            } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(day.date, inSameDayAs: tomorrow) {
                name = "tomorrow"
            } else { continue }
            guard let old = earlier.day(day.date) else { continue }
            let d = day.high - old.high
            let shown = delta(abs(d))
            if shown >= 3 {
                notes.append("\(name.prefix(1).uppercased() + name.dropFirst())’s high is \(d > 0 ? "up" : "down") \(shown)° \(since).")
            }
            if let p = day.precipitationProbability, let was = old.precipitationProbability, abs(p - was) >= 25 {
                let a = Int(was.rounded()), b = Int(p.rounded())
                notes.append("Rain chance \(name) is \(p > was ? "up" : "down") from \(a)% to \(b)% \(since).")
            }
        }
        return Array(notes.prefix(3))
    }
}
