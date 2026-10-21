import Foundation

/// Pure helpers for Open-Meteo's free-tier daily request limit: classify a 429, compute the next
/// 00:00-UTC resume time with stored jitter, and encode/decode the on-disk marker.
public enum OpenMeteoQuota {
    public static let forecastHost = "api.open-meteo.com"
    public static let airQualityHost = "air-quality-api.open-meteo.com"
    public static let exactHosts: Set<String> = [forecastHost, airQualityHost]

    /// Banner / error prefix (verbatim). Times are appended by callers via `UserFacingError.clockTime`.
    public static let messagePrefix = "Open-Meteo's free daily limit is used up"

    public enum Kind: Equatable, Sendable {
        case dailyLimit
        case other
    }

    /// Exact hosts only. Daily = 429 + JSON `reason` containing "daily api request limit" (case-insensitive).
    public static func classify(status: Int, host: String?, body: Data) -> Kind {
        guard status == 429, let host, exactHosts.contains(host.lowercased()) else { return .other }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reason = obj["reason"] as? String else { return .other }
        return reason.lowercased().contains("daily api request limit") ? .dailyLimit : .other
    }

    /// Next 00:00 UTC + 120 s + jitter (0…180 s). Server resets in the first minute of the UTC day.
    public static func until(after now: Date, jitter: TimeInterval) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfToday = cal.startOfDay(for: now)
        let j = max(0, min(jitter, 180))
        let todayUntil = startOfToday.addingTimeInterval(120 + j)
        if todayUntil > now { return todayUntil }
        return startOfToday.addingTimeInterval(86400 + 120 + j)
    }

    /// Random 0…180 s, drawn once and stored in the marker.
    public static func drawJitter(using generator: inout some RandomNumberGenerator) -> TimeInterval {
        TimeInterval(Int.random(in: 0...180, using: &generator))
    }

    public static func drawJitter() -> TimeInterval {
        var g = SystemRandomNumberGenerator()
        return drawJitter(using: &g)
    }

    public struct Marker: Codable, Equatable, Sendable {
        public var until: Date
        public var lastProbeAt: Date
        public var jitter: TimeInterval

        public init(until: Date, lastProbeAt: Date, jitter: TimeInterval) {
            self.until = until; self.lastProbeAt = lastProbeAt; self.jitter = jitter
        }
    }

    public static func markerKey(host: String) -> String { "om-daily-limit:" + host.lowercased() }

    public static func encode(_ marker: Marker) throws -> Data {
        try JSONEncoder().encode(marker)
    }

    public static func decode(_ data: Data) -> Marker? {
        try? JSONDecoder().decode(Marker.self, from: data)
    }

    /// Discard if `until < now` or `until > now + 24 h 5 m` (clock moved).
    public static let sanityHorizon: TimeInterval = 24 * 3600 + 5 * 60

    public static func isSane(_ marker: Marker, now: Date) -> Bool {
        marker.until >= now && marker.until <= now.addingTimeInterval(sanityHorizon)
    }

    /// Next probe: `lastProbeAt + 60 min`.
    public static let probeInterval: TimeInterval = 60 * 60

    public static func nextProbeAt(lastProbeAt: Date) -> Date {
        lastProbeAt.addingTimeInterval(probeInterval)
    }

    // MARK: User-facing messages

    /// US city, NWS-only path.
    public static func nwsOnlyMessage(until: Date, now: Date = Date(), timeZone: TimeZone = .current,
                                      locale: Locale = .autoupdatingCurrent) -> String {
        "\(messagePrefix) · showing the National Weather Service forecast · full forecast after \(resumePhrase(until: until, now: now, timeZone: timeZone, locale: locale))"
    }

    /// Cached OM still shown.
    public static func cachedMessage(dataTime: Date, until: Date, now: Date = Date(),
                                     timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let from = UserFacingError.clockTime(dataTime, timeZone: timeZone, locale: locale, roundUp: false)
        return "\(messagePrefix) · showing data from \(from) · updates resume after \(resumePhrase(until: until, now: now, timeZone: timeZone, locale: locale))"
    }

    /// No usable data.
    public static func noDataMessage(until: Date, now: Date = Date(), timeZone: TimeZone = .current,
                                     locale: Locale = .autoupdatingCurrent) -> String {
        "\(messagePrefix) · Skyline will try again after \(resumePhrase(until: until, now: now, timeZone: timeZone, locale: locale))"
    }

    /// Time alone for same local day; "tomorrow" + time when `until` falls on the next local day.
    public static func resumePhrase(until: Date, now: Date = Date(), timeZone: TimeZone = .current,
                                    locale: Locale = .autoupdatingCurrent) -> String {
        let time = UserFacingError.clockTime(until, timeZone: timeZone, locale: locale, roundUp: false)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if !cal.isDate(until, inSameDayAs: now) {
            return "tomorrow \(time)"
        }
        return time
    }
}
