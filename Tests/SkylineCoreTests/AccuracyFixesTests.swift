import Foundation
import XCTest
@testable import SkylineCore

/// Tiny lock box for RecordingHTTPClient counters (Sendable-friendly).
private final class AFLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Accuracy fixes (station seeding, wind decimals, Forecast Confidence). Static fixtures only.
final class AccuracyFixesTests: XCTestCase {
    private let stationsURL = URL(string: "https://api.weather.gov/gridpoints/OKX/33,42/stations")!
    private let near = Coordinate(latitude: 41.16, longitude: -73.13)
    private let nycTZ = TimeZone(identifier: "America/New_York")!
    private let honoluluTZ = TimeZone(identifier: "Pacific/Honolulu")!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
        super.tearDown()
    }

    private func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("af-\(name)-\(UUID().uuidString)")
    }

    private func recordingClient(stationGets: AFLockBox<Int>,
                                 obsGets: AFLockBox<Int> = AFLockBox(0),
                                 failStations: Bool = false) -> RecordingHTTPClient {
        RecordingHTTPClient { url in
            if url.absoluteString.contains("/stations") {
                stationGets.value += 1
                if failStations { throw URLError(.notConnectedToInternet) }
                return try Fixture.data("nws_stations_kbdr")
            }
            if url.absoluteString.contains("/observations") {
                obsGets.value += 1
                return try Fixture.data("nws_observations")
            }
            throw HTTPError.status(404, url)
        }
    }

    // MARK: 1. Station seeding

    func testStationSeededAtLaunchBeforeThrottle() async throws {
        let dir = tempDir("seed-cached")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        // Cached fresh verification ID, no benchmark station, lastObsCheck 1 min ago, due empty.
        await v.seedVerificationStationMeta(key: "bridgeport", stationID: "KBDR",
                                            stationName: "Bridgeport", fetched: clock.now.addingTimeInterval(-3600),
                                            lastObsCheck: clock.now.addingTimeInterval(-60))
        let before = await v.benchmarkStation(for: "bridgeport")
        XCTAssertNil(before)
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 1)
        let pick = await v.benchmarkStation(for: "bridgeport")
        XCTAssertEqual(pick?.stationID.uppercased(), "KBDR")
        let obsCheck = await v.lastObsCheck(for: "bridgeport")
        XCTAssertEqual(obsCheck, clock.now.addingTimeInterval(-60), "seed must not touch lastObsCheck")
    }

    func testFreshInstallNoCachedIDSeedsWithOneGET() async throws {
        let dir = tempDir("seed-fresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        // No stationID, no lastObsCheck, due empty.
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 1)
        let seeded = await v.benchmarkStation(for: "bridgeport")
        XCTAssertEqual(seeded?.stationID.uppercased(), "KBDR")
        let vid = await v.verificationStationID(for: "bridgeport")
        XCTAssertEqual(vid?.uppercased(), "KBDR")
        // Verify path again → 0 more GETs.
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 1)
    }

    func testFreshFetchFailureRecordsBackoff() async throws {
        let dir = tempDir("seed-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets, failStations: true)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 1)
        let skipNow = await v.shouldSkipUSStationSeed(key: "bridgeport", now: clock.now)
        let skipNearEnd = await v.shouldSkipUSStationSeed(
            key: "bridgeport",
            now: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache - 1))
        let skipAfter = await v.shouldSkipUSStationSeed(
            key: "bridgeport",
            now: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache + 1))
        XCTAssertTrue(skipNow)
        XCTAssertTrue(skipNearEnd)
        XCTAssertFalse(skipAfter)
    }

    func testConcurrentVerifyOneGET() async throws {
        let dir = tempDir("seed-conc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = RecordingHTTPClient { url in
            if url.absoluteString.contains("/stations") {
                gets.value += 1
                try await Task.sleep(nanoseconds: 50_000_000)
                return try Fixture.data("nws_stations_kbdr")
            }
            throw HTTPError.status(404, url)
        }
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        async let a: Void = v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        async let b: Void = v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        _ = await (a, b)
        XCTAssertEqual(gets.value, 1)
        let concPick = await v.benchmarkStation(for: "bridgeport")
        XCTAssertEqual(concPick?.stationID.uppercased(), "KBDR")
    }

    func testNilForecastPointNoGET() async throws {
        let dir = tempDir("seed-nilpt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: nil, cityElevationM: 38)
        XCTAssertEqual(gets.value, 0)
        let none = await v.benchmarkStation(for: "bridgeport")
        XCTAssertNil(none)
    }

    func testSeedPreservesHistory() async throws {
        let dir = tempDir("seed-hist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        let other = "other-city"
        await v.seedVerificationStationMeta(key: other, stationID: "KLGA", fetched: clock.now.addingTimeInterval(-86400),
                                            lastObsCheck: clock.now.addingTimeInterval(-120))
        let issued = clock.now.addingTimeInterval(-4 * 3600)
        let valid = clock.now.addingTimeInterval(3600) // future → not due
        await v.record([ForecastRecord(loc: "bridgeport", issued: issued, valid: valid,
                                       f: ["blend": SourceValues(t: 10)])], key: "bridgeport")
        await v.record([ForecastRecord(loc: other, issued: issued, valid: valid,
                                       f: ["blend": SourceValues(t: 11)])], key: other)
        let pendBefore = await v.pendingCount(for: "bridgeport")
        let verBefore = await v.verifiedCount(for: "bridgeport")
        let otherID = await v.verificationStationID(for: other)
        let otherObs = await v.lastObsCheck(for: other)
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        let pendAfter = await v.pendingCount(for: "bridgeport")
        let verAfter = await v.verifiedCount(for: "bridgeport")
        let otherIDAfter = await v.verificationStationID(for: other)
        let otherObsAfter = await v.lastObsCheck(for: other)
        XCTAssertEqual(pendAfter, pendBefore)
        XCTAssertEqual(verAfter, verBefore)
        XCTAssertEqual(otherIDAfter, otherID)
        XCTAssertEqual(otherObsAfter, otherObs)
        let histPick = await v.benchmarkStation(for: "bridgeport")
        XCTAssertEqual(histPick?.stationID.uppercased(), "KBDR")
    }

    func testNoExtraLookupOnceStationPresent() async throws {
        let dir = tempDir("seed-present")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        let pick = MetarStationPick(stationID: "KBDR", name: "Bridgeport",
                                    coordinate: near, elevationM: 2, distanceKm: 1,
                                    elevationDeltaM: -36, pickedAt: clock.now)
        await v.seedBenchmark(station: pick, key: "bridgeport", cityElevationM: 38)
        await v.seedVerificationStationMeta(key: "bridgeport", stationID: "KBDR", fetched: clock.now)
        for _ in 0..<5 {
            await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        }
        XCTAssertEqual(gets.value, 0)
    }

    func testSeedBackoffRespected() async throws {
        let dir = tempDir("seed-backoff")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        await v.noteUSStationSeedFailure(key: "bridgeport",
                                         until: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache))
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 0)
        // Failure path itself records 24 h (covered by testFreshFetchFailureRecordsBackoff).
    }

    func testSeedDoesNotTouchLastObsCheckOrObservations() async throws {
        let dir = tempDir("seed-noobs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let obs = AFLockBox(0)
        let client = recordingClient(stationGets: gets, obsGets: obs)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        let prior = clock.now.addingTimeInterval(-90)
        await v.seedVerificationStationMeta(key: "bridgeport", stationID: "KBDR", fetched: clock.now.addingTimeInterval(-3600),
                                            lastObsCheck: prior)
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        let obsCheck = await v.lastObsCheck(for: "bridgeport")
        XCTAssertEqual(obsCheck, prior)
        XCTAssertEqual(obs.value, 0, "seed path must not GET observations")
        XCTAssertEqual(gets.value, 1)
    }

    func testNonUSNoSeed() async throws {
        let dir = tempDir("seed-nonus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now })
        await v.verifyIfDue(key: "paris", stationsURL: nil, near: near, cityElevationM: 35)
        XCTAssertEqual(gets.value, 0)
        let parisStation = await v.benchmarkStation(for: "paris")
        XCTAssertNil(parisStation)
    }

    func testPendingVsFailingLabel() async throws {
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: false, switchOn: true,
                                                 nDays: 0, units: { $0 }, stationPending: true),
                       BiasCorrection.offStationPending)
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: false, switchOn: true,
                                                 nDays: 0, units: { $0 }, stationPending: false),
                       BiasCorrection.offStation)
        // US nil station without back-off → pending via buildStatuses.
        let dir = tempDir("label-us")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now },
                                 launchArguments: ["Skyline", "-SkylineAccuracyMeasurement"])
        _ = await v.corrections("nyc", timeZoneIdentifier: "America/New_York", cityElevationM: 32, isUS: true)
        let usLines = await v.correctionStatuses("nyc")
        XCTAssertFalse(usLines.isEmpty)
        XCTAssertTrue(usLines.contains { $0.line == BiasCorrection.offStationPending })

        // Backed off → offStation (not pending).
        await v.noteUSStationSeedFailure(key: "nyc",
                                         until: clock.now.addingTimeInterval(ForecastVerifier.usStationSeedNegativeCache))
        _ = await v.corrections("nyc", timeZoneIdentifier: "America/New_York", cityElevationM: 32, isUS: true)
        let backed = await v.correctionStatuses("nyc")
        XCTAssertTrue(backed.contains { $0.line == BiasCorrection.offStation })
        XCTAssertFalse(backed.contains { $0.line == BiasCorrection.offStationPending })

        // Non-US → never pending.
        _ = await v.corrections("paris", timeZoneIdentifier: "Europe/Paris", cityElevationM: 35, isUS: false)
        let nonUS = await v.correctionStatuses("paris")
        XCTAssertFalse(nonUS.contains { $0.line == BiasCorrection.offStationPending })
    }

    func testStatusRebuiltAfterSeed() async throws {
        let dir = tempDir("label-rebuild")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let gets = AFLockBox(0)
        let client = recordingClient(stationGets: gets)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now },
                                 launchArguments: ["Skyline", "-SkylineAccuracyMeasurement"])
        _ = await v.corrections("bridgeport", timeZoneIdentifier: "America/New_York", cityElevationM: 38, isUS: true)
        let before = await v.correctionStatuses("bridgeport")
        XCTAssertTrue(before.contains { $0.line == BiasCorrection.offStationPending })
        await v.verifyIfDue(key: "bridgeport", stationsURL: stationsURL, near: near, cityElevationM: 38)
        XCTAssertEqual(gets.value, 1)
        let after = await v.correctionStatuses("bridgeport")
        XCTAssertFalse(after.isEmpty, "rows must remain visible after rebuild")
        XCTAssertFalse(after.contains { $0.line == BiasCorrection.offStationPending })
        XCTAssertFalse(after.contains { $0.line == BiasCorrection.offStation })
    }

    // MARK: 7. Wind decimals

    func testWindErrorOneDecimal() {
        let units = DisplayUnits.imperial
        // Diagnosis MAE figures are already in mph; format path is units.speed then ±%.1f.
        XCTAssertEqual(String(format: "±%.1f", units.speed(2.71 * 1.609344)), "±2.7")
        XCTAssertEqual(String(format: "±%.1f", units.speed(3.35 * 1.609344)), "±3.4")
    }

    func testWindKmh() {
        let units = DisplayUnits.metric
        XCTAssertEqual(String(format: "±%.1f", units.speed(2.71)), "±2.7")
        XCTAssertEqual(String(format: "±%.1f", units.speed(3.35)), "±3.4")
        XCTAssertEqual(units.speedUnit, "km/h")
    }

    // MARK: 8–10. Forecast Confidence

    func testConfidenceUsesLowSpread() {
        var day = DailyForecast(date: Date(timeIntervalSince1970: 1_700_000_000), weatherCode: 0,
                                high: 15, low: 5)
        // Highs within 0.6 °C; lows 4.4 °C apart → Low.
        day.sources = [
            SourceReading(name: "A", high: 15.0, low: 5.0, weight: 1),
            SourceReading(name: "B", high: 15.3, low: 7.2, weight: 1),
            SourceReading(name: "C", high: 15.6, low: 9.4, weight: 1),
        ]
        let spread = ForecastConfidence.spread(day: day, modelSeries: [], timeZone: nycTZ,
                                               now: day.date.addingTimeInterval(12 * 3600), isToday: false)
        XCTAssertEqual(spread ?? -1, 4.4, accuracy: 1e-9)
        XCTAssertEqual(ForecastConfidence.levelName(spread), "Low")
        let insight = ForecastInsight.confidence(day: day, hourly: [], timeZone: nycTZ,
                                                 now: day.date.addingTimeInterval(12 * 3600),
                                                 hourLabel: { _ in "" }, delta: { Int($0.rounded()) })
        XCTAssertEqual(insight.level, .low)
    }

    func testConfidenceIgnoresPastPartOfToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nycTZ
        let dayDate = cal.startOfDay(for: Date(timeIntervalSince1970: 1_720_000_000))
        var day = DailyForecast(date: dayDate, weatherCode: 0, high: 20, low: 10)
        day.sources = [
            SourceReading(name: "A", high: 30, low: 0, weight: 1),
            SourceReading(name: "B", high: 31, low: 1, weight: 1),
        ]
        // Build two series: morning disagree wildly; afternoon agree tightly.
        let times = (0..<24).compactMap { cal.date(byAdding: .hour, value: $0, to: dayDate) }
        let cool = times.map { _ in 10.0 }
        let warm = times.map { _ in 11.0 }
        // Past hours (0..<10): inject a 20 °C diverge that must be ignored.
        var aTemps = cool, bTemps = warm
        for i in 0..<10 { aTemps[i] = 0; bTemps[i] = 20 }
        let series = [
            ModelSeries(name: "GFS", times: times, temperatures: aTemps),
            ModelSeries(name: "ECMWF", times: times, temperatures: bTemps),
            ModelSeries(name: "Skyline blend", isBlend: true, times: times, temperatures: cool),
        ]
        let now = cal.date(byAdding: .hour, value: 12, to: dayDate)!
        let spread = ForecastConfidence.spread(day: day, modelSeries: series, timeZone: nycTZ,
                                               now: now, isToday: true)
        XCTAssertNotNil(spread)
        XCTAssertLessThan(spread!, 2.0, "past morning divergence must not count")

        // <3 h remaining → nil and "—".
        let late = cal.date(byAdding: .hour, value: 22, to: dayDate)!
        let lateSpread = ForecastConfidence.spread(day: day, modelSeries: series, timeZone: nycTZ,
                                                   now: late, isToday: true)
        XCTAssertNil(lateSpread)
        XCTAssertEqual(ForecastConfidence.levelName(lateSpread), ForecastConfidence.emDash)
        let hrs = ForecastConfidence.remainingTodayHours(dayDate: dayDate, timeZone: nycTZ, now: late)
        XCTAssertNotNil(hrs)
        XCTAssertLessThan(hrs!, Double(ForecastConfidence.confidenceMinRemainingHours))
    }

    func testDay0WindowCityTZ() {
        XCTAssertNotEqual(TimeZone.current.identifier, honoluluTZ.identifier,
                          "process tz must differ from city tz fixture")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = honoluluTZ
        let dayDate = cal.startOfDay(for: Date(timeIntervalSince1970: 1_720_000_000))
        let now = cal.date(byAdding: .hour, value: 8, to: dayDate)!
        let w = ForecastConfidence.day0Window(dayDate: dayDate, timeZone: honoluluTZ, now: now)
        XCTAssertNotNil(w)
        XCTAssertEqual(w!.start, now)
        // End is next local midnight via calendar day add.
        let endExpected = cal.date(byAdding: .day, value: 1, to: dayDate)!
        XCTAssertEqual(w!.end, endExpected)

        // L1: spring-forward 23 h, fall-back 25 h (NYC 2026, #22 fixtures).
        var nycCal = Calendar(identifier: .gregorian)
        nycCal.timeZone = nycTZ
        let spring = nycCal.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let springStart = nycCal.startOfDay(for: spring)
        let springWin = ForecastConfidence.day0Window(dayDate: springStart, timeZone: nycTZ, now: springStart)!
        XCTAssertEqual(springWin.end.timeIntervalSince(springWin.start), 23 * 3600, accuracy: 1)

        let fall = nycCal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let fallStart = nycCal.startOfDay(for: fall)
        let fallWin = ForecastConfidence.day0Window(dayDate: fallStart, timeZone: nycTZ, now: fallStart)!
        XCTAssertEqual(fallWin.end.timeIntervalSince(fallWin.start), 25 * 3600, accuracy: 1)
    }

    func testEmptyModelSeriesFallback() {
        var day = DailyForecast(date: Date(timeIntervalSince1970: 1_700_000_000), weatherCode: 0,
                                high: 15, low: 5)
        day.sources = [
            SourceReading(name: "A", high: 15, low: 5, weight: 1),
            SourceReading(name: "B", high: 17, low: 6, weight: 1),
        ]
        let viaEmpty = ForecastConfidence.spread(day: day, modelSeries: [], timeZone: nycTZ,
                                                 now: day.date.addingTimeInterval(10 * 3600), isToday: true)
        let viaSources = ForecastConfidence.sourcesSpread(day)
        XCTAssertEqual(viaEmpty, viaSources)
        XCTAssertEqual(viaEmpty ?? -1, 2.0, accuracy: 1e-9)
    }

    func testSharedConfidenceThresholds() {
        let eps = 1e-9
        XCTAssertEqual(ForecastConfidence.levelName(2.0), "High")
        XCTAssertEqual(ForecastConfidence.levelName(2.0 + eps), "Medium")
        XCTAssertEqual(ForecastConfidence.levelName(4.0), "Medium")
        XCTAssertEqual(ForecastConfidence.levelName(4.0 + eps), "Low")
        XCTAssertEqual(ForecastConfidence.level(2.0), .high)
        XCTAssertEqual(ForecastConfidence.level(2.0 + eps), .medium)
        XCTAssertEqual(ForecastConfidence.level(4.0), .medium)
        XCTAssertEqual(ForecastConfidence.level(4.0 + eps), .low)

        // Both surfaces at the same boundaries (Insight via shared level()).
        for (spread, want) in [(2.0, ForecastInsight.Level.high), (2.0 + eps, .medium),
                               (4.0, .medium), (4.0 + eps, .low)] {
            XCTAssertEqual(ForecastConfidence.level(spread), want)
            var day = DailyForecast(date: Date(timeIntervalSince1970: 1_700_100_000), weatherCode: 0,
                                    high: 20, low: 10, highSpread: spread)
            day.sources = [
                SourceReading(name: "A", high: 10, low: 0, weight: 1),
                SourceReading(name: "B", high: 10 + spread, low: 0, weight: 1),
            ]
            let c = ForecastInsight.confidence(day: day, hourly: [], timeZone: .gmt,
                                               now: day.date.addingTimeInterval(86400),
                                               hourLabel: { _ in "" }, delta: { Int($0.rounded()) })
            XCTAssertEqual(c.level, want, "spread \(spread)")
        }
    }

    func testThresholdsFahrenheitBoundary() {
        let spreadC = ForecastConfidence.ConfidenceThresholds.highMaxSpreadC // 2.0
        let units = DisplayUnits.imperial
        let shown = units.temperatureDelta(spreadC)
        XCTAssertEqual(shown, 3.6, accuracy: 1e-9)
        XCTAssertEqual(ForecastConfidence.levelName(spreadC), "High")
        var day = DailyForecast(date: Date(timeIntervalSince1970: 1_700_200_000), weatherCode: 0,
                                high: 20, low: 10)
        day.sources = [
            SourceReading(name: "A", high: 10, low: 0, weight: 1),
            SourceReading(name: "B", high: 10 + spreadC, low: 0, weight: 1),
        ]
        let c = ForecastInsight.confidence(day: day, hourly: [], timeZone: .gmt,
                                           now: day.date.addingTimeInterval(86400),
                                           hourLabel: { _ in "" },
                                           delta: { Int(units.temperatureDelta($0).rounded()) })
        XCTAssertEqual(c.level, .high)
        XCTAssertEqual(ForecastConfidence.level(spreadC), .high)
    }

    func testBlendUnchanged() throws {
        let om = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let nws = try NWSPeriod.decodeList(Fixture.data("nws_forecast"))
        let tz = TimeZone(identifier: "America/New_York")!
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: tz)
        let before = daily
        for (i, day) in daily.enumerated() {
            _ = ForecastConfidence.spread(day: day, modelSeries: [], timeZone: tz,
                                          now: day.date.addingTimeInterval(12 * 3600),
                                          isToday: i == 0)
            _ = ForecastInsight.confidence(day: day, hourly: [], timeZone: tz,
                                           now: day.date.addingTimeInterval(12 * 3600),
                                           hourLabel: { _ in "" }, delta: { Int($0.rounded()) })
        }
        XCTAssertEqual(daily, before, "DailyForecast arrays must stay byte-equal")
        // Re-blend: confidence helpers must not change blender output either.
        let again = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: tz)
        XCTAssertEqual(again, before)
    }
}
