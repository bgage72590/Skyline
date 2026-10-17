import Foundation

/// How `WeatherStore` records a refresh: the offline error, when to retry, and when a later
/// success clears both so the banner can go away. Lives in SkylineCore so the store and tests
/// share one implementation.
public enum RefreshBookkeeping {
    public static let openMeteoHost = "api.open-meteo.com"
    public static let savedDataMessage = "Couldn’t reach the weather service; showing saved data."
    /// Saved data because the Mac has no network (the only case the banner may call "Offline").
    public static let offlineSavedMessage = "You’re offline; showing saved data."
    /// A failed refresh with saved data and no live back-off is retried this soon (once), not after the
    /// 1-minute ladder step: the usual cause is one dropped request, and the banner should clear fast.
    public static let quickRetryAfterFallback: TimeInterval = 15

    public struct FollowUp: Equatable, Sendable {
        public var message: String
        public var notBefore: Date?
        public var clearError: Bool
        /// Seconds to the first retry when it should come sooner than the ladder (nil = ladder).
        public var quickRetry: TimeInterval? = nil
    }

    /// Saved data on screen. A live host back-off schedules the retry at `until` and says when.
    public static func afterReport(isOfflineFallback: Bool, cause: FallbackCause? = nil, backoffUntil: Date?,
                                   now: Date = Date(), timeZone: TimeZone = .current,
                                   locale: Locale = .autoupdatingCurrent) -> FollowUp {
        guard isOfflineFallback else {
            return FollowUp(message: "", notBefore: nil, clearError: true)
        }
        if let backoffUntil, backoffUntil > now {
            let message = UserFacingError.message(
                HTTPError.backingOff(host: openMeteoHost, until: backoffUntil), now: now, timeZone: timeZone, locale: locale)
            return FollowUp(message: message, notBefore: backoffUntil, clearError: false)
        }
        if cause == .offline { return FollowUp(message: offlineSavedMessage, notBefore: nil, clearError: false) }
        return FollowUp(message: savedDataMessage, notBefore: nil, clearError: false, quickRetry: quickRetryAfterFallback)
    }

    /// A thrown refresh failure (including force during a long back-off).
    public static func afterFailure(_ error: Error, now: Date = Date(), timeZone: TimeZone = .current,
                                    locale: Locale = .autoupdatingCurrent) -> FollowUp {
        FollowUp(message: UserFacingError.message(error, now: now, timeZone: timeZone, locale: locale),
                 notBefore: notBefore(error, now: now), clearError: false)
    }

    public static func notBefore(_ error: Error, now: Date = Date()) -> Date? {
        switch error {
        case HTTPError.throttled(_, _, let after): return after.map { now.addingTimeInterval($0) }
        case HTTPError.backingOff(_, let until): return until
        default: return nil
        }
    }

    /// The report isn't current: saved data after a failed refresh, or a refresh error. Shows the banner.
    public static func isOffline(isOfflineFallback: Bool, error: String?) -> Bool {
        isOfflineFallback || error != nil
    }

    /// The Mac really has no network: the only time the banner and the dropdown may say "Offline".
    /// A dropped request, a timeout, a 5xx or a back-off is not that (QA, build 88: "Offline" after a
    /// Refresh on a working network).
    public static func isReallyOffline(cause: FallbackCause?, error: String?) -> Bool {
        cause == .offline || error == UserFacingError.offline || error == offlineSavedMessage
    }

    /// Banner sentence. A scheduled back-off replaces "showing data from …" with the retry clock time.
    /// `offline` = `isReallyOffline`; any other failure says the update failed, not that the Mac is offline.
    public static func bannerLine(offline: Bool, error: String?, dataTime: String) -> String {
        if let error, error.contains("retrying at") { return error }
        if offline { return "Offline · showing data from " + dataTime }
        if error != nil { return "Couldn’t update · showing data from " + dataTime }
        return "Showing data from " + dataTime
    }
}

