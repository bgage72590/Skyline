import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPError: Error, Sendable, Equatable {
    case status(Int, URL)
    case invalidResponse
}

/// Minimal async HTTP abstraction so services can be tested with fixtures.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    /// NWS requires an identifying User-Agent; other services are happy with it too.
    public static let userAgent = "Skyline/1.0 (personal macOS weather app; github.com/briangage/Skyline)"

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Encoding": "gzip"]
            config.requestCachePolicy = .reloadIgnoringLocalCacheData // we cache ourselves with explicit TTLs
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, url) }
        return data
    }
}
