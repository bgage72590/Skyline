import Foundation
import XCTest
@testable import SkylineCore

/// Tiny lock box for RecordingHTTPClient counters (Sendable-friendly).
private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Form 4: rain headline, US bias station/statusLine, MET Norway pending, Decision 2 boundaries.
final class Fix4Tests: XCTestCase {
    private var clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
    private let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                                      coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
    private let paris = WeatherLocation(name: "Paris", country: "France",
                                        coordinate: Coordinate(latitude: 48.85, longitude: 2.35))

    // MARK: QA background TTL override

    func testQABackgroundTTLMinutesOverride() {
        XCTAssertEqual(WeatherService.TTL.background, 10_800)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: ["Skyline"]), 10_800)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: [
            "Skyline", WeatherService.TTL.QABackgroundTTLMinutes.argument, "5"
        ]), 300)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: [
            "Skyline", WeatherService.TTL.QABackgroundTTLMinutes.argument, "0"
        ]), 10_800)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: [
            "Skyline", WeatherService.TTL.QABackgroundTTLMinutes.argument, "-3"
        ]), 10_800)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: [
            "Skyline", WeatherService.TTL.QABackgroundTTLMinutes.argument, "nope"
        ]), 10_800)
        XCTAssertEqual(WeatherService.TTL.effectiveBackground(arguments: [
            "Skyline", WeatherService.TTL.QABackgroundTTLMinutes.argument
        ]), 10_800)
    }

    // MARK: Fix 2 — rain headline

    func testRainHeadlineUsesHitRateNotRainAccuracy() {
        XCTAssertEqual(AccuracySummary.minRainyHoursForHeadline, 12)
        var blend = SourceScore(source: .blend)
        blend.tempAbs = 100; blend.tempN = 100; blend.tempHours = 100
        // ~94% dry hours: rainAccuracy ≈ 95%, hitRate ≈ 54%
        blend.hits = 54; blend.misses = 46
        blend.falseAlarms = 5; blend.correctNegatives = 895
        blend.wetHours = 100; blend.wetHoursCaught = 54
        XCTAssertEqual(blend.rainAccuracy!, 0.949, accuracy: 0.01)
        XCTAssertEqual(blend.hitRate!, 0.54, accuracy: 0.001)

        let r = AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 1000, pendingForecasts: 0,
                               stationID: nil, stationName: nil, overall: [.blend: blend],
                               byBucket: [:], recentWinner: nil, recentWinnerMAE: nil,
                               weights: BlendWeights(), minDays: 3)
        let text = AccuracySummary.headline(r, delta: { String(format: "%.1f°C", $0) })
        XCTAssertTrue(text.contains("Rain: caught 54% of rainy hours"), text)
        XCTAssertTrue(text.contains("(54 of 100 rainy hours)"), text)
        XCTAssertFalse(text.contains("95%"), text)
        XCTAssertFalse(text.contains("Rain calls were right"), text)
    }

    func testRainHeadlineDryHoursDoNotChangePercent() {
        var a = SourceScore(source: .blend)
        a.tempAbs = 10; a.tempN = 10; a.tempHours = 10
        a.hits = 12; a.misses = 0; a.falseAlarms = 0; a.correctNegatives = 100
        a.wetHours = 12; a.wetHoursCaught = 12
        var b = a
        b.falseAlarms = 50; b.correctNegatives = 500
        let ra = AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 100, pendingForecasts: 0,
                                stationID: nil, stationName: nil, overall: [.blend: a], byBucket: [:],
                                recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        let rb = AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 100, pendingForecasts: 0,
                                stationID: nil, stationName: nil, overall: [.blend: b], byBucket: [:],
                                recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        let fa = AccuracySummary.headline(ra, delta: { "\($0)" })
        let fb = AccuracySummary.headline(rb, delta: { "\($0)" })
        XCTAssertTrue(fa.contains("100%"))
        XCTAssertTrue(fb.contains("100%"))
    }

    func testRainHeadlineGuardBoundary() {
        func report(hits: Double, misses: Double) -> AccuracyReport {
            var s = SourceScore(source: .blend)
            s.tempAbs = 1; s.tempN = 1; s.tempHours = 1
            s.hits = hits; s.misses = misses
            s.wetHours = Int(hits + misses); s.wetHoursCaught = Int(hits)
            return AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 20, pendingForecasts: 0,
                                  stationID: nil, stationName: nil, overall: [.blend: s], byBucket: [:],
                                  recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        }
        XCTAssertFalse(AccuracySummary.headline(report(hits: 11, misses: 0), delta: { "\($0)" }).contains("Rain:"))
        XCTAssertTrue(AccuracySummary.headline(report(hits: 12, misses: 0), delta: { "\($0)" }).contains("Rain:"))
        var dry = SourceScore(source: .blend)
        dry.tempAbs = 1; dry.tempN = 1; dry.tempHours = 1
        dry.correctNegatives = 100
        let zero = AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 20, pendingForecasts: 0,
                                  stationID: nil, stationName: nil, overall: [.blend: dry], byBucket: [:],
                                  recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        XCTAssertFalse(AccuracySummary.headline(zero, delta: { "\($0)" }).contains("Rain:"))
    }

    func testRainHeadlineZeroDenominatorAndDedupeCollapsed() {
        // Zero rainy hours → no Rain: clause (hitRate nil).
        var s = SourceScore(source: .blend)
        s.tempAbs = 5; s.tempN = 5; s.tempHours = 5
        s.hits = 0; s.misses = 0; s.wetHours = 0
        let r = AccuracyReport(status: .ready, daysCollected: 14, verifiedPairs: 5, pendingForecasts: 0,
                               stationID: nil, stationName: nil, overall: [.blend: s], byBucket: [:],
                               recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        XCTAssertNil(s.hitRate)
        XCTAssertFalse(AccuracySummary.headline(r, delta: { "\($0)" }).contains("Rain:"))

        // collapsedForScoring: two Macs same valid within 90 min → one scored row.
        let t0 = clock.now
        let a = VerifiedRecord(ForecastRecord(loc: "k", issued: t0, valid: t0.addingTimeInterval(3600),
                                              f: ["blend": SourceValues(t: 10)]),
                               ObservedHour(t: 11, wet: false))
        let b = VerifiedRecord(ForecastRecord(loc: "k", issued: t0.addingTimeInterval(30 * 60),
                                              valid: t0.addingTimeInterval(3600),
                                              f: ["blend": SourceValues(t: 12)]),
                               ObservedHour(t: 11, wet: false))
        let collapsed = AccuracySync.collapsedForScoring([a, b])
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].r.f["blend"]?.t ?? -1, 10, accuracy: 0.01)
    }

    // MARK: Fix 3 — statusLine / gate constants / siting / units

    func testGateThresholdConstants() {
        XCTAssertEqual(BiasCorrection.hourlyGateDays, 7)
        XCTAssertEqual(BiasCorrection.hourlyGatePairs, 300)
        XCTAssertEqual(BiasCorrection.dailyGateDays, 14)
        XCTAssertEqual(BiasCorrection.dailyGatePairs, 20)
        XCTAssertEqual(ForecastVerifier.usStationSeedNegativeCache, BenchmarkStore.secondsPerDay)
        XCTAssertEqual(BenchmarkStore.metPendingExpiry, 2 * BenchmarkStore.secondsPerDay)
    }

    func testStatusLineRealThresholds() {
        let hourly = BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                               nDays: 3, units: { $0 }, target: .h0to6, nPairs: 21)
        XCTAssertEqual(hourly, "off (3/7 days · 21/300 pairs)")
        XCTAssertFalse(hourly.contains("/20 days"))
        let daily = BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                              nDays: 5, units: { $0 }, target: .dailyHigh, nPairs: 10)
        XCTAssertEqual(daily, "off (5/14 days · 10/20 pairs)")
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: false, switchOn: true,
                                                 nDays: 5, units: { $0 }), "off: station")
    }

    func testSitingKBDRLikeAndUnits() {
        XCTAssertTrue(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: 2, cityElevationM: 38))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 30, stationElevationM: 2, cityElevationM: 38))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: 150, cityElevationM: 0))
        XCTAssertTrue(BiasCorrection.sitingPasses(distanceKm: 12, stationElevationM: nil, cityElevationM: nil))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 20, stationElevationM: nil, cityElevationM: nil))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: nil, cityElevationM: 38))

        let near = Coordinate(latitude: 41.16, longitude: -73.13)
        let meters = try! Fixture.data("nws_stations_kbdr")
        let pick = ForecastVerifier.nwsStationPick(data: meters, id: "KBDR", near: near,
                                                   cityElevationM: 38, at: clock.now)
        XCTAssertEqual(pick?.elevationM, 2)
        XCTAssertEqual(pick?.distanceKm ?? 99, 0, accuracy: 1)

        let feet = """
        {"features":[{"properties":{"stationIdentifier":"KBDR","name":"Bridgeport",
        "elevation":{"value":7,"unitCode":"wmoUnit:ft"}},
        "geometry":{"coordinates":[-73.13,41.16]}}]}
        """.data(using: .utf8)!
        let bad = ForecastVerifier.nwsStationPick(data: feet, id: "KBDR", near: near,
                                                  cityElevationM: 38, at: clock.now)
        XCTAssertNil(bad?.elevationM)
    }

    func testGateBoundariesCorrectionZeroUntilMet() {
        func rows(days: Int, pairsPerDay: Int, target: CorrectionTarget) -> [TrainingRow] {
            (0..<days).map { d in
                TrainingRow(loc: "x", localDay: clock.now.addingTimeInterval(Double(-d - 1) * 86400),
                            target: target, sumE: Double(pairsPerDay), n: pairsPerDay, distinct: 1)
            }
        }
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 6, pairsPerDay: 50, target: .h0to6),
                                           target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 7, pairsPerDay: 42, target: .h0to6),
                                           target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertTrue(BiasCorrection.gate(rows: rows(days: 7, pairsPerDay: 43, target: .h0to6),
                                          target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 13, pairsPerDay: 2, target: .dailyHigh),
                                           target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 14, pairsPerDay: 1, target: .dailyHigh),
                                           target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertTrue(BiasCorrection.gate(rows: rows(days: 14, pairsPerDay: 2, target: .dailyHigh),
                                          target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
    }

    func testGatedCorrectionLeavesDisplayTempsUnchanged() {
        // Empty offsets (gate not met) → apply is a no-op for °C display temps (°F formatting is pure).
        var hourly = [HourlyForecast(time: clock.now, temperature: 20, apparentTemperature: 20,
                                     weatherCode: 0, isDay: true)]
        var daily = [DailyForecast(date: clock.now, weatherCode: 0, high: 22, low: 12)]
        var current = CurrentConditions(time: clock.now, temperature: 20, apparentTemperature: 20,
                                        humidity: 50, dewPoint: 10, weatherCode: 0, isDay: true,
                                        precipitation: 0, cloudCover: nil, pressure: nil,
                                        windSpeed: 0, windDirection: nil, windGust: nil,
                                        visibility: nil, uvIndex: nil)
        let beforeH = hourly[0].temperature
        let beforeD = daily[0].high
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current,
                             issued: clock.now, timeZone: .gmt, offsets: [:])
        XCTAssertEqual(hourly[0].temperature, beforeH)
        XCTAssertEqual(daily[0].high, beforeD)
        XCTAssertEqual(current.temperature, 20)
    }

    func testUSStationSeedReplacesMismatchedAndNegativeCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-us-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stationsURL = URL(string: "https://api.weather.gov/gridpoints/OKX/33,42/stations")!
        let stationGets = LockBox(0)
        let client = RecordingHTTPClient { url in
            if url.absoluteString.contains("/stations") {
                stationGets.value += 1
                return try Fixture.data("nws_stations_kbdr")
            }
            if url.absoluteString.contains("/observations") {
                return try Fixture.data("nws_observations")
            }
            throw HTTPError.status(404, url)
        }
        let v = ForecastVerifier(directory: dir, client: client, now: { self.clock.now })
        let key = "bridgeport"
        let near = Coordinate(latitude: 41.16, longitude: -73.13)
        // Seed a mismatched METAR-style station in the benchmark store.
        let wrong = MetarStationPick(stationID: "KJFK", name: "Kennedy",
                                     coordinate: Coordinate(latitude: 40.64, longitude: -73.78),
                                     elevationM: 4, distanceKm: 50, pickedAt: clock.now)
        await v.seedBenchmark(station: wrong, key: key, cityElevationM: 38)

        // Due pending so verifyIfDue runs station().
        let issued = clock.now.addingTimeInterval(-4 * 3600)
        let valid = clock.now.addingTimeInterval(-30 * 60)
        await v.record([ForecastRecord(loc: key, issued: issued, valid: valid,
                                       f: ["blend": SourceValues(t: 10)])], key: key)
        await v.verifyIfDue(key: key, stationsURL: stationsURL, near: near, cityElevationM: 38)
        // After first verify, station should be KBDR from the fixture (nearest ASOS airport).
        let benchDir = await v.benchmarkStoreDirectory()
        let store = BenchmarkStore(directory: benchDir, now: { self.clock.now })
        let pick = await store.station(for: key)
        XCTAssertEqual(pick?.stationID.uppercased(), "KBDR")
        XCTAssertGreaterThanOrEqual(stationGets.value, 1)

        // Negative cache: force a failure window then ensure skip (no repeat seed).
        await store.noteUSStationSeedFailure(key: key,
                                             until: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache))
        let skip = await store.shouldSkipUSStationSeed(key: key, now: clock.now)
        XCTAssertTrue(skip)
        let skipAgain = await store.shouldSkipUSStationSeed(key: key, now: clock.now.addingTimeInterval(3600))
        XCTAssertTrue(skipAgain)
        let afterWindow = await store.shouldSkipUSStationSeed(
            key: key, now: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache + 1))
        XCTAssertFalse(afterWindow)
    }

    func testNonUSMakesNoNWSStationsRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-nonus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nwsStationGets = LockBox(0)
        let client = RecordingHTTPClient { url in
            if url.host?.contains("weather.gov") == true, url.absoluteString.contains("/stations") {
                nwsStationGets.value += 1
            }
            throw HTTPError.status(404, url)
        }
        let store = BenchmarkStore(directory: dir, client: client, now: { self.clock.now })
        _ = await store.ensureStation(key: "paris", near: paris.coordinate, isUS: false, cityElevationM: 35)
        XCTAssertEqual(nwsStationGets.value, 0, "non-US ensureStation must not hit NWS stations")
    }

    // MARK: Fix 4 — MET pending

    func testMetPendingRecordScoreDedupeFreshness() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-met-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = BenchmarkStore(directory: dir, now: { self.clock.now })
        let issued = clock.now
        let hours: [MetNorwayHour] = (1...6).map { lead in
            MetNorwayHour(time: issued.addingTimeInterval(Double(lead) * 3600), temperatureC: 10 + Double(lead))
        }
        // Fresh: fetchedAt == issued → recorded.
        await store.seedMetCache(MetNorwayCacheEntry(loc: "k", fetchedAt: issued, lastModified: nil,
                                                     expires: nil, body: Data(), hourly: hours))
        await store.recordMetPending(key: "k", issued: issued, hours: hours, fetchedAt: issued)
        await store.recordMetPending(key: "k", issued: issued, hours: hours, fetchedAt: issued) // dedupe
        // Stale by +1s past max age → nothing new for a second issuance.
        let oldFetch = issued.addingTimeInterval(-(BenchmarkStore.metNorwaySampleMaxAge + 1))
        await store.recordMetPending(key: "k", issued: issued.addingTimeInterval(60), hours: hours,
                                     fetchedAt: oldFetch)

        // Advance past first lead + 20 min; score.
        clock.now = issued.addingTimeInterval(3600 + 21 * 60)
        let obs = [StationObservation(time: issued.addingTimeInterval(3600), temperatureC: 11,
                                      windKmh: nil, precipLastHourMM: nil, precipitating: false)]
        let pairs = await store.scoreMetPending(key: "k", observations: obs, now: clock.now)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].kind, .metNorway)
        XCTAssertEqual(pairs[0].forecastC, 11, accuracy: 0.01)

        // Boundary: age == maxAge still records.
        let atMax = issued.addingTimeInterval(-BenchmarkStore.metNorwaySampleMaxAge)
        await store.recordMetPending(key: "k2", issued: issued, hours: hours, fetchedAt: atMax)
    }

    func testMetNorwayLeadValuesMatchRecordsLadder() {
        let issued = clock.now
        // Hours on every records ladder lead.
        let hours: [MetNorwayHour] = ForecastSampler.leads.map { lead in
            MetNorwayHour(time: issued.addingTimeInterval(Double(lead) * 3600),
                          temperatureC: Double(lead))
        }
        let leads = ForecastSampler.metNorwayLeadValues(location: "k", issued: issued, hours: hours)
        XCTAssertEqual(leads.map { Int($0.valid.timeIntervalSince(issued) / 3600) }, ForecastSampler.leads)
        // Past-only hour must not appear (future-only pending).
        let pastOnly = [MetNorwayHour(time: issued.addingTimeInterval(-3600), temperatureC: 1)]
        let none = ForecastSampler.metNorwayLeadValues(location: "k", issued: issued, hours: pastOnly)
        XCTAssertTrue(none.isEmpty)
        // recordMetPending also filters valid > issued.
        XCTAssertEqual(leads.count, ForecastSampler.leads.count)
    }

    func testMetPendingExpiryCapAppendNotRewrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-metcap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = BenchmarkStore(directory: dir, now: { self.clock.now })
        let issued = clock.now
        // One future hour.
        let hours = [MetNorwayHour(time: issued.addingTimeInterval(3600), temperatureC: 10)]
        await store.recordMetPending(key: "a", issued: issued, hours: hours, fetchedAt: issued)
        let path = dir.appendingPathComponent("met-pending.jsonl")
        let size1 = (try? Data(contentsOf: path))?.count ?? 0
        // Append a second issuance — file should grow (append), not shrink to a rewrite of one row.
        let issued2 = issued.addingTimeInterval(3 * 3600)
        let hours2 = [MetNorwayHour(time: issued2.addingTimeInterval(3600), temperatureC: 11)]
        await store.recordMetPending(key: "a", issued: issued2, hours: hours2, fetchedAt: issued2)
        let size2 = (try? Data(contentsOf: path))?.count ?? 0
        XCTAssertGreaterThan(size2, size1)

        // Expiry: advance past 2 days; score drops expired without observation.
        clock.now = issued.addingTimeInterval(BenchmarkStore.metPendingExpiry + 3600)
        let left = await store.scoreMetPending(key: "a", observations: [], now: clock.now)
        XCTAssertTrue(left.isEmpty)
    }

    func testMetUserAgentAndIfModifiedSinceAndFixture() throws {
        let url = Endpoints.metNorwayCompact(Coordinate(latitude: 48.85, longitude: 2.35))
        XCTAssertEqual(URLSessionHTTPClient.userAgent(for: url), URLSessionHTTPClient.metNorwayUserAgent)
        let data = try Fixture.data("met_norway_compact")
        let hours = METNorwayClient.decode(data)
        XCTAssertFalse(hours.isEmpty, "Form4 MET fixture must decode")
        // If-Modified-Since is set when a cached lastModified exists (METNorwayClient.fetch).
        XCTAssertNotNil(hours.first?.temperatureC)
    }

    func testShowsMetNorwayRow() {
        let hidden = BenchmarkSummary(rows: [
            .init(kind: .metNorway, tempMAE: 1.0, n: 19, dailyN: 0)
        ])
        XCTAssertFalse(BenchmarkScorer.showsMetNorwayRow(hidden))
        let shown = BenchmarkSummary(rows: [
            .init(kind: .metNorway, tempMAE: 1.0, n: 20, dailyN: 0)
        ])
        XCTAssertTrue(BenchmarkScorer.showsMetNorwayRow(shown))
    }

    // MARK: Decision 2 L / N — pair fetch behaviour

    func testDecision2L_BOnlyAt43199_FullPairAt43200_SingleModelOnAFail() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let urlB = Endpoints.openMeteoForecastB(coord)
        let entryA = await cache.entry(urlA.absoluteString, maxAge: .infinity)
        XCTAssertNotNil(entryA)
        let aStored = entryA!.storedAt

        // A age 43199 → B-only (only keyB written).
        clock.now = aStored.addingTimeInterval(WeatherService.TTL.blendMaxAge - 1)
        let recordingBOnly = RecordingHTTPClient { url in try await MockHTTPClient().get(url, headers: [:]) }
        let svcBOnly = WeatherService(client: recordingBOnly, cache: cache, now: { clock.now })
        let bOnly = try await svcBOnly.fetchOpenMeteoPair(coord, models: models,
                                                          ttl: WeatherService.TTL.background,
                                                          force: false, maxStale: WeatherService.MaxStale.forecast,
                                                          priority: .background, allowNetwork: true,
                                                          lightBackground: true)
        XCTAssertTrue(bOnly.isBOnly)
        XCTAssertFalse(bOnly.isSingleModelB)
        XCTAssertEqual(recordingBOnly.openMeteoForecastURLs.count, 1)
        XCTAssertEqual(recordingBOnly.openMeteoForecastURLs.first?.absoluteString, urlB.absoluteString)
        // B-only must not refresh keyA's storedAt.
        let aAfterBOnly = await cache.entry(urlA.absoluteString, maxAge: .infinity)
        XCTAssertEqual(aAfterBOnly?.storedAt, aStored)

        // Fresh cache for the ≥ blendMaxAge / single-model cases (A age must stay ≥ 43200).
        let cache2 = ResponseCache(directory: nil, now: { clock.now })
        clock.now = Date(timeIntervalSince1970: 1_700_000_000)
        let seeder2 = WeatherService(client: MockHTTPClient(), cache: cache2, now: { clock.now })
        _ = try await seeder2.report(for: nyc)
        let a2 = await cache2.entry(urlA.absoluteString, maxAge: .infinity)!
        clock.now = a2.storedAt.addingTimeInterval(WeatherService.TTL.blendMaxAge)

        let recordingFull = RecordingHTTPClient { url in try await MockHTTPClient().get(url, headers: [:]) }
        let svcFull = WeatherService(client: recordingFull, cache: cache2, now: { clock.now })
        let full = try await svcFull.fetchOpenMeteoPair(coord, models: models,
                                                        ttl: 1,
                                                        force: false, maxStale: WeatherService.MaxStale.forecast,
                                                        priority: .background, allowNetwork: true,
                                                        lightBackground: true)
        XCTAssertFalse(full.isBOnly)
        XCTAssertFalse(full.isSingleModelB)
        let fullOM = recordingFull.openMeteoForecastURLs.map(\.absoluteString)
        XCTAssertTrue(fullOM.contains(urlA.absoluteString))
        XCTAssertTrue(fullOM.contains(urlB.absoluteString))
        let bi = fullOM.firstIndex(of: urlB.absoluteString)!
        let ai = fullOM.firstIndex(of: urlA.absoluteString)!
        XCTAssertLessThan(bi, ai)

        // Separate seed: A aged ≥ blendMaxAge, A GET fails after B → single-model B (no extra B GET).
        let cache3 = ResponseCache(directory: nil, now: { clock.now })
        clock.now = Date(timeIntervalSince1970: 1_700_000_000)
        let seeder3 = WeatherService(client: MockHTTPClient(), cache: cache3, now: { clock.now })
        _ = try await seeder3.report(for: nyc)
        let a3 = await cache3.entry(urlA.absoluteString, maxAge: .infinity)!
        clock.now = a3.storedAt.addingTimeInterval(WeatherService.TTL.blendMaxAge)
        let aFailFlag = LockBox(false)
        let recordingSingle = RecordingHTTPClient { url in
            if url.absoluteString == urlA.absoluteString {
                aFailFlag.value = true
                throw URLError(.timedOut)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svcSingle = WeatherService(client: recordingSingle, cache: cache3, now: { clock.now })
        let single = try await svcSingle.fetchOpenMeteoPair(coord, models: models,
                                                            ttl: 1, force: false,
                                                            maxStale: WeatherService.MaxStale.forecast,
                                                            priority: .background, allowNetwork: true,
                                                            lightBackground: true)
        XCTAssertTrue(aFailFlag.value)
        XCTAssertTrue(single.isSingleModelB)
        XCTAssertTrue(single.isBOnly)
        XCTAssertEqual(recordingSingle.openMeteoForecastURLs.filter { $0.absoluteString == urlB.absoluteString }.count, 1)
    }

    func testDecision2L_BOnlyFailureReturnsCachedPairNoFurtherGETs() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let live = try await seeder.report(for: nyc)
        let liveAsOf = live.forecastAsOf
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let entryA = await cache.entry(urlA.absoluteString, maxAge: .infinity)!
        clock.now = entryA.storedAt.addingTimeInterval(1_000) // still < blendMaxAge
        let omGets = LockBox(0)
        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                omGets.value += 1
                throw URLError(.timedOut)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        let pair = try await svc.fetchOpenMeteoPair(coord, models: models,
                                                    ttl: 1, force: false,
                                                    maxStale: WeatherService.MaxStale.forecast,
                                                    priority: .background, allowNetwork: true,
                                                    lightBackground: true)
        XCTAssertTrue(pair.isFallback)
        XCTAssertEqual(omGets.value, 1, "B-only failure must not issue further OM GETs")
        XCTAssertEqual(pair.storedAt, liveAsOf ?? pair.storedAt)
    }

    func testDecision2L_Quota429DoesNotFetchBAfter() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let urlB = Endpoints.openMeteoForecastB(coord)
        let entryA = await cache.entry(urlA.absoluteString, maxAge: .infinity)!
        clock.now = entryA.storedAt.addingTimeInterval(WeatherService.TTL.blendMaxAge)
        let body = try Fixture.data("om_daily_limit_429")
        let sawBAfterA429 = LockBox(false)
        let sawA429 = LockBox(false)
        let recording = RecordingHTTPClient { url in
            if url.absoluteString == urlA.absoluteString {
                sawA429.value = true
                if OpenMeteoQuota.classify(status: 429, host: url.host, body: body) == .dailyLimit {
                    throw HTTPError.dailyLimit(host: url.host ?? "")
                }
            }
            if url.absoluteString == urlB.absoluteString, sawA429.value {
                sawBAfterA429.value = true
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        let pair = try await svc.fetchOpenMeteoPair(coord, models: models,
                                                    ttl: 1, force: false,
                                                    maxStale: WeatherService.MaxStale.forecast,
                                                    priority: .background, allowNetwork: true,
                                                    lightBackground: true)
        XCTAssertTrue(sawA429.value)
        XCTAssertFalse(sawBAfterA429.value, "must not GET B after an A 429")
        // B was fetched first; single-model B from those bytes.
        XCTAssertTrue(pair.isSingleModelB)
        XCTAssertEqual(recording.openMeteoForecastURLs.filter { $0.absoluteString == urlB.absoluteString }.count, 1)
    }

    func testDecision2L_BOnlySkipsIssuanceAndAccuracySample() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-iss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = MockHTTPClient()
        let seeder = WeatherService(client: client, cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        let urlA = Endpoints.openMeteoForecastA(nyc.coordinate.rounded, models: ForecastModel.models(inCONUS: true))
        let entryA = await cache.entry(urlA.absoluteString, maxAge: .infinity)!
        clock.now = entryA.storedAt.addingTimeInterval(WeatherService.TTL.background + 60)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        let wants = await v.wantsIssuance(VerificationKey.key(for: nyc))
        XCTAssertTrue(wants)
        let svc = WeatherService(client: client, cache: cache, verifier: v, now: { clock.now })
        _ = try await svc.report(for: nyc, role: .background, lightBackground: true)
        try await Task.sleep(for: .milliseconds(400))
        let pending = dir.appendingPathComponent("pending.jsonl")
        let hasPending = FileManager.default.fileExists(atPath: pending.path)
            && ((try? Data(contentsOf: pending))?.isEmpty == false)
        XCTAssertFalse(hasPending, "B-only refresh must not record an issuance")
    }

    func testDecision2N_NotifyReuseAt20MinStillFetchesAlerts() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        clock.now = clock.now.addingTimeInterval(20 * 60) // within notifyReuseHidden (30 min)
        let recording = RecordingHTTPClient { url in try await MockHTTPClient().get(url, headers: [:]) }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        _ = try await svc.report(for: nyc, role: .freshCadence, windowVisible: false, isNotifyCity: true)
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0, "OM reused at 20 min while hidden notify")
        XCTAssertTrue(recording.urls.contains { $0.absoluteString.contains("api.weather.gov/alerts") },
                      "NWS alerts still requested on the notify tick")
    }

    func testPairConsistentSyntheticTimestampsAllowOlderA() throws {
        // Documents loadBOnly's content-only check: identical synthetic storedAts.
        let full = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let halves = full.splitPairHalves()
        let tB = clock.now
        let tAOlder = tB.addingTimeInterval(-3_600)
        XCTAssertFalse(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: tAOlder,
                                                         halves.b, storedAtB: tB),
                       "real ages differ by >120s → rejected")
        XCTAssertTrue(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: tB,
                                                        halves.b, storedAtB: tB),
                      "identical synthetic timestamps → content-only check (B-fresh/A-older allowed)")
        // Form4b: content-only helper accepts the same halves without storedAt.
        XCTAssertTrue(OpenMeteoResponse.pairContentConsistent(halves.a, halves.b))
    }

    // MARK: Fix 1 helpers (planner-level; store wake catch-up listed unimplemented if not covered)

    func testFix1StaggerSpacingAndDailyLimitedStillDue() {
        let d0 = RefreshPlanner.nextDequeueDelay(lastDequeueAt: nil, now: clock.now, id: "a")
        XCTAssertEqual(d0, 0)
        let last = clock.now
        let d1 = RefreshPlanner.nextDequeueDelay(lastDequeueAt: last, now: last, id: "a")
        XCTAssertGreaterThanOrEqual(d1, 15)
        XCTAssertFalse(RefreshPlanner.stillDue(id: "a", pairAge: 10_800, role: .background,
                                               wantsIssuance: false, windowVisible: false, dailyLimited: true),
                       "daily-limited background never dequeues")
    }

    // MARK: Form4b — B-newer cached-pair readback (plan-fix4b)

    /// B is always `bGap` newer than A; then advance so A's age is `aAge`.
    private func seedBNewerPair(cache: ResponseCache, clock: TestClock, location: WeatherLocation,
                                aAge: TimeInterval,
                                bGap: TimeInterval = 3 * 3600,
                                mutateB: ((inout OpenMeteoResponse) -> Void)? = nil) async throws -> (urlA: String, urlB: String, tA: Date, tB: Date) {
        let coord = location.coordinate.rounded
        let models = ForecastModel.models(inCONUS: location.isInCONUS)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models).absoluteString
        let urlB = Endpoints.openMeteoForecastB(coord).absoluteString
        let fixture = location.isInCONUS ? "om_nyc" : "om_paris"
        let halves = try OpenMeteoResponse.decode(Fixture.data(fixture)).splitPairHalves()
        var bHalf = halves.b
        mutateB?(&bHalf)
        let tA = Date(timeIntervalSince1970: 1_700_000_000)
        clock.now = tA
        await cache.store(try OpenMeteoResponse.encode(halves.a), for: urlA)
        let tB = tA.addingTimeInterval(bGap)
        clock.now = tB
        await cache.store(try OpenMeteoResponse.encode(bHalf), for: urlB)
        clock.now = tA.addingTimeInterval(aAge)
        return (urlA, urlB, tA, tB)
    }

    // (a)
    func testBNewerPairAcceptedAt43199() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                              aAge: WeatherService.TTL.blendMaxAge - 1)
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let pair = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                    models: ForecastModel.models(inCONUS: true),
                                                    ttl: WeatherService.TTL.background, force: false,
                                                    maxStale: WeatherService.MaxStale.forecast,
                                                    priority: .background, allowNetwork: false,
                                                    lightBackground: true)
        XCTAssertTrue(pair.isBOnly)
        XCTAssertEqual(pair.storedAt, seeded.tB)
        XCTAssertEqual(pair.halfA.storedAt, seeded.tA)
        // B age ≫ ttl on allowNetwork:false → isFallback (lock #5).
        XCTAssertTrue(pair.isFallback)
    }

    func testBNewerPairRejectedAt43200() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        _ = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                     aAge: WeatherService.TTL.blendMaxAge)
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        do {
            _ = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                 models: ForecastModel.models(inCONUS: true),
                                                 ttl: WeatherService.TTL.background, force: false,
                                                 maxStale: WeatherService.MaxStale.forecast,
                                                 priority: .background, allowNetwork: false,
                                                 lightBackground: true)
            XCTFail("A age == blendMaxAge must reject B-newer cache read")
        } catch {
            // expected: nil cache → throw on cache-only
        }
    }

    func testBNewerPairRejectedAt43201() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        _ = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                     aAge: WeatherService.TTL.blendMaxAge + 1)
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        do {
            _ = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                 models: ForecastModel.models(inCONUS: true),
                                                 ttl: WeatherService.TTL.background, force: false,
                                                 maxStale: WeatherService.MaxStale.forecast,
                                                 priority: .background, allowNetwork: false,
                                                 lightBackground: true)
            XCTFail("A age > blendMaxAge must reject B-newer cache read")
        } catch {
            // expected
        }
    }

    // (b) + L1
    func testRelaunchAfterBOnlyRefreshNoNetwork() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models).absoluteString
        let aBefore = await cache.entry(urlA, maxAge: .infinity)!
        let aBytesBefore = aBefore.data
        let aStoredBefore = aBefore.storedAt

        clock.now = aStoredBefore.addingTimeInterval(WeatherService.TTL.background + 60)
        let live = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let bOnly = try await live.fetchOpenMeteoPair(coord, models: models,
                                                      ttl: 1, force: false,
                                                      maxStale: WeatherService.MaxStale.forecast,
                                                      priority: .background, allowNetwork: true,
                                                      lightBackground: true)
        XCTAssertTrue(bOnly.isBOnly)
        let bStored = bOnly.storedAt

        let aAfter = await cache.entry(urlA, maxAge: .infinity)!
        XCTAssertEqual(aAfter.storedAt, aStoredBefore)
        XCTAssertEqual(aAfter.data, aBytesBefore)

        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                XCTFail("relaunch must not GET Open-Meteo forecast")
                throw URLError(.notConnectedToInternet)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let relaunch = WeatherService(client: recording, cache: cache, now: { clock.now })
        let report = try await relaunch.report(for: nyc, allowNetwork: false, role: .background)
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0)
        XCTAssertEqual(report.forecastAsOf, bStored)
        let pairAge = clock.now.timeIntervalSince(bStored)
        let due = RefreshPlanner.due(cities: [nyc], pairAges: [nyc.id: pairAge],
                                     roles: [nyc.id: .background], windowVisible: false)
        XCTAssertFalse(due.background.contains(nyc.id))
        XCTAssertFalse(RefreshPlanner.stillDue(id: nyc.id, pairAge: pairAge, role: .background,
                                               wantsIssuance: false, windowVisible: false,
                                               dailyLimited: false))
    }

    // (c)
    func testOfflineFallbackBNewerPair() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                              aAge: WeatherService.TTL.blendMaxAge - 60)
        let recording = RecordingHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        clock.now = seeded.tA.addingTimeInterval(WeatherService.TTL.blendMaxAge - 30)
        let report = try await svc.report(for: nyc, role: .background)
        XCTAssertTrue(report.isOfflineFallback)
        XCTAssertEqual(report.fallbackCause, .offline)
        XCTAssertEqual(report.forecastAsOf, seeded.tB)
        // One failed B GET (lightBackground), then cached pair — no A GET / no further OM.
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 1)
        XCTAssertEqual(recording.openMeteoForecastURLs.first?.absoluteString, seeded.urlB)
    }

    // (d)
    func testBackoffFallbackBNewerPair() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                              aAge: WeatherService.TTL.blendMaxAge - 60)
        let recording = RecordingHTTPClient { _ in
            XCTFail("backoff must not GET")
            throw URLError(.timedOut)
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        await svc.setBackoffForTesting(OpenMeteoQuota.forecastHost,
                                       until: clock.now.addingTimeInterval(600))
        let before = await svc.backoff(for: OpenMeteoQuota.forecastHost)
        let pair = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                    models: ForecastModel.models(inCONUS: true),
                                                    ttl: 1, force: false,
                                                    maxStale: WeatherService.MaxStale.forecast,
                                                    priority: .background, allowNetwork: true,
                                                    lightBackground: true)
        XCTAssertTrue(pair.isFallback)
        XCTAssertEqual(pair.cause, .busy)
        XCTAssertEqual(pair.storedAt, seeded.tB)
        XCTAssertTrue(pair.isBOnly)
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0)
        let after = await svc.backoff(for: OpenMeteoQuota.forecastHost)
        XCTAssertEqual(after, before, "backoff must not be cleared")
    }

    // (e)
    func testDailyLimitFallbackBNewerPairUS() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                              aAge: WeatherService.TTL.blendMaxAge - 60)
        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                XCTFail("daily-limited must not GET OM forecast")
                throw HTTPError.dailyLimit(host: OpenMeteoQuota.forecastHost)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        await svc.setDailyLimitForTesting(OpenMeteoQuota.forecastHost,
                                          until: clock.now.addingTimeInterval(6 * 3600),
                                          lastProbeAt: clock.now, jitter: 0)
        let report = try await svc.report(for: nyc, role: .background)
        XCTAssertEqual(report.forecastAsOf, seeded.tB)
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0)
    }

    func testDailyLimitFallbackBNewerPairNonUS() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: paris,
                                              aAge: WeatherService.TTL.blendMaxAge - 60)
        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                XCTFail("daily-limited must not GET OM forecast")
                throw HTTPError.dailyLimit(host: OpenMeteoQuota.forecastHost)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        await svc.setDailyLimitForTesting(OpenMeteoQuota.forecastHost,
                                          until: clock.now.addingTimeInterval(6 * 3600),
                                          lastProbeAt: clock.now, jitter: 0)
        let report = try await svc.report(for: paris, role: .background)
        XCTAssertEqual(report.forecastAsOf, seeded.tB)
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0)
        XCTAssertNotEqual(report.forecastMode, .nwsOnly, "non-US must keep OM stale pair, not NWS-only")
    }

    // (f)
    func testBNewerPairHourlyTimeMismatchRejected() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        _ = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                     aAge: WeatherService.TTL.blendMaxAge - 1) { b in
            if var hourly = b.hourly, let t = hourly["time"] {
                hourly["time"] = t.map { $0.map { $0 + 3600 } }
                b.hourly = hourly
            }
        }
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        do {
            _ = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                 models: ForecastModel.models(inCONUS: true),
                                                 ttl: WeatherService.TTL.background, force: false,
                                                 maxStale: WeatherService.MaxStale.forecast,
                                                 priority: .background, allowNetwork: false)
            XCTFail("hourly.time mismatch must reject")
        } catch { /* expected */ }
    }

    func testBNewerPairDailyTimeMismatchRejected() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        _ = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                     aAge: WeatherService.TTL.blendMaxAge - 1) { b in
            if var daily = b.daily, let t = daily["time"] {
                daily["time"] = t.map { $0.map { $0 + 86_400 } }
                b.daily = daily
            }
        }
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        do {
            _ = try await svc.fetchOpenMeteoPair(nyc.coordinate.rounded,
                                                 models: ForecastModel.models(inCONUS: true),
                                                 ttl: WeatherService.TTL.background, force: false,
                                                 maxStale: WeatherService.MaxStale.forecast,
                                                 priority: .background, allowNetwork: false)
            XCTFail("daily.time mismatch must reject")
        } catch { /* expected */ }
    }

    // (g)
    func testViewedCityStillFetchesFullPair() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models).absoluteString
        let urlB = Endpoints.openMeteoForecastB(coord).absoluteString
        let halves = try OpenMeteoResponse.decode(Fixture.data("om_nyc")).splitPairHalves()
        let tA = clock.now
        await cache.store(try OpenMeteoResponse.encode(halves.a), for: urlA)
        clock.now = tA.addingTimeInterval(2 * 3600 - 60)
        await cache.store(try OpenMeteoResponse.encode(halves.b), for: urlB)
        clock.now = tA.addingTimeInterval(2 * 3600)
        let recording = RecordingHTTPClient { url in try await MockHTTPClient().get(url, headers: [:]) }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        _ = try await svc.fetchOpenMeteoPair(coord, models: models,
                                             ttl: WeatherService.TTL.forecast, force: false,
                                             maxStale: WeatherService.MaxStale.forecast,
                                             priority: .interactive, allowNetwork: true,
                                             lightBackground: false)
        let om = recording.openMeteoForecastURLs.map(\.absoluteString)
        XCTAssertTrue(om.contains(urlA))
        XCTAssertTrue(om.contains(urlB))
    }

    // (h)
    func testCachedBNewerPairNoIssuance() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        // A hours old but still within background TTL so the TTL cache hit fires (0 GETs);
        // B age under TTL.forecast so issuanceOK's age gate would otherwise pass.
        let bGap: TimeInterval = 2 * 3600
        let aAge: TimeInterval = 2 * 3600 + 60
        let seeded = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                              aAge: aAge, bGap: bGap)
        XCTAssertLessThan(clock.now.timeIntervalSince(seeded.tB), WeatherService.TTL.forecast)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("form4b-iss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = MockHTTPClient()
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        let wants = await v.wantsIssuance(VerificationKey.key(for: nyc))
        XCTAssertTrue(wants)
        let recording = RecordingHTTPClient { url in try await client.get(url, headers: [:]) }
        let svc = WeatherService(client: recording, cache: cache, verifier: v, now: { clock.now })
        _ = try await svc.report(for: nyc, role: .background)
        try await Task.sleep(for: .milliseconds(400))
        let pending = dir.appendingPathComponent("pending.jsonl")
        let hasPending = FileManager.default.fileExists(atPath: pending.path)
            && ((try? Data(contentsOf: pending))?.isEmpty == false)
        XCTAssertFalse(hasPending, "cached B-newer pair must not record an issuance")
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0, "must be a cache hit, no OM GET")
    }

    // (i)
    func testAOldOfflineUnchanged() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        _ = try await seedBNewerPair(cache: cache, clock: clock, location: nyc,
                                     aAge: WeatherService.TTL.blendMaxAge)
        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                XCTFail("must not GET OM when A ≥ blendMaxAge offline")
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svc = WeatherService(client: recording, cache: cache, now: { clock.now })
        // Cache-only: A ≥ blendMaxAge → readCachedPair nil; no OM GET (pair miss throws or NWS-only).
        do {
            _ = try await svc.report(for: nyc, allowNetwork: false, role: .background)
        } catch {
            // Pair miss without dailyLimit throws; US NWS-only only on the limited path.
        }
        XCTAssertEqual(recording.openMeteoForecastURLs.count, 0)

        let cacheP = ResponseCache(directory: nil, now: { clock.now })
        clock.now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await seedBNewerPair(cache: cacheP, clock: clock, location: paris,
                                     aAge: WeatherService.TTL.blendMaxAge)
        let recP = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost {
                XCTFail("no OM when A ≥ blendMaxAge and limited")
                throw HTTPError.dailyLimit(host: OpenMeteoQuota.forecastHost)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let svcP = WeatherService(client: recP, cache: cacheP, now: { clock.now })
        await svcP.setDailyLimitForTesting(OpenMeteoQuota.forecastHost,
                                           until: clock.now.addingTimeInterval(6 * 3600),
                                           lastProbeAt: clock.now, jitter: 0)
        do {
            _ = try await svcP.report(for: paris, role: .background)
            XCTFail("non-US with A ≥ blendMaxAge and limited must throw dailyLimit")
        } catch let e as HTTPError {
            if case .dailyLimit = e { /* expected */ }
            else { XCTFail("\(e)") }
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(recP.openMeteoForecastURLs.count, 0)
    }

    // (j)
    func testBOlderThanABeyondSlackRejected() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models).absoluteString
        let urlB = Endpoints.openMeteoForecastB(coord).absoluteString
        let halves = try OpenMeteoResponse.decode(Fixture.data("om_nyc")).splitPairHalves()
        let tB = clock.now
        await cache.store(try OpenMeteoResponse.encode(halves.b), for: urlB)
        clock.now = tB.addingTimeInterval(3 * 3600)
        await cache.store(try OpenMeteoResponse.encode(halves.a), for: urlA)
        clock.now = tB.addingTimeInterval(3 * 3600 + 60)
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        do {
            _ = try await svc.fetchOpenMeteoPair(coord, models: models,
                                                 ttl: WeatherService.TTL.background, force: false,
                                                 maxStale: WeatherService.MaxStale.forecast,
                                                 priority: .background, allowNetwork: false)
            XCTFail("B older than A by > slack must reject")
        } catch { /* expected */ }
    }

    // L2
    func testNormalPairReadbackMinStoredAtNotBOnly() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models).absoluteString
        let urlB = Endpoints.openMeteoForecastB(coord).absoluteString
        let halves = try OpenMeteoResponse.decode(Fixture.data("om_nyc")).splitPairHalves()
        let tA = clock.now
        await cache.store(try OpenMeteoResponse.encode(halves.a), for: urlA)
        clock.now = tA.addingTimeInterval(60)
        let tB = clock.now
        await cache.store(try OpenMeteoResponse.encode(halves.b), for: urlB)
        clock.now = tB.addingTimeInterval(30)
        let svc = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let pair = try await svc.fetchOpenMeteoPair(coord, models: models,
                                                    ttl: WeatherService.TTL.background, force: false,
                                                    maxStale: WeatherService.MaxStale.forecast,
                                                    priority: .background, allowNetwork: false)
        XCTAssertFalse(pair.isBOnly)
        XCTAssertEqual(pair.storedAt, min(tA, tB))
        XCTAssertEqual(pair.halfA.storedAt, tA)
        XCTAssertEqual(pair.halfB.storedAt, tB)
    }
}
