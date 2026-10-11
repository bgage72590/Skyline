import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPError: Error, Sendable, Equatable {
    case status(Int, URL)
    case invalidResponse
    /// 429 or 503: the service asked us to slow down. `retryAfter` is its Retry-After (seconds), if sent.
    case throttled(Int, URL, retryAfter: TimeInterval?)
    /// Not sent: the host asked Skyline to back off and that time hasn't passed yet.
    case backingOff(host: String, until: Date)

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
    public static func message(_ error: Error, now: Date = Date()) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "You’re offline."
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
            case .backingOff(_, let until):
                return "Weather service is busy. Skyline will try again" + wait(until.timeIntervalSince(now)) + "."
            case .status(let code, _) where code >= 500:
                return "Weather service didn’t respond (error \(code))."
            case .status(404, _): return "No weather data for this place."
            case .status(let code, _): return "Weather service refused the request (error \(code))."
            case .invalidResponse: return "Weather service sent data Skyline couldn’t read."
            }
        }
        if error is DecodingError { return "Weather service sent data Skyline couldn’t read." }
        return "Something went wrong loading the weather."
    }

    private static func wait(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s > 0 else { return " shortly" }
        return s < 90 ? " in about a minute" : " in \(Int((s / 60).rounded())) min"
    }
}

/// Minimal async HTTP abstraction so services can be tested with fixtures.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    /// Plain User-Agent for every host except NWS (Open-Meteo, IEM, RainViewer, radar tiles): no name,
    /// no contact.
    public static let genericUserAgent = "Skyline/1.0"
    /// NWS asks for a contact so it can reach the developer before throttling. Sent ONLY to api.weather.gov.
    public static let nwsContact = "Brian.gage@gmail.com"
    public static let nwsUserAgent = "Skyline/1.0 (\(nwsContact))"

    public static func userAgent(for url: URL) -> String {
        url.host?.lowercased() == "api.weather.gov" ? nwsUserAgent : genericUserAgent
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
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue(Self.userAgent(for: url), forHTTPHeaderField: "User-Agent") // last: callers can't override
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        if http.statusCode == 429 || http.statusCode == 503 {
            throw HTTPError.throttled(http.statusCode, url,
                                      retryAfter: HTTPError.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, url) }
        return data
    }
}
