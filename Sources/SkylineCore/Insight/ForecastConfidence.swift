import Foundation

/// Shared Forecast Confidence spread + thresholds (accuracy-fixes plan). Pure; no persisted fields.
public enum ForecastConfidence {
    /// Raw °C thresholds shared by ModuleDetailView and ForecastInsight (`≤`).
    public enum ConfidenceThresholds {
        public static let highMaxSpreadC = 2.0
        public static let mediumMaxSpreadC = 4.0
    }

    /// Minimum remaining hours of today (and samples per series) required for a day-0 spread.
    public static let confidenceMinRemainingHours = 3
    public static let secondsPerHour: TimeInterval = 3600

    public static let emDash = "—"
    public static let notEnoughOfTodayLeft = "Not enough of today left"

    /// High / Medium / Low / "—" from a raw °C spread.
    public static func levelName(_ spread: Double?) -> String {
        guard let spread else { return emDash }
        if spread <= ConfidenceThresholds.highMaxSpreadC { return "High" }
        if spread <= ConfidenceThresholds.mediumMaxSpreadC { return "Medium" }
        return "Low"
    }

    /// Classify a raw °C spread the same way both surfaces do.
    public static func level(_ spread: Double) -> ForecastInsight.Level {
        if spread <= ConfidenceThresholds.highMaxSpreadC { return .high }
        if spread <= ConfidenceThresholds.mediumMaxSpreadC { return .medium }
        return .low
    }

    /// City-TZ day-0 window: `[startOfHour(now), startOfDay(day)+1 day)` via calendar day add (never +86400).
    public static func day0Window(dayDate: Date, timeZone: TimeZone, now: Date) -> (start: Date, end: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: dayDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
        let hourParts = cal.dateComponents([.year, .month, .day, .hour], from: now)
        guard let start = cal.date(from: hourParts) else { return nil }
        return (start, end)
    }

    /// Hours left in the city-TZ day-0 window from `now` (may be negative if `now` is past end).
    public static func remainingTodayHours(dayDate: Date, timeZone: TimeZone, now: Date) -> Double? {
        guard let w = day0Window(dayDate: dayDate, timeZone: timeZone, now: now) else { return nil }
        return w.end.timeIntervalSince(w.start) / secondsPerHour
    }

    /// Max of high-spread and low-spread in raw °C, or nil when not enough data / day-0 window.
    public static func spread(day: DailyForecast, modelSeries: [ModelSeries], timeZone: TimeZone,
                              now: Date, isToday: Bool) -> Double? {
        if isToday {
            return day0Spread(day: day, modelSeries: modelSeries, timeZone: timeZone, now: now)
        }
        return sourcesSpread(day)
    }

    // MARK: - Internals

    /// Days ≥ 1 (and empty-modelSeries fallback): max(high, low) from weighted sources.
    public static func sourcesSpread(_ day: DailyForecast) -> Double? {
        let rows = day.sources.filter { $0.weight > 0 }
        let highs = rows.compactMap(\.high)
        let lows = rows.compactMap(\.low)
        let highSpread: Double?
        if highs.count >= 2, let hi = highs.max(), let lo = highs.min() { highSpread = hi - lo }
        else { highSpread = nil }
        let lowSpread: Double?
        if lows.count >= 2, let hi = lows.max(), let lo = lows.min() { lowSpread = hi - lo }
        else { lowSpread = nil }
        switch (highSpread, lowSpread) {
        case let (h?, l?): return max(h, l)
        case let (h?, nil): return h
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    private static func day0Spread(day: DailyForecast, modelSeries: [ModelSeries],
                                   timeZone: TimeZone, now: Date) -> Double? {
        guard let window = day0Window(dayDate: day.date, timeZone: timeZone, now: now) else { return nil }
        let remaining = window.end.timeIntervalSince(window.start) / secondsPerHour
        if remaining < Double(confidenceMinRemainingHours) { return nil }

        let series = modelSeries.filter { !$0.isBlend }
        if series.isEmpty {
            // Fall back to sources when nothing hourly is available (after the <3 h guard).
            return sourcesSpread(day)
        }

        var remHighs: [Double] = []
        var remLows: [Double] = []
        for s in series {
            let temps = zip(s.times, s.temperatures).compactMap { t, v -> Double? in
                (t >= window.start && t < window.end) ? v : nil
            }
            guard temps.count >= confidenceMinRemainingHours else { continue }
            guard let hi = temps.max(), let lo = temps.min() else { continue }
            remHighs.append(hi)
            remLows.append(lo)
        }
        guard remHighs.count >= 2, remLows.count >= 2,
              let highMax = remHighs.max(), let highMin = remHighs.min(),
              let lowMax = remLows.max(), let lowMin = remLows.min() else { return nil }
        return max(highMax - highMin, lowMax - lowMin)
    }
}
