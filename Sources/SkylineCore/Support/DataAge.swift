import Foundation

/// Wording for how old the shown weather data is ("Updated 5 min ago").
public enum DataAge {
    /// "just now" (< 1 min), "5 min ago", "2 h ago", "3 d ago".
    public static func relative(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }

    public static func updatedText(_ report: WeatherReport, now: Date = Date()) -> String {
        "Updated " + relative(report.freshnessAge(at: now))
    }

    /// Data older than this is treated as stale (dimmed, flagged) given the refresh interval in minutes:
    /// at least 30 min, and a quarter hour of slack beyond one refresh cycle.
    public static func staleAfter(refreshMinutes: Int) -> TimeInterval {
        Double(max(30, refreshMinutes + 15)) * 60
    }

    /// Fresh-cadence cities keep `staleAfter(refreshMinutes:)`. Background cities use background TTL + 15 min
    /// so a row isn't dimmed at 30 min while its OM pair is still within `TTL.background`.
    public static func staleAfter(refreshMinutes: Int, role: RefreshPlanner.Role) -> TimeInterval {
        switch role {
        case .freshCadence: return staleAfter(refreshMinutes: refreshMinutes)
        case .background: return WeatherService.TTL.effectiveBackground() + 15 * 60
        }
    }

    /// Older than this, even data already on screen is withdrawn (the forecast offline-cache cap).
    public static let maxDisplayAge: TimeInterval = WeatherService.MaxStale.forecast
}
