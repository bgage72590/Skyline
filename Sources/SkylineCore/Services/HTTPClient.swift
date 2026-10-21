import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPError: Error, Sendable, Equatable {
    case status(Int, URL)
    case invalidResponse
    /// 429 or 503: the service asked us to slow down. `retryAfter` is its Retry-After (seconds), if sent.
    case throttled(Int, URL, retryAfter: TimeInterval?)
    /// Open-Meteo free-tier daily request limit (not transient; resume after 00:00 UTC).
    case dailyLimit(host: String)
    /// Not sent: the host asked Skyline to back off and that time hasn't passed yet.
    case backingOff(host: String, until: Date)
    /// Not sent (or not followed): the address isn't one of the known weather services (L28).
    case disallowedHost(String)

    /// Parses a Retry-After header: delta-seconds ("120") or an HTTP date.
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let s = Double(v) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v).map { max(0, $0.timeIntervalSince(now)) }
    }
}

extension HTTPError: LocalizedError {
    public var errorDescription: String? { UserFacingError.message(self) }
}

/// Plain-English wording for errors shown in the UI (instead of "…HTTPError error 0.").
public enum UserFacingError {
    /// The one message that means the Mac itself has no network.
    public static let offline = "You’re offline."

    public static func message(_ error: Error, now: Date = Date(), timeZone: TimeZone = .current,
                               locale: Locale = .autoupdatingCurrent) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return offline
            // -1005 is a dropped connection (often a reused keep-alive the server had closed), not "no
            // network": calling it "offline" put a false Offline banner up after Refresh (QA, build 88).
            case .networkConnectionLost: return "Lost the connection to the weather service."
            case .timedOut: return "Weather service didn’t respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Couldn’t reach the weather service."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "Couldn’t make a secure connection to the weather service."
            default: return "Couldn’t reach the weather service."
            }
        }
        if let h = error as? HTTPError {
            switch h {
            case .throttled(_, _, let after):
                return "Weather service is busy. Skyline will try again" + wait(after) + "."
            case .dailyLimit(let host):
                // Resume time is owned by WeatherService / OpenMeteoQuota messages; this is a fallback.
                return OpenMeteoQuota.noDataMessage(until: OpenMeteoQuota.until(after: now, jitter: 0),
                                                    now: now, timeZone: timeZone, locale: locale)
                    + (host.isEmpty ? "" : "")
            case .backingOff(let host, let until):
                return busyLine(host: host, until: until, timeZone: timeZone, locale: locale)
            case .status(let code, _) where code >= 500:
                return "Weather service didn’t respond (error \(code))."
            case .status(404, _): return "No weather data for this place."
            case .status(let code, _): return "Weather service refused the request (error \(code))."
            case .invalidResponse, .disallowedHost: return "Weather service sent data Skyline couldn’t read."
            }
        }
        if error is DecodingError { return "Weather service sent data Skyline couldn’t read." }
        return "Something went wrong loading the weather."
    }

    /// "Open-Meteo busy, retrying at 3:05 PM" — local clock time, not a duration.
    /// The retry fires `retrySlack` after `until` at the latest (a 2 s margin plus the sleep's 10 s
    /// tolerance), and the time shown is rounded up, so the banner never names a minute before the retry.
    public static let retrySlack: TimeInterval = 12

    public static func busyLine(host: String, until: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let who = host == "api.open-meteo.com" ? "Open-Meteo" : "Weather service"
        return "\(who) busy, retrying at \(clockTime(until.addingTimeInterval(retrySlack), timeZone: timeZone, locale: locale, roundUp: true))"
    }

    /// Hours and minutes in the user's own 12/24-hour style (the "j" template follows the locale and the
    /// system's 24-hour setting). `roundUp` moves any partial minute to the next one.
    public static func clockTime(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .autoupdatingCurrent,
                                 roundUp: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "h:mm a"
        let shown = roundUp ? Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.up) * 60) : date
        // Newer ICU puts a narrow no-break space before AM/PM; keep plain spaces in banner text.
        return f.string(from: shown).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func wait(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s > 0 else { return " shortly" }
        return s < 90 ? " in about a minute" : " in \(Int((s / 60).rounded())) min"
    }
}

/// The only servers Skyline talks to (L28, Security L5). Addresses that come from responses (NWS
/// forecast links, zone outlines, RainViewer's tile host) are checked against this before they're
/// requested, so a tampered response can't send Skyline elsewhere. HTTPS only.
public enum KnownHosts {
    public static let all: Set<String> = [
        "api.open-meteo.com", "air-quality-api.open-meteo.com", "geocoding-api.open-meteo.com",
        "api.weather.gov", "mesonet.agron.iastate.edu", "www.spc.noaa.gov",
        "api.rainviewer.com", "tilecache.rainviewer.com",
        // Accuracy PR 1: measurement-only hosts (METAR verification + MET Norway forecast benchmark).
        "aviationweather.gov", "api.met.no",
    ]

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return all.contains(host)
    }
}

