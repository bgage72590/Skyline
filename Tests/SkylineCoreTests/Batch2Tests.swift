import XCTest
@testable import SkylineCore

/// Regression tests for batch 2's core items (T1–T5, T7, T14, L6, L8).
final class Batch2Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11, 2026

    private func record(lead: Double, valid: Date, _ f: [VerificationSource: SourceValues]) -> ForecastRecord {
        ForecastRecord(loc: "x", issued: valid.addingTimeInterval(-lead * 3600), valid: valid,
                       f: Dictionary(uniqueKeysWithValues: f.map { ($0.key.rawValue, $0.value) }))
    }

    // MARK: T1 learned weights

    /// Code Reviewer's case: one old pair (to stretch the calendar span past 3 days) plus one afternoon of
    /// 0–6 h pairs from a single regime used to move weights (ECMWF 1.28×, GFS 0.72×). Now it stays neutral.
    func testWeightsDontLearnFromOneAfternoon() {
        var recs = [VerifiedRecord(record(lead: 3, valid: t0, [.ecmwf: SourceValues(t: 10), .gfs: SourceValues(t: 10)]),
                                   ObservedHour(t: 10))]
        let afternoon = t0.addingTimeInterval(4 * 86400)
        for i in 0..<40 {
            let v = afternoon.addingTimeInterval(Double(i) * 360) // 4 h of pairs
            recs.append(VerifiedRecord(record(lead: 3, valid: v, [.ecmwf: SourceValues(t: 10.5, p: 0),
                                                                  .gfs: SourceValues(t: 12, p: 0)]), ObservedHour(t: 10, wet: false)))
        }
        let scores = AccuracyScorer.score(recs, now: afternoon.addingTimeInterval(5 * 3600), halfLifeDays: 0)
        XCTAssertGreaterThanOrEqual(scores.days, 3, "calendar span alone would have passed the old gate")
        XCTAssertTrue(AdaptiveWeighting.weights(from: scores).isNeutral)
        XCTAssertFalse(AdaptiveWeighting.isReady(scores))

        // The same number of pairs spread over 5 days does learn.
        let spread = (0..<40).map { i in
            VerifiedRecord(record(lead: 3, valid: t0.addingTimeInterval(Double(i) * 3 * 3600),
                                  [.ecmwf: SourceValues(t: 10.5), .gfs: SourceValues(t: 12)]), ObservedHour(t: 10))
        }
        let s2 = AccuracyScorer.score(spread, now: t0.addingTimeInterval(6 * 86400), halfLifeDays: 0)
        let w = AdaptiveWeighting.weights(from: s2)
        XCTAssertGreaterThan(w.multiplier(.temperature, .ecmwf, leadHours: 3), w.multiplier(.temperature, .gfs, leadHours: 3))
        XCTAssertTrue(AdaptiveWeighting.isReady(s2))
    }

    /// "Ready" on the Accuracy screen and the weights in use come from the same rule.
    func testReadyMatchesWeightsInUse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let recs = (1...6).map { h in
            record(lead: Double(h), valid: t0.addingTimeInterval(Double(h) * 3600), [.blend: SourceValues(t: 11), .ecmwf: SourceValues(t: 12)])
        }
        await v.record(recs, key: "x")
        clock.now = t0.addingTimeInterval(7 * 3600)
        let r = await v.report("x")
        XCTAssertEqual(r.status == .ready, !r.weights.isNeutral)
    }

    /// Rain weights compare every source on the same call (amount ≥ 0.2 mm). A source with only a
    /// probability (NWS) isn't scored against amount-based sources; the display tallies are unchanged.
    func testRainWeightUsesAmountForEverySource() {
        let recs = (0..<120).map { i -> VerifiedRecord in
            let wet = i % 3 == 0
            return VerifiedRecord(record(lead: 3, valid: t0.addingTimeInterval(Double(i) * 3 * 3600), [
                .ecmwf: SourceValues(pop: wet ? 10 : 90, p: wet ? 1 : 0),   // right amounts, backwards probability
                .gfs: SourceValues(pop: wet ? 90 : 10, p: wet ? 0 : 1),     // right probability, backwards amounts
                .nws: SourceValues(pop: wet ? 90 : 10),
            ]), ObservedHour(wet: wet))
        }
        let s = AccuracyScorer.score(recs, now: t0.addingTimeInterval(16 * 86400), halfLifeDays: 0)
        let w = AdaptiveWeighting.weights(from: s)
        XCTAssertGreaterThan(w.multiplier(.rain, .ecmwf, leadHours: 3), 1)
        XCTAssertLessThan(w.multiplier(.rain, .gfs, leadHours: 3), 1)
        XCTAssertEqual(w.multiplier(.rain, .nws, leadHours: 3), 1, "no amounts → not scored for rain weight")
        XCTAssertEqual(s.overall[.nws]?.hitRate ?? 0, 1, accuracy: 1e-9, "display tallies still use probability")
    }

    // MARK: T2 headline temperature

    func testBlendedTemperatureInterpolatesToNow() {
        let h = [HourlyForecast(time: t0, temperature: 10, apparentTemperature: 8, weatherCode: 0, isDay: true),
                 HourlyForecast(time: t0.addingTimeInterval(3600), temperature: 14, apparentTemperature: 12, weatherCode: 0, isDay: true)]
        let mid = ForecastBlender.temperature(at: t0.addingTimeInterval(900), hourly: h)
        XCTAssertEqual(mid?.temperature ?? .nan, 11, accuracy: 1e-9)
        XCTAssertEqual(mid?.apparent ?? .nan, 9, accuracy: 1e-9)
        XCTAssertEqual(ForecastBlender.temperature(at: t0, hourly: h)?.temperature, 10)
        XCTAssertNil(ForecastBlender.temperature(at: t0.addingTimeInterval(5 * 3600), hourly: h), "past the data")
    }

    // MARK: T3 per-value NWS parsing

    func testOneBlankNWSValueKeepsTheRest() throws {
        let json = """
        {"properties":{"periods":[
          {"name":"Today","startTime":"2026-10-11T06:00:00-04:00","endTime":"2026-10-11T18:00:00-04:00","isDaytime":true,
           "temperature":66,"temperatureUnit":"F","probabilityOfPrecipitation":{"value":20},"windSpeed":"5 to 10 mph","shortForecast":"Sunny"},
          {"name":"Tonight","startTime":"2026-10-11T18:00:00-04:00","endTime":"2026-10-12T06:00:00-04:00","isDaytime":false,
           "temperature":null,"temperatureUnit":"F","probabilityOfPrecipitation":{"value":40},"windSpeed":"5 mph","shortForecast":"Showers"},
          {"name":"Broken","startTime":"not a date","endTime":"2026-10-12T18:00:00-04:00","isDaytime":true,"temperature":70},
          {"name":"Garbage","isDaytime":"yes"},
          {"name":"Monday","startTime":"2026-10-12T06:00:00-04:00","endTime":"2026-10-12T18:00:00-04:00","isDaytime":true,
           "temperature":71,"temperatureUnit":"F","shortForecast":"Mostly Sunny"}]}}
        """
        let periods = try NWSPeriod.decodeList(Data(json.utf8))
        XCTAssertEqual(periods.map(\.name), ["Today", "Tonight", "Monday"])
        XCTAssertNil(periods[1].temperatureC)
        XCTAssertEqual(periods[1].probabilityOfPrecipitation, 40, "the blank temperature doesn't drop the rain chance")
        XCTAssertEqual(periods[2].temperatureC ?? .nan, fToC(71), accuracy: 1e-9)
        XCTAssertEqual(periods[0].windSpeedKmh ?? 0, 7.5 * 1.609344, accuracy: 1e-9, "T5: range midpoint")
    }

    // MARK: T4 hourly rain-chance alignment

    /// Open-Meteo's value at T covers (T-1, T]. The NWS hour [T-1, T) is the same hour; [T, T+1) is the next.
    func testNWSHourlyPoPPairsWithPrecedingHour() throws {
        let t = 1_800_000_000.0
        let json = """
        {"latitude":40,"longitude":-74,"timezone":"UTC","utc_offset_seconds":0,
         "hourly":{"time":[\(t),\(t + 3600)],"temperature_2m_best_match":[10,10],"precipitation_probability_best_match":[0,0]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        func p(_ start: Double, pop: Double) -> NWSPeriod {
            NWSPeriod(name: "", startTime: Date(timeIntervalSince1970: start), endTime: Date(timeIntervalSince1970: start + 3600),
                      isDaytime: true, temperatureC: 10, probabilityOfPrecipitation: pop, relativeHumidity: nil,
                      windSpeedKmh: nil, windDirection: nil, shortForecast: "", detailedForecast: "")
        }
        // Rain expected 0–1 h after t (the hour ending at t + 3600), dry the hour before.
        let nws = [p(t - 3600, pop: 0), p(t, pop: 100), p(t + 3600, pop: 0)]
        let h = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nws, now: Date(timeIntervalSince1970: t - 7200))
        XCTAssertEqual(h[0].precipitationProbability ?? -1, 0, accuracy: 1e-9, "hour ending at t was dry")
        XCTAssertGreaterThan(h[1].precipitationProbability ?? 0, 40, "hour ending at t+1h is the wet one (NWS 100 % blended with the model 0 %)")
    }

    // MARK: T7 location rounding

    func testCoarseCoordinate() {
        let c = Coordinate(latitude: 41.123456, longitude: -73.987654).coarse
        XCTAssertEqual(c.latitude, 41.12, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, -73.99, accuracy: 1e-9)
        XCTAssertTrue(Endpoints.nwsPoint(c).absoluteString.hasSuffix("/points/41.1200,-73.9900"))
    }

    func testCurrentLocationRequestsAreCoarse() async throws {
        let client = MockHTTPClient()
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil), now: { self.fixtureTime })
        let here = WeatherLocation(id: WeatherLocation.currentLocationID, name: "Here",
                                   coordinate: Coordinate(latitude: 40.712345, longitude: -74.006789), isCurrentLocation: true)
        _ = try await service.report(for: here)
        let urls = client.requests.map(\.absoluteString)
        XCTAssertFalse(urls.contains { $0.contains("40.7123") || $0.contains("74.0068") }, "\(urls)")
        XCTAssertTrue(urls.contains { $0.contains("40.71") })
        // Saved cities keep their 4-decimal precision.
        let saved = WeatherLocation(name: "Saved", coordinate: Coordinate(latitude: 40.712345, longitude: -74.006789))
        _ = try await service.report(for: saved)
        XCTAssertTrue(client.requests.map(\.absoluteString).contains { $0.contains("40.7123") })
    }

    // MARK: T14 readable errors and back-off

    func testReadableErrorMessages() {
        let url = URL(string: "https://api.weather.gov/x")!
        XCTAssertEqual(UserFacingError.message(URLError(.notConnectedToInternet)), "You’re offline.")
        XCTAssertEqual(UserFacingError.message(URLError(.timedOut)), "Weather service didn’t respond.")
        XCTAssertEqual(UserFacingError.message(HTTPError.status(502, url)), "Weather service didn’t respond (error 502).")
        XCTAssertEqual(UserFacingError.message(HTTPError.throttled(429, url, retryAfter: 300)),
                       "Weather service is busy. Skyline will try again in 5 min.")
        XCTAssertFalse(HTTPError.invalidResponse.localizedDescription.contains("HTTPError"))
        XCTAssertFalse(HTTPError.status(500, url).localizedDescription.contains("SkylineCore"))
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(HTTPError.retryAfter("120"), 120)
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri, 15 Jan 2027 08:00:00 GMT
        XCTAssertEqual(HTTPError.retryAfter("Fri, 15 Jan 2027 08:02:00 GMT", now: now) ?? -1, 120, accuracy: 1)
        XCTAssertNil(HTTPError.retryAfter(nil))
        XCTAssertNil(HTTPError.retryAfter("soon"))
    }

    /// Answers 429 (Retry-After 120 s) for Open-Meteo forecasts while `throttled`; fixtures otherwise.
    final class ThrottlingClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        private let lock = NSLock()
        private var _throttled = false, _hits = 0
        var throttled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _throttled }
            set { lock.lock(); _throttled = newValue; lock.unlock() }
        }
        var forecastHits: Int { lock.lock(); defer { lock.unlock() }; return _hits }
        private func note(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let isForecast = url.host == "api.open-meteo.com"
            if isForecast { _hits += 1 }
            return isForecast && _throttled
        }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            if note(url) { throw HTTPError.throttled(429, url, retryAfter: 120) }
            return try await inner.get(url, headers: headers)
        }
    }

    func testBacksOffAfter429AndRespectsRetryAfter() async throws {
        let client = ThrottlingClient()
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let nyc = WeatherLocation(name: "New York", coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
        _ = try await service.report(for: nyc)
        client.throttled = true
        clock.now = fixtureTime.addingTimeInterval(15 * 60)
        let r1 = try await service.report(for: nyc)
        XCTAssertTrue(r1.isOfflineFallback, "429 → cached copy, flagged")
        let hits = client.forecastHits
        let until = await service.backoff(for: "api.open-meteo.com")
        XCTAssertEqual(until?.timeIntervalSince(clock.now) ?? 0, 120, accuracy: 1)

        clock.now = clock.now.addingTimeInterval(60)
        _ = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertEqual(client.forecastHits, hits, "no request to a host inside its Retry-After window")

        clock.now = clock.now.addingTimeInterval(90)
        client.throttled = false
        let r3 = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertEqual(client.forecastHits, hits + 1)
        XCTAssertFalse(r3.isOfflineFallback)
        let cleared = await service.backoff(for: "api.open-meteo.com")
        XCTAssertNil(cleared)
    }

    // MARK: L8 cache clean-up

    func testCachePrune() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = ResponseCache(directory: dir, now: { Date(timeIntervalSince1970: 0) })
        await old.store(Data("old".utf8), for: "a")
        let fresh = ResponseCache(directory: dir, now: { Date(timeIntervalSince1970: 30 * 86400) })
        await fresh.store(Data("new".utf8), for: "b")
        try Data("junk".utf8).write(to: dir.appendingPathComponent("broken.plist"))
        await fresh.prune()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let a = await fresh.stale("a"); XCTAssertNil(a)
        let b = await fresh.stale("b"); XCTAssertNotNil(b)
    }

    func testCacheMemoryIsCapped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ResponseCache(directory: dir)
        for i in 0..<(ResponseCache.memoryLimit + 30) { await cache.store(Data("\(i)".utf8), for: "k\(i)") }
        let count = await cache.memoryCount
        XCTAssertEqual(count, ResponseCache.memoryLimit)
        let first = await cache.stale("k0")
        XCTAssertEqual(first, Data("0".utf8), "evicted from memory, still on disk")
    }
}

/// U1: the identifying User-Agent (with Brian's contact) goes only to NWS; everything else gets "Skyline/1.0".
final class UserAgentTests: XCTestCase {
    func testUserAgentOnlyIdentifiesToNWS() {
        for s in ["https://api.weather.gov/points/40.71,-74.01", "https://api.weather.gov/alerts/active?point=1,2"] {
            XCTAssertEqual(URLSessionHTTPClient.userAgent(for: URL(string: s)!), "Skyline/1.0 (Brian.gage@gmail.com)", s)
        }
        for s in ["https://api.open-meteo.com/v1/forecast", "https://air-quality-api.open-meteo.com/v1/air-quality",
                  "https://geocoding-api.open-meteo.com/v1/search", "https://api.rainviewer.com/public/weather-maps.json",
                  "https://tilecache.rainviewer.com/v2/radar/1/256/1/2/3/2/1_1.png",
                  "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/x/1/2/3.png",
                  "https://api.weather.gov.evil.example/x"] {
            XCTAssertEqual(URLSessionHTTPClient.userAgent(for: URL(string: s)!), "Skyline/1.0", s)
        }
        XCTAssertEqual(URLSessionHTTPClient.genericUserAgent, "Skyline/1.0", "the radar tile downloader's User-Agent")
        XCTAssertFalse(URLSessionHTTPClient.nwsUserAgent.contains("github"))
    }
}
