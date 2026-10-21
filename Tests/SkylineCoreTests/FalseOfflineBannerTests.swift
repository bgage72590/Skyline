import XCTest
@testable import SkylineCore

/// QA, build 88 (3:13 PM): after Refresh on a working network the radar view showed
/// "Offline · showing data from … · Retry" for ~20 minutes. Root cause: one forced Open-Meteo GET in
/// the Refresh burst died in flight (-1005 "network connection lost" on a reused keep-alive, or a 5xx).
/// `fetchEntry` fell straight back to the saved copy, `UserFacingError` called -1005 "You’re offline",
/// and the banner printed "Offline" for any refresh error. The retry then waited on the 1-min ladder
/// (and was dropped while the window was hidden), so the banner stuck.
final class FalseOfflineBannerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_725_400)
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))

    /// Throws the scripted errors on successive Open-Meteo forecast GETs, then answers normally.
    final class FlakyClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        private let lock = NSLock()
        private var script: [Error] = []
        private var _forecastGets = 0
        var forecastGets: Int { lock.lock(); defer { lock.unlock() }; return _forecastGets }
        func fail(with errors: [Error]) { lock.lock(); script = errors; lock.unlock() }
        private func next(_ url: URL) -> Error? {
            guard url.host == "api.open-meteo.com" else { return nil }
            lock.lock(); defer { lock.unlock() }
            _forecastGets += 1
            return script.isEmpty ? nil : script.removeFirst()
        }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            if let e = next(url) { throw e }
            return try await inner.get(url, headers: headers)
        }
    }

    func primed() async throws -> (FlakyClient, TestClock, WeatherService) {
        let client = FlakyClient(), clock = TestClock(t0)
        let s = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        await s.setTransientRetryDelay(0)
        _ = try await s.report(for: nyc)
        clock.now = t0.addingTimeInterval(20 * 60) // past the forecast TTL: Refresh goes to the network
        return (client, clock, s)
    }

    func testDroppedRequestDuringRefreshIsRetriedAndNotShownAsOffline() async throws {
        let (client, _, s) = try await primed()
        let before = client.forecastGets
        client.fail(with: [URLError(.networkConnectionLost)])
        let r = try await s.report(for: nyc, forceRefresh: true, priority: .interactive)
        // A fails once, retries, succeeds; then B (pair half) — three forecast GETs total.
        XCTAssertEqual(client.forecastGets - before, 3, "one immediate second try on A, then B")
        XCTAssertFalse(r.isOfflineFallback, "the second try worked: live data, no banner")
        XCTAssertNil(r.fallbackCause)
        XCTAssertTrue(RefreshBookkeeping.afterReport(isOfflineFallback: r.isOfflineFallback, cause: r.fallbackCause,
                                                     backoffUntil: nil).clearError)
    }

    func testServerTroubleShowsSavedDataButNeverSaysOffline() async throws {
        let (client, _, s) = try await primed()
        client.fail(with: [HTTPError.status(502, URL(string: "https://api.open-meteo.com")!),
                           HTTPError.status(502, URL(string: "https://api.open-meteo.com")!)])
        let r = try await s.report(for: nyc, forceRefresh: true, priority: .interactive)
        XCTAssertTrue(r.isOfflineFallback)
        XCTAssertEqual(r.fallbackCause, .unreachable)
        let follow = RefreshBookkeeping.afterReport(isOfflineFallback: true, cause: r.fallbackCause, backoffUntil: nil)
        XCTAssertEqual(follow.message, RefreshBookkeeping.savedDataMessage)
        XCTAssertEqual(follow.quickRetry, RefreshBookkeeping.quickRetryAfterFallback, "retried in seconds, not after the ladder")
        let offline = RefreshBookkeeping.isReallyOffline(cause: r.fallbackCause, error: follow.message)
        XCTAssertFalse(offline)
        XCTAssertTrue(RefreshBookkeeping.isOffline(isOfflineFallback: true, error: follow.message), "the banner still shows")
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: offline, error: follow.message, dataTime: "3:05 PM"),
                       "Couldn’t update · showing data from 3:05 PM")
    }

    func testNoNetworkStillSaysOffline() async throws {
        let (client, _, s) = try await primed()
        let before = client.forecastGets
        client.inner.offline = true
        client.fail(with: [URLError(.notConnectedToInternet)])
        let r = try await s.report(for: nyc, forceRefresh: true, priority: .interactive)
        XCTAssertEqual(client.forecastGets - before, 1, "no point re-trying with no network")
        XCTAssertEqual(r.fallbackCause, .offline)
        let follow = RefreshBookkeeping.afterReport(isOfflineFallback: true, cause: r.fallbackCause, backoffUntil: nil)
        XCTAssertEqual(follow.message, RefreshBookkeeping.offlineSavedMessage)
        XCTAssertNil(follow.quickRetry)
        let offline = RefreshBookkeeping.isReallyOffline(cause: r.fallbackCause, error: follow.message)
        XCTAssertTrue(offline)
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: offline, error: follow.message, dataTime: "3:05 PM"),
                       "Offline · showing data from 3:05 PM")
    }

    func testOnlyNoNetworkCountsAsOffline() {
        XCTAssertEqual(FallbackCause(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(FallbackCause(URLError(.networkConnectionLost)), .unreachable)
        XCTAssertEqual(FallbackCause(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(FallbackCause(HTTPError.throttled(429, URL(string: "https://api.open-meteo.com")!, retryAfter: 5)), .busy)
        let lost = UserFacingError.message(URLError(.networkConnectionLost))
        XCTAssertNotEqual(lost, UserFacingError.offline)
        XCTAssertFalse(RefreshBookkeeping.isReallyOffline(cause: nil, error: lost))
        XCTAssertTrue(RefreshBookkeeping.isReallyOffline(cause: nil, error: UserFacingError.message(URLError(.notConnectedToInternet))))
        // A thrown non-offline failure: "Couldn’t update", not "Offline".
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: false, error: lost, dataTime: "3:05 PM"),
                       "Couldn’t update · showing data from 3:05 PM")
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: false, error: nil, dataTime: "3:05 PM"),
                       "Showing data from 3:05 PM")
    }

    func testSavedReportsWithoutACauseStillDecode() async throws {
        let (_, _, s) = try await primed()
        var r = try await s.report(for: nyc)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        json["fallbackCause"] = nil // a report saved by an older build
        XCTAssertNil(try JSONDecoder().decode(WeatherReport.self, from: JSONSerialization.data(withJSONObject: json)).fallbackCause)
        r.fallbackCause = .offline
        XCTAssertEqual(try JSONDecoder().decode(WeatherReport.self, from: JSONEncoder().encode(r)).fallbackCause, .offline)
    }
}