/// Why a report is showing saved data (`WeatherReport.fallbackCause`).
public enum FallbackCause: String, Codable, Sendable, Equatable {
    /// No network on this Mac.
    case offline
    /// The host said slow down, or Skyline is waiting out its Retry-After.
    case busy
    /// Anything else: a dropped connection, a timeout, a server error, unreadable data.
    case unreachable

    public init(_ error: Error) {
        if let u = error as? URLError, [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(u.code) {
            self = .offline
        } else if let h = error as? HTTPError, case .throttled = h {
            self = .busy
        } else if let h = error as? HTTPError, case .backingOff = h {
            self = .busy
        } else {
            self = .unreachable
        }
    }

    /// One immediate second try is worth it: the request died on the way, not because of the network
    /// being down or the host refusing us. Covers macOS's -1005 on a reused keep-alive connection.
    public static func retriesOnce(_ error: Error) -> Bool {
        if let u = error as? URLError {
            return [.networkConnectionLost, .badServerResponse, .cannotConnectToHost, .secureConnectionFailed].contains(u.code)
        }
        if let h = error as? HTTPError, case .status(let code, _) = h { return code >= 500 }
        return false
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
    /// Follow-up L1: 0 to `maxJitter` s, spread over 1000 steps from a stable hash of the city id.
    public static let maxJitter: TimeInterval = 5

    public static func jitter(for id: String) -> TimeInterval {
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Double(h % 1000) / 1000 * maxJitter
    }

    /// `hasReport` (follow-up M3): a city with saved data on screen gets no quick retries, only the
    /// PR #2 ladder; the quiet ladder is for cities that have nothing to show yet.
    public static func decide(error: Error, attempt: Int, backoffUntil: Date?, refreshInterval: TimeInterval,
                              jitterSeed: Int = 0, hasReport: Bool = false, jitter fixedJitter: TimeInterval? = nil,
                              now: Date = Date()) -> Decision {
        let jitter = fixedJitter ?? Double(abs(jitterSeed) % 1000) / 1000 * maxJitter
        let wait = max(0, (backoffUntil ?? RefreshBookkeeping.notBefore(error, now: now) ?? now).timeIntervalSince(now))
        if !hasReport, isTransient(error), attempt < quickRetries.count {
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


/// Follow-up (LOW L3 + "Updating… clears" test): the store's quiet-retry bookkeeping, pure so it is
/// testable. A city is "updating" from a quiet failure until a success, a non-quiet failure, an
/// abandoned retry (not visible), or a dropped answer (My Location moved).
public struct QuietRetryTracker: Equatable, Sendable {
    public private(set) var updating: Set<String> = []
    /// Quiet attempts used per city, so the PR #2 ladder after them starts at 1 min.
    public private(set) var quietAttempts: [String: Int] = [:]

    public init() {}

    /// Returns the decision; `quiet` marks the city updating.
    public mutating func failed(_ id: String, error: Error, hasReport: Bool, backoffUntil: Date?,
                                refreshInterval: TimeInterval, now: Date = Date()) -> FetchRetryPolicy.Decision {
        let d = FetchRetryPolicy.decide(error: error, attempt: quietAttempts[id, default: 0], backoffUntil: backoffUntil,
                                        refreshInterval: refreshInterval, hasReport: hasReport,
                                        jitter: FetchRetryPolicy.jitter(for: id), now: now)
        if d.quiet {
            updating.insert(id)
            quietAttempts[id, default: 0] += 1
        } else {
            updating.remove(id)
        }
        return d
    }

    public mutating func succeeded(_ id: String) {
        updating.remove(id)
        quietAttempts[id] = nil
    }

    /// The retry won't run (city not visible) or the answer was dropped: stop showing "Updating…".
    public mutating func abandoned(_ id: String) { updating.remove(id) }

    /// Index into the PR #2 exponential ladder for the next non-quiet retry.
    public func ladderIndex(_ id: String, attempt: Int) -> Int { max(0, attempt - quietAttempts[id, default: 0]) }
}