/// Counts network requests for Settings › Privacy & energy (L23). Thread-safe; in memory only.
public final class RequestStats: @unchecked Sendable {
    public static let shared = RequestStats()
    private let lock = NSLock()
    private var count = 0
    public let since = Date()
    public init() {}
    public func note() { lock.lock(); count += 1; lock.unlock() }
    private var packed = 0, compressed = 0, unpacked = 0
    /// Radar tiles stored palette-packed, as original compressed bytes, or as decoded RGBA (measurement log).
    public func notePacked(_ ok: Bool, compressed isCompressed: Bool = false) {
        lock.lock()
        if ok { packed += 1 } else if isCompressed { compressed += 1 } else { unpacked += 1 }
        lock.unlock()
    }
    public var packCounts: (packed: Int, compressed: Int, unpacked: Int) {
        lock.lock(); defer { lock.unlock() }; return (packed, compressed, unpacked)
    }
    public var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// Requests per hour since launch (nil in the first 5 minutes, when it means little).
    public func perHour(now: Date = Date()) -> Double? {
        let hours = now.timeIntervalSince(since) / 3600
        return hours < 5.0 / 60 ? nil : Double(total) / hours
    }
}

/// Status + body + cache headers for conditional GETs (MET Norway). Additive to `HTTPClient.get`.
public struct HTTPFetchResult: Sendable, Equatable {
    public var statusCode: Int
    public var data: Data
    public var lastModified: String?
    public var expires: String?
    public var retryAfter: TimeInterval?

    public init(statusCode: Int, data: Data, lastModified: String? = nil, expires: String? = nil,
                retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode; self.data = data; self.lastModified = lastModified
        self.expires = expires; self.retryAfter = retryAfter
    }

    public var isNotModified: Bool { statusCode == 304 }
    public var isNoContent: Bool { statusCode == 204 }
    public var isDeprecated: Bool { statusCode == 203 }
}

/// Minimal async HTTP abstraction so services can be tested with fixtures.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
    /// Additive conditional-GET path. Default wraps `get` as status 200.
    func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult
}

extension HTTPClient {
    public func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        let data = try await get(url, headers: headers)
        return HTTPFetchResult(statusCode: 200, data: data)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    /// Plain User-Agent for every host except NWS / MET Norway / AWC (Open-Meteo, IEM, RainViewer, radar tiles).
    public static let genericUserAgent = "Skyline/1.0"
    /// NWS asks for a contact so it can reach the developer before throttling. Sent ONLY to api.weather.gov.
    /// Reused as the MET Norway contact (lock §8); never duplicated as a second string literal for that host.
    public static let nwsContact = "Brian.gage@gmail.com"
    public static let nwsUserAgent = "Skyline/1.0 (\(nwsContact))"
    /// MET Norway ToS: identifying UA with a real contact. Sent ONLY to api.met.no (lock §8).
    public static var metNorwayUserAgent: String { "Skyline/1.0 (\(nwsContact))" }
    /// AWC guideline: identifying UA without an email (lock §8).
    public static let awcUserAgent = "Skyline/1.0 (macOS weather app; accuracy checks)"

    public static func userAgent(for url: URL) -> String {
        switch url.host?.lowercased() {
        case "api.weather.gov": return nwsUserAgent
        case "api.met.no": return metNorwayUserAgent
        case "aviationweather.gov": return awcUserAgent
        default: return genericUserAgent
        }
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.httpAdditionalHeaders = ["Accept-Encoding": "gzip"] // User-Agent is set per request
            config.requestCachePolicy = .reloadIgnoringLocalCacheData // we cache ourselves with explicit TTLs
            config.urlCache = nil
            // No cookies: none of the services need them (Security I1).
            config.httpCookieAcceptPolicy = .never
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let result = try await perform(url, headers: headers, allowConditional: false)
        guard (200..<300).contains(result.statusCode) else { throw HTTPError.status(result.statusCode, url) }
        return result.data
    }

    /// Reads status (including 304/203/204/429) and Last-Modified / Expires without changing `get` behaviour.
    public func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        try await perform(url, headers: headers, allowConditional: true)
    }

    private func perform(_ url: URL, headers: [String: String], allowConditional: Bool) async throws -> HTTPFetchResult {
        guard KnownHosts.isAllowed(url) else { throw HTTPError.disallowedHost(url.host ?? url.absoluteString) }
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(Self.userAgent(for: url), forHTTPHeaderField: "User-Agent") // last: callers can't override
        RequestStats.shared.note()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        // A redirect to somewhere else is refused too.
        guard KnownHosts.isAllowed(http.url ?? url) else { throw HTTPError.disallowedHost(http.url?.host ?? "?") }
        let retry = HTTPError.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        let result = HTTPFetchResult(statusCode: http.statusCode, data: data,
                                     lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                     expires: http.value(forHTTPHeaderField: "Expires"),
                                     retryAfter: retry)
        if allowConditional {
            // Conditional path surfaces 304/203/204/429 to the caller; other errors still throw.
            if result.statusCode == 304 || result.statusCode == 203 || result.statusCode == 204 { return result }
            if result.statusCode == 429 || result.statusCode == 503 { return result }
        }
        // Daily-limit detection lives here (before the generic throttled path). Tests call
        // `OpenMeteoQuota.classify` directly because fake clients bypass `perform`.
        if result.statusCode == 429,
           OpenMeteoQuota.classify(status: 429, host: url.host, body: result.data) == .dailyLimit {
            throw HTTPError.dailyLimit(host: url.host ?? "")
        }
        if result.statusCode == 429 || result.statusCode == 503 {
            throw HTTPError.throttled(result.statusCode, url, retryAfter: retry)
        }
        guard (200..<300).contains(result.statusCode) else { throw HTTPError.status(result.statusCode, url) }
        return result
    }
}
