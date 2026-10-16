import XCTest
@testable import SkylineCore

/// Item 2: new city fetches slow / timing out behind PR #2's back-off and the serialized Open-Meteo lock.
final class FetchReliabilityTests: XCTestCase {
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400)
    let om = "api.open-meteo.com"

    /// Records the order of Open-Meteo forecast GETs; the first one is held so the others queue.
    final class OrderClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        private let lock = NSLock()
        private var _order: [String] = []
        var holdFirst: Duration = .milliseconds(300)
        var order: [String] { lock.lock(); defer { lock.unlock() }; return _order }
        private func note(_ url: URL) -> Int? {
            guard url.host == "api.open-meteo.com" else { return nil }
            let lat = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "latitude" }?.value ?? "?"
            lock.lock(); defer { lock.unlock() }
            _order.append(lat)
            return _order.count
        }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            if note(url) == 1 { try await Task.sleep(for: holdFirst) }
            return try await inner.get(url, headers: headers)
        }
    }

    func city(_ lat: Double) -> WeatherLocation {
        WeatherLocation(name: "C\(lat)", coordinate: Coordinate(latitude: lat, longitude: -74.0))
    }
    func service(_ client: HTTPClient, _ clock: TestClock) -> WeatherService {
        WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
    }

    func testNewCityJumpsTheQueuedRefreshes() async throws {
        let clock = TestClock(fixtureTime)
        let client = OrderClient()
        let s = service(client, clock)
        async let a = s.report(for: city(40.0))                       // holds the lock
        try await Task.sleep(for: .milliseconds(60))
        async let b = s.report(for: city(41.0))                       // queued refresh
        async let c = s.report(for: city(42.0))                       // queued refresh
        try await Task.sleep(for: .milliseconds(60))
        async let d = s.report(for: city(43.0), priority: .interactive) // just added
        _ = try await (a, b, c, d)
        XCTAssertEqual(client.order.first, "40.0000")
        XCTAssertEqual(client.order[1], "43.0000", "the new city goes next, ahead of queued refreshes: \(client.order)")
        XCTAssertEqual(Set(client.order.suffix(2)), ["41.0000", "42.0000"])
    }

    func testStillOneOpenMeteoGetAtATimeWithPriorities() async throws {
        // PR #2's stampede protection is kept: priority reorders the line, never widens it.
        final class Overlap: HTTPClient, @unchecked Sendable {
            let inner = MockHTTPClient()
            private let lock = NSLock()
            private var n = 0, _max = 0
            var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _max }
            private func begin(_ u: URL) -> Bool {
                guard u.host == "api.open-meteo.com" else { return false }
                lock.lock(); n += 1; _max = max(_max, n); lock.unlock(); return true
            }
            private func end() { lock.lock(); n -= 1; lock.unlock() }
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                if begin(url) { try await Task.sleep(for: .milliseconds(40)); end() }
                return try await inner.get(url, headers: headers)
            }
        }
        let client = Overlap()
        let s = service(client, TestClock(fixtureTime))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for (i, lat) in [40.0, 41.0, 42.0, 43.0, 44.0].enumerated() {
                g.addTask { _ = try await s.report(for: self.city(lat), priority: i % 2 == 0 ? .interactive : .background) }
            }
            try await g.waitForAll()
        }
        XCTAssertEqual(client.maxInFlight, 1)
    }

    func testSameCityLoadedTwiceSharesOneGet() async throws {
        let clock = TestClock(fixtureTime)
        let client = OrderClient()
        let s = service(client, clock)
        let x = city(40.0)
        var y = x; y.id = "other-id-same-place" // add + sync apply under another id: same URL
        async let a = s.report(for: x)
        async let b = s.report(for: y)
        _ = try await (a, b)
        XCTAssertEqual(client.order.count, 1, "one forecast GET for one URL: \(client.order)")
    }

    func testFirstFetchWaitsOutAShortBackoffInsteadOfFailing() async throws {
        let clock = TestClock(fixtureTime)
        let client = OrderClient(); client.holdFirst = .zero
        let s = service(client, clock)
        await s.setBackoffSleep { [clock] secs in clock.now = clock.now.addingTimeInterval(secs) }
        await s.setBackoffForTesting(om, until: clock.now.addingTimeInterval(10))
        let r = try await s.report(for: city(40.0), priority: .interactive)
        XCTAssertFalse(r.isOfflineFallback)
        XCTAssertEqual(client.order.count, 1)
    }

    func testBackgroundAndLongBackoffsStillDontHitTheHost() async throws {
        let clock = TestClock(fixtureTime)
        let client = OrderClient(); client.holdFirst = .zero
        let s = service(client, clock)
        await s.setBackoffForTesting(om, until: clock.now.addingTimeInterval(10))
        do { _ = try await s.report(for: city(40.0)); XCTFail("background must not wait or fetch") }
        catch HTTPError.backingOff {}
        await s.setBackoffForTesting(om, until: clock.now.addingTimeInterval(600))
        do { _ = try await s.report(for: city(41.0), priority: .interactive); XCTFail("10 min back-off is not waited") }
        catch HTTPError.backingOff {}
        XCTAssertEqual(client.order, [], "no GET during a back-off")
    }

    // MARK: Retry policy (quiet "updating" state)

    func testTransientFailuresRetryQuicklyAndQuietly() {
        let now = fixtureTime
        for (attempt, want) in FetchRetryPolicy.quickRetries.enumerated() {
            let d = FetchRetryPolicy.decide(error: URLError(.timedOut), attempt: attempt, backoffUntil: nil,
                                            refreshInterval: 900, now: now)
            XCTAssertTrue(d.quiet)
            XCTAssertEqual(d.retryAfter, want, accuracy: 0.001)
        }
        let after = FetchRetryPolicy.decide(error: URLError(.timedOut), attempt: 3, backoffUntil: nil, refreshInterval: 900, now: now)
        XCTAssertFalse(after.quiet, "then the banner, as before")
        XCTAssertEqual(after.retryAfter, 60, accuracy: 0.001)
    }

    func testQuietRetryNeverBeatsTheBackoff() {
        let now = fixtureTime
        let d = FetchRetryPolicy.decide(error: HTTPError.backingOff(host: om, until: now.addingTimeInterval(120)),
                                        attempt: 0, backoffUntil: now.addingTimeInterval(120), refreshInterval: 900, now: now)
        XCTAssertTrue(d.quiet)
        XCTAssertGreaterThanOrEqual(d.retryAfter, 121)
        let t = FetchRetryPolicy.decide(error: HTTPError.throttled(429, URL(string: "https://\(om)")!, retryAfter: 45),
                                        attempt: 1, backoffUntil: nil, refreshInterval: 900, now: now)
        XCTAssertGreaterThanOrEqual(t.retryAfter, 46)
    }

    func testJitterSpreadsCitiesAndRealOfflineStillShows() {
        let a = FetchRetryPolicy.decide(error: URLError(.timedOut), attempt: 0, backoffUntil: nil, refreshInterval: 900, jitterSeed: 1)
        let b = FetchRetryPolicy.decide(error: URLError(.timedOut), attempt: 0, backoffUntil: nil, refreshInterval: 900, jitterSeed: 2)
        XCTAssertNotEqual(a.retryAfter, b.retryAfter)
        XCTAssertLessThanOrEqual(abs(a.retryAfter - b.retryAfter), 3)
        XCTAssertFalse(FetchRetryPolicy.decide(error: URLError(.notConnectedToInternet), attempt: 0, backoffUntil: nil,
                                               refreshInterval: 900).quiet)
        XCTAssertFalse(FetchRetryPolicy.decide(error: HTTPError.status(404, URL(string: "https://x")!), attempt: 0,
                                               backoffUntil: nil, refreshInterval: 900).quiet)
        XCTAssertTrue(FetchRetryPolicy.isTransient(HTTPError.status(503, URL(string: "https://x")!)))
    }

    func testPriority() {
        XCTAssertEqual(FetchRetryPolicy.priority(force: false, hasReport: false), .interactive)
        XCTAssertEqual(FetchRetryPolicy.priority(force: true, hasReport: true), .interactive)
        XCTAssertEqual(FetchRetryPolicy.priority(force: false, hasReport: true), .background)
    }
}
