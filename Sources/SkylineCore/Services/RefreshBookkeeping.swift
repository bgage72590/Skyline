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

/// Item 2: how a refresh that didn't produce fresh data is followed up. The first few transient
/// failures (timeout, dropped connection, 5xx, a short Open-Meteo back-off) retry quickly and quietly:
/// the city shows "Updating…" (or keeps its saved data) instead of an error banner. After that, or for
/// a real "you're offline", the PR #2 behaviour applies: a message and the exponential retry, and a
/// live back-off is always respected (never earlier than `backoffUntil`), so no 429 stampede.
public enum FetchRetryPolicy {
    /// Seconds before quiet retry 1, 2, 3.
    public static let quickRetries: [TimeInterval] = [5, 15, 30]

    public struct Decision: Equatable, Sendable {
        /// true = no banner; the city stays in the "updating" state.
        public var quiet: Bool
        public var retryAfter: TimeInterval
    }

    public static func isTransient(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                    .secureConnectionFailed, .badServerResponse].contains(u.code)
        }
        if let h = error as? HTTPError {
            switch h {
            case .throttled, .backingOff: return true
            case .status(let code, _): return code >= 500
            default: return false
            }
        }
        return false
    }

    /// `attempt` = failures so far for this city (0 for the first). `jitterSeed` spreads cities apart.
    public static func decide(error: Error, attempt: Int, backoffUntil: Date?, refreshInterval: TimeInterval,
                              jitterSeed: Int = 0, now: Date = Date()) -> Decision {
        let jitter = Double(abs(jitterSeed) % 4) // 0–3 s, so retries after one back-off don't line up
        let wait = max(0, (backoffUntil ?? RefreshBookkeeping.notBefore(error, now: now) ?? now).timeIntervalSince(now))
        if isTransient(error), attempt < quickRetries.count {
            return Decision(quiet: true, retryAfter: max(quickRetries[attempt], wait + 1) + jitter)
        }
        let slow = attempt - quickRetries.count
        let base = min(60 * pow(2, Double(min(max(slow, 0), 6))), max(refreshInterval, 60))
        return Decision(quiet: false, retryAfter: max(base, wait + 2) + jitter)
    }

    /// Fresh data from a city with nothing on screen goes ahead of queued refreshes.
    public static func priority(force: Bool, hasReport: Bool) -> FetchPriority {
        force || !hasReport ? .interactive : .background
    }
}
