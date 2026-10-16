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

    /// Holds the first Open-Meteo GET until the test opens it; ordering tests wait on the service's queue
    /// depth instead of sleeping (follow-up: less timing-dependent).
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
    final class GatedClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        let gate = Gate()
        private let lock = NSLock()
        private var _order: [String] = []
        var order: [String] { lock.lock(); defer { lock.unlock() }; return _order }
        private func note(_ url: URL) -> Int? {
            guard url.host == "api.open-meteo.com" else { return nil }
            let lat = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "latitude" }?.value ?? "?"
            lock.lock(); defer { lock.unlock() }
            _order.append(String(lat.prefix(2)))
            return _order.count
        }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            if note(url) == 1 { await gate.wait() }
            return try await inner.get(url, headers: headers)
        }
    }

    func waitForQueue(_ s: WeatherService, depth: Int) async throws {
        for _ in 0..<20_000 {
            if await s.openMeteoQueueDepth() >= depth { return }
            await Task.yield()
        }
        XCTFail("queue never reached \(depth)")
    }
    func waitForFirstGet(_ c: GatedClient) async throws {
        for _ in 0..<20_000 where c.order.isEmpty { await Task.yield() }
    }

    func testNewCityJumpsTheQueuedRefreshes() async throws {
        let client = GatedClient()
        let s = service(client, TestClock(fixtureTime))
        async let a = s.report(for: city(40.0))
        try await waitForFirstGet(client)
        async let b = s.report(for: city(41.0))
        try await waitForQueue(s, depth: 1)
        async let c = s.report(for: city(42.0))
        try await waitForQueue(s, depth: 2)
        async let d = s.report(for: city(43.0), priority: .interactive)
        try await waitForQueue(s, depth: 3)
        await client.gate.release()
        _ = try await (a, b, c, d)
        XCTAssertEqual(client.order, ["40", "43", "41", "42"])
    }

    /// Follow-up M1: a new city that joins a queued background GET for the same URL promotes it.
    func testJoiningNewCityPromotesTheSharedBackgroundGet() async throws {
        let client = GatedClient()
        let s = service(client, TestClock(fixtureTime))
        async let a = s.report(for: city(40.0))
        try await waitForFirstGet(client)
        async let c = s.report(for: city(42.0))                 // queued first
        try await waitForQueue(s, depth: 1)
        async let b = s.report(for: city(41.0))                 // background, behind 42
        try await waitForQueue(s, depth: 2)
        var joiner = city(41.0); joiner.id = "just-added"       // same URL, new city
        async let j = s.report(for: joiner, priority: .interactive)
        // Wait until the join has registered (a counter, not a fixed sleep).
        for _ in 0..<20_000 { if await s.joinedGetCount() > 0 { break }; await Task.yield() }
        let joined = await s.joinedGetCount()
        XCTAssertEqual(joined, 1)
        let depth = await s.openMeteoQueueDepth()
        XCTAssertEqual(depth, 2, "joined, not queued again")
        await client.gate.release()
        _ = try await (a, b, c, j)
        XCTAssertEqual(client.order, ["40", "41", "42"], "promoted ahead of the earlier background GET")
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

    // MARK: Follow-ups

    func testCachedCitiesGetNoQuickRetries() {
        let d = FetchRetryPolicy.decide(error: URLError(.timedOut), attempt: 0, backoffUntil: nil, refreshInterval: 900,
                                        hasReport: true, jitter: 0)
        XCTAssertFalse(d.quiet, "M3: saved data on screen, PR #2 ladder only")
        XCTAssertEqual(d.retryAfter, 60, accuracy: 0.001)
    }

    func testOfflineShowsPromptlyEvenWithoutData() {
        var t = QuietRetryTracker()
        let d = t.failed("a", error: URLError(.notConnectedToInternet), hasReport: false, backoffUntil: nil,
                         refreshInterval: 900)
        XCTAssertFalse(d.quiet, "M2: a real offline is never quiet")
        XCTAssertFalse(t.updating.contains("a"))
    }

    func testUpdatingClearsOnSuccessFailureAndAbandon() {
        var t = QuietRetryTracker()
        _ = t.failed("a", error: URLError(.timedOut), hasReport: false, backoffUntil: nil, refreshInterval: 900)
        XCTAssertTrue(t.updating.contains("a"))
        t.succeeded("a")
        XCTAssertFalse(t.updating.contains("a"), "success clears")
        XCTAssertNil(t.quietAttempts["a"])

        for n in 0..<3 {
            let d = t.failed("b", error: URLError(.timedOut), hasReport: false, backoffUntil: nil, refreshInterval: 900)
            XCTAssertTrue(d.quiet)
        }
        let last = t.failed("b", error: URLError(.timedOut), hasReport: false, backoffUntil: nil, refreshInterval: 900)
        XCTAssertFalse(last.quiet)
        XCTAssertFalse(t.updating.contains("b"), "quick retries used up: banner, not Updating…")
        XCTAssertEqual(t.ladderIndex("b", attempt: 3), 0, "the slow ladder starts at 1 min")

        _ = t.failed("c", error: URLError(.timedOut), hasReport: false, backoffUntil: nil, refreshInterval: 900)
        t.abandoned("c")
        XCTAssertFalse(t.updating.contains("c"), "My Location moved / retry not run: cleared")
    }

    func testWiderJitter() {
        let ids = (0..<200).map { "\(40 + Double($0) / 100),-74.0000" }
        let js = ids.map(FetchRetryPolicy.jitter(for:))
        XCTAssertTrue(js.allSatisfy { $0 >= 0 && $0 < FetchRetryPolicy.maxJitter })
        XCTAssertGreaterThan(Set(js).count, 150, "far more than the old 4 values")
        XCTAssertEqual(FetchRetryPolicy.jitter(for: "x"), FetchRetryPolicy.jitter(for: "x"), "stable per city")
    }
}
