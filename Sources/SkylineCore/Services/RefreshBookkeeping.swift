import Foundation

/// How `WeatherStore` records a refresh: the offline error, when to retry, and when a later
/// success clears both so the banner can go away. Lives in SkylineCore so the store and tests
/// share one implementation.
public enum RefreshBookkeeping {
    public static let openMeteoHost = "api.open-meteo.com"
    public static let savedDataMessage = "Couldn’t reach the weather service; showing saved data."

    public struct FollowUp: Equatable, Sendable {
        public var message: String
        public var notBefore: Date?
        public var clearError: Bool
    }

    /// Saved data on screen. A live host back-off schedules the retry at `until` and says when.
    public static func afterReport(isOfflineFallback: Bool, backoffUntil: Date?, now: Date = Date(),
                                   timeZone: TimeZone = .current) -> FollowUp {
        guard isOfflineFallback else {
            return FollowUp(message: "", notBefore: nil, clearError: true)
        }
        if let backoffUntil, backoffUntil > now {
            let message = UserFacingError.message(
                HTTPError.backingOff(host: openMeteoHost, until: backoffUntil), now: now, timeZone: timeZone)
            return FollowUp(message: message, notBefore: backoffUntil, clearError: false)
        }
        return FollowUp(message: savedDataMessage, notBefore: nil, clearError: false)
    }

    /// A thrown refresh failure (including force during a long back-off).
    public static func afterFailure(_ error: Error, now: Date = Date(), timeZone: TimeZone = .current) -> FollowUp {
        FollowUp(message: UserFacingError.message(error, now: now, timeZone: timeZone),
                 notBefore: notBefore(error, now: now), clearError: false)
    }

    public static func notBefore(_ error: Error, now: Date = Date()) -> Date? {
        switch error {
        case HTTPError.throttled(_, _, let after): return after.map { now.addingTimeInterval($0) }
        case HTTPError.backingOff(_, let until): return until
        default: return nil
        }
    }

    public static func isOffline(isOfflineFallback: Bool, error: String?) -> Bool {
        isOfflineFallback || error != nil
    }

    /// Banner sentence. A scheduled back-off replaces "showing data from …" with the retry clock time.
    public static func bannerLine(offline: Bool, error: String?, dataTime: String) -> String {
        if let error, error.contains("retrying at") { return error }
        return (offline ? "Offline · showing data from " : "Showing data from ") + dataTime
    }
}
