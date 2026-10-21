import Foundation
import SkylineCore

/// QA hook (`-SkylineSimulateOMDailyLimit YES`): answers 429 + daily-limit body for Open-Meteo
/// forecast and air-quality hosts only. Other hosts go to the wrapped client.
/// Builds the error via `OpenMeteoQuota.classify` on the canned body (CR non-blocking note).
struct QuotaLimitHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private let body: Data

    init(inner: HTTPClient = URLSessionHTTPClient(),
         body: Data = Data(#"{"error":true,"reason":"Daily API request limit exceeded. Please try again tomorrow."}"#.utf8)) {
        self.inner = inner
        self.body = body
    }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        let host = url.host?.lowercased() ?? ""
        if OpenMeteoQuota.exactHosts.contains(host) {
            // Mirror URLSessionHTTPClient.perform: classify then throw dailyLimit.
            if OpenMeteoQuota.classify(status: 429, host: host, body: body) == .dailyLimit {
                throw HTTPError.dailyLimit(host: host)
            }
            throw HTTPError.throttled(429, url, retryAfter: nil)
        }
        return try await inner.get(url, headers: headers)
    }
}
