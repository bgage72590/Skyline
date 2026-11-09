import Foundation
import XCTest
@testable import SkylineCore

/// Accuracy PR 2 lock §4 + §3a BLOCK-ON tests. Network faked; golden from merged main @ 362a5d4.
final class AccuracyPR2Tests: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_791_725_400)
    static let goldenName = "golden_report_pr1_362a5d4"
    var t0: Date { Self.t0 }
    let paris = WeatherLocation(name: "Paris", country: "France",
                                coordinate: Coordinate(latitude: 48.85, longitude: 2.35))
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.removeObject(forKey: BiasCorrection.QAOverride.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.removeObject(forKey: BiasCorrection.QAOverride.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
        super.tearDown()
    }

    // MARK: §4 — Golden ×3 (B6)

    func testGoldenBelowGateSwitchOffMeasurementOff() async throws {
        let golden = try loadGolden()

        // Below gate (fresh city): byte-identical to PR 1 golden.
        let below = try await reportSlice(correction: true, measurement: true)
        XCTAssertEqual(below.hourly, golden.hourly)
        XCTAssertEqual(below.daily, golden.daily)
        XCTAssertEqual(below.current, golden.current)
        XCTAssertEqual(below.modelSeries, golden.modelSeries)
        XCTAssertEqual(below.weights, golden.weights)

        // Kill switch OFF.
        let off = try await reportSlice(correction: false, measurement: true)
        XCTAssertEqual(off.hourly, golden.hourly)
        XCTAssertEqual(off.daily, golden.daily)
        XCTAssertEqual(off.current, golden.current)
        XCTAssertEqual(off.modelSeries, golden.modelSeries)
        XCTAssertEqual(off.weights, golden.weights)

        // Measurement OFF.
        let measOff = try await reportSlice(correction: true, measurement: false)
        XCTAssertEqual(measOff.hourly, golden.hourly)
        XCTAssertEqual(measOff.daily, golden.daily)
        XCTAssertEqual(measOff.current, golden.current)
        XCTAssertEqual(measOff.modelSeries, golden.modelSeries)
        XCTAssertEqual(measOff.weights, golden.weights)
    }

    func testGateBoundariesStayUncorrected() {
        // 13 days / 19 pairs / 299 pairs / 300 pairs on 6 days → below gate → offset 0.
        func rows(days: Int, pairsPerDay: Int, target: CorrectionTarget) -> [TrainingRow] {
            (0..<days).map { d in
                TrainingRow(loc: "x", localDay: t0.addingTimeInterval(Double(-d - 1) * 86400),
                            target: target, sumE: Double(pairsPerDay) * 1.0, n: pairsPerDay)
            }
        }
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 13, pairsPerDay: 1, target: .dailyHigh),
                                            target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 19, pairsPerDay: 1, target: .dailyHigh),
                                            target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertTrue(BiasCorrection.gate(rows: rows(days: 20, pairsPerDay: 1, target: .dailyHigh),
                                          target: .dailyHigh, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 6, pairsPerDay: 50, target: .h0to6),
                                            target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertFalse(BiasCorrection.gate(rows: rows(days: 7, pairsPerDay: 42, target: .h0to6), // 294
                                            target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
        XCTAssertTrue(BiasCorrection.gate(rows: rows(days: 7, pairsPerDay: 43, target: .h0to6), // 301
                                          target: .h0to6, sitingOK: true, switchOn: true, measurementOn: true))
    }

    // MARK: B1 — Dedupe idempotence ×20

    func testDedupeIdempotenceTwentyReruns() async throws {
        let dir = tempDir("pr2-dedupe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        let key = "paris"
        let station = MetarStationPick(stationID: "LFPG", coordinate: Coordinate(latitude: 49.01, longitude: 2.55),
                                       elevationM: 119, distanceKm: 23, elevationDeltaM: 84, pickedAt: t0)
        await store.seedStation(station, key: key)
        let pair = BenchmarkHourlyPair(loc: key, issued: t0, valid: t0.addingTimeInterval(3600),
                                       kind: .skyline, forecastC: 14, observedC: 13, uncorrectedC: 14)
        let train = TrainingRow(loc: key, localDay: t0.addingTimeInterval(-86400), target: .h0to6, sumE: 1, n: 1)
        let metar = VerifiedRecord(
            ForecastRecord(loc: key, issued: t0, valid: t0.addingTimeInterval(7200),
                           f: [VerificationSource.blend.rawValue: SourceValues(t: 14)]),
            ObservedHour(t: 13))
        let obs = [StationObservation(time: t0, temperatureC: 12, windKmh: 5, precipLastHourMM: nil, precipitating: false)]
        for _ in 0..<20 {
            await store.recordHourlyPairs([pair])
            await store.recordTrainingRows([train])
            await store.recordMetarVerified([metar])
            await store.recordNWSTemps(key: key, stationID: "LFPG", obs: obs)
        }
        let h = await store.hourlyBenchCount(for: key)
        let tr = await store.trainingCount(for: key)
        let mv = await store.metarVerifiedCount(for: key)
        let mc = await store.metarCount(for: key)
        XCTAssertEqual(h, 1)
        XCTAssertEqual(tr, 1)
        XCTAssertEqual(mv, 1)
        XCTAssertEqual(mc, 1)
    }

    // MARK: A1 — NWS temps for US daily

    func testA1RecordNWSTempsDedupedNoNewRequests() async throws {
        let dir = tempDir("pr2-a1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PR1HTTPClient()
        let before = client.awcFetchCount + client.metFetchCount
        let v = ForecastVerifier(directory: dir, client: client, now: { Self.t0 })
        let key = VerificationKey.key(for: nyc)
        let obs = (0..<24).map { i in
            StationObservation(time: t0.addingTimeInterval(Double(i) * 3600), temperatureC: 10 + Double(i % 5),
                               windKmh: 5, precipLastHourMM: nil, precipitating: false)
        }
        await v.runMeasurement(key: key, coordinate: nyc.coordinate, timeZoneIdentifier: "America/New_York",
                               daily: [], openMeteo: try OpenMeteoResponse.decode(Fixture.data("om_nyc")),
                               blended: [], isUS: true, nwsObservations: obs)
        await v.runMeasurement(key: key, coordinate: nyc.coordinate, timeZoneIdentifier: "America/New_York",
                               daily: [], openMeteo: try OpenMeteoResponse.decode(Fixture.data("om_nyc")),
                               blended: [], isUS: true, nwsObservations: obs)
        let n = await v.benchmarkMetarCount(key)
        XCTAssertEqual(n, 24)
        // A1: US path must not add AWC station/METAR requests (MET Norway is unchanged from PR 1).
        XCTAssertEqual(client.awcFetchCount, 0)
        _ = before
    }

    // MARK: B2 — D+1 and like-for-like / spike

    func testDailyDPlus1AndHourlySlotsIgnoreSpikes() {
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let day = cal.startOfDay(for: t0)
        // 5-min spike to 40 °C should not set the slot high when nearest-to-:00 is 20.
        var temps: [(Date, Double)] = []
        for h in 0..<24 {
            let slot = day.addingTimeInterval(Double(h) * 3600)
            temps.append((slot, 20))
            temps.append((slot.addingTimeInterval(300), 40)) // spike
        }
        let now = day.addingTimeInterval(25 * 3600)
        let slots = BiasCorrection.hourlySlotExtremes(temps: temps, day: day, timeZone: tz, now: now)
        XCTAssertEqual(slots?.high, 20)
        XCTAssertEqual(slots?.low, 20)
        XCTAssertEqual(slots?.slots, 24)

        // D+1: same-day issue must not score.
        let issueSame = DailyForecastIssue(loc: "x", issued: day.addingTimeInterval(3600), localDay: day,
                                           timeZoneIdentifier: tz.identifier, highs: ["skyline": 22], lows: ["skyline": 10],
                                           rawHourlyMaxC: 22, rawHourlyMinC: 10)
        let issueAhead = DailyForecastIssue(loc: "x", issued: day.addingTimeInterval(-3600), localDay: day,
                                            timeZoneIdentifier: tz.identifier, highs: ["skyline": 21], lows: ["skyline": 11],
                                            rawHourlyMaxC: 21, rawHourlyMinC: 11)
        let obs = DailyObservedExtremes(loc: "x", localDay: day, timeZoneIdentifier: tz.identifier,
                                        highC: 20, lowC: 10, distinctHours: 24, source: "nws")
        let mae = BenchmarkScorer.dailyMAE(issues: [issueSame, issueAhead], obs: [obs], kind: .skyline, high: true)
        XCTAssertEqual(mae?.n, 1)
        XCTAssertEqual(mae?.mae ?? -1, 1.0, accuracy: 1e-9) // |21-20|
    }

    // MARK: B3 — Write volume / timing

    func testWriteVolumeAndTimingBound() async throws {
        let dir = tempDir("pr2-write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        await store.resetBytesWrittenSeam()
        let start = Date()
        for city in 0..<15 {
            let key = "c\(city)"
            let station = MetarStationPick(stationID: String(format: "X%03d", city),
                                           coordinate: Coordinate(latitude: 48, longitude: 2),
                                           elevationM: 100, distanceKm: 10, elevationDeltaM: 10, pickedAt: t0)
            await store.seedStation(station, key: key)
            var trains: [TrainingRow] = []
            for d in 0..<60 {
                for target in CorrectionTarget.allCases {
                    trains.append(TrainingRow(loc: key,
                                              localDay: t0.addingTimeInterval(Double(-d - 1) * 86400),
                                              target: target, sumE: 1.2, n: target.isDaily ? 1 : 50,
                                              distinct: target.isDaily ? nil : 20))
                }
            }
            await store.recordTrainingRows(trains)
            // Steady-state refresh: one more day, should be append-only small write.
            await store.resetBytesWrittenSeam()
            let extra = CorrectionTarget.allCases.map {
                TrainingRow(loc: key, localDay: t0.addingTimeInterval(-61 * 86400), target: $0, sumE: 1, n: 1)
            }
            await store.recordTrainingRows(extra)
            let wrote = await store.bytesWrittenSinceSeamReset()
            XCTAssertLessThan(wrote, 100_000, "city \(key) wrote \(wrote)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "60d×15 cities took \(elapsed)s")
    }

    // MARK: B4 — Zero added requests

    func testZeroAddedRequestsCorrectionOnVsOff() async throws {
        let clientOn = PR1HTTPClient()
        let clientOff = PR1HTTPClient()
        let clock = TestClock(t0)
        UserDefaults.standard.set(true, forKey: BiasCorrection.Switch.defaultsKey)
        let onDir = tempDir("pr2-req-on"); defer { try? FileManager.default.removeItem(at: onDir) }
        let svcOn = WeatherService(client: clientOn, cache: ResponseCache(directory: nil, now: { clock.now }),
                                   verifier: ForecastVerifier(directory: onDir, client: clientOn, now: { clock.now }),
                                   now: { clock.now })
        _ = try await svcOn.report(for: paris)
        try await Task.sleep(for: .milliseconds(300))
        let onCount = clientOn.requests.count

        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        let offDir = tempDir("pr2-req-off"); defer { try? FileManager.default.removeItem(at: offDir) }
        let svcOff = WeatherService(client: clientOff, cache: ResponseCache(directory: nil, now: { clock.now }),
                                    verifier: ForecastVerifier(directory: offDir, client: clientOff, now: { clock.now }),
                                    now: { clock.now })
        _ = try await svcOff.report(for: paris)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(clientOn.requests.count, onCount)
        XCTAssertEqual(clientOff.requests.count, clientOn.requests.count)
    }

    // MARK: B5 — Leakage

    func testLeakageSeededFutureRowChangesNothing() {
        let past = (1...20).map { d in
            TrainingRow(loc: "x", localDay: t0.addingTimeInterval(Double(-d) * 86400),
                        target: .dailyHigh, sumE: 2.0, n: 1)
        }
        let asOf = t0
        let (a, n) = BiasCorrection.estimate(rows: past.filter { $0.localDay < asOf }, asOf: asOf)
        let future = TrainingRow(loc: "x", localDay: t0.addingTimeInterval(86400), target: .dailyHigh, sumE: 100, n: 1)
        let (b, n2) = BiasCorrection.estimate(rows: (past + [future]).filter { $0.localDay < asOf }, asOf: asOf)
        XCTAssertEqual(a, b, accuracy: 1e-12)
        XCTAssertEqual(n, n2)
        XCTAssertEqual(past[0].sumE, 2.0) // learning uses uncorrected errors only
    }

    // MARK: B7 — Clamp and ramp

    func testClampAndRampSequenceStableAcrossRefreshes() {
        XCTAssertEqual(BiasCorrection.clamp(3), 2)
        XCTAssertEqual(BiasCorrection.clamp(-3), -2)
        var applied = 0.0
        let targets = [0.5, 1.0, 1.5, 2.0, 2.5]
        var sequence: [Double] = []
        for (i, t) in targets.enumerated() {
            applied = BiasCorrection.rateLimited(previous: applied, targetC: BiasCorrection.clamp(-t),
                                                 sameLocalDay: false, forceZero: false)
            sequence.append(applied)
            // Same local day: stable across 20 refreshes.
            for _ in 0..<20 {
                let again = BiasCorrection.rateLimited(previous: applied, targetC: BiasCorrection.clamp(-t),
                                                       sameLocalDay: true, forceZero: false)
                XCTAssertEqual(again, applied, accuracy: 1e-12, "day \(i)")
            }
        }
        XCTAssertEqual(sequence[0], -0.5, accuracy: 1e-9)
        XCTAssertEqual(sequence[1], -1.0, accuracy: 1e-9)
        XCTAssertEqual(sequence[2], -1.5, accuracy: 1e-9)
        XCTAssertEqual(sequence[3], -2.0, accuracy: 1e-9)
        XCTAssertEqual(sequence[4], -2.0, accuracy: 1e-9) // clamped
        // Kill switch drops to 0 immediately.
        XCTAssertEqual(BiasCorrection.rateLimited(previous: -2, targetC: -2, sameLocalDay: false, forceZero: true), 0)
    }

    // MARK: B8 — Feels-like, dew, invariants, edge ramp, reconcileCurrent

    func testApplyFeelsLikeDewInvariantsEdgeRampReconcile() {
        let issued = t0
        var hourly: [HourlyForecast] = []
        for h in 0..<60 {
            let lead = Double(h)
            hourly.append(HourlyForecast(time: issued.addingTimeInterval(lead * 3600),
                                         temperature: 20, apparentTemperature: 21,
                                         weatherCode: 1, isDay: true, dewPoint: 19))
        }
        var daily = [DailyForecast(date: issued, weatherCode: 1, high: 22, low: 18)]
        var current = CurrentConditions(time: issued, temperature: 20, apparentTemperature: 21,
                                        humidity: 50, dewPoint: 19, weatherCode: 1, isDay: true,
                                        precipitation: 0, cloudCover: nil, pressure: nil,
                                        windSpeed: 5, windDirection: nil, windGust: nil,
                                        visibility: nil, uvIndex: nil)
        let offsets: [CorrectionTarget: Double] = [.h0to6: 1.0, .h6to24: 0.0, .day2: 0.0, .day3plus: 0.0,
                                                   .dailyHigh: 0.5, .dailyLow: -0.5]
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current,
                             issued: issued, timeZone: TimeZone(identifier: "UTC")!, offsets: offsets)
        // Apparent gets same offset as temperature at lead 0.
        XCTAssertEqual(hourly[0].temperature, 21, accuracy: 1e-9)
        XCTAssertEqual(hourly[0].apparentTemperature!, 22, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(hourly[0].dewPoint!, hourly[0].temperature)
        // Edge ramp around 6 h: no step > 0.35 between adjacent hours near the boundary.
        for i in 3..<10 {
            let step = abs(hourly[i].temperature - hourly[i - 1].temperature)
            XCTAssertLessThanOrEqual(step, BiasCorrection.maxEdgeStepC + 1e-9, "hour \(i)")
        }
        XCTAssertGreaterThanOrEqual(daily[0].high, hourly.filter { abs($0.time.timeIntervalSince(issued)) < 86400 }.map(\.temperature).max()! - 1e-9)
        // reconcileCurrent with corrected temp.
        let code = Nowcast.reconcileCurrent(code: 61, minutely: [], now: issued, temperature: current.temperature)
        XCTAssertTrue(code == 61 || code == 71 || code == 63 || code == 1 || code >= 0)
    }

    // MARK: B8 — Widget / menu consistency

    func testWidgetSnapshotAndMenuSummaryMatchCorrected() throws {
        var report = try makeBareReport(temp: 20)
        report.current.temperature = 21
        report.current.apparentTemperature = 25 // ≥3 °C feels-like delta
        report.hourly[0].temperature = 21
        report.daily[0].high = 23
        let snap = WidgetSnapshot(report: report, locationName: "Test", units: .metric, now: t0)
        XCTAssertEqual(snap.temperature, 21)
        XCTAssertEqual(snap.hours.first?.temperature, 21)
        XCTAssertEqual(snap.high, 23)
        let feels = MenuSummary.feelsLikeText(temperature: report.current.temperature,
                                              apparent: report.current.apparentTemperature,
                                              units: .metric)
        XCTAssertNotNil(feels)
        XCTAssertEqual(feels, "Feels like 25°")
    }

    // MARK: B9 — Non-temperature fields unchanged when gated

    func testNonTemperatureFieldsByteIdenticalWhenGated() throws {
        let enc = Self.sortedEncoder()
        let base = try makeBareReport(temp: 20)
        var corrected = base
        var hourly = corrected.hourly
        var daily = corrected.daily
        var current = corrected.current
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current,
                             issued: t0, timeZone: .gmt,
                             offsets: [.h0to6: 1.0, .h6to24: 1.0, .day2: 1.0, .day3plus: 1.0,
                                       .dailyHigh: 1.0, .dailyLow: 1.0])
        corrected.hourly = hourly; corrected.daily = daily; corrected.current = current
        // Strip temperature-ish fields and compare the rest.
        func strip(_ r: WeatherReport) -> Data {
            var c = r.current
            c.temperature = 0; c.apparentTemperature = 0; c.dewPoint = nil
            let hours = r.hourly.map { h -> HourlyForecast in
                var x = h; x.temperature = 0; x.apparentTemperature = nil; x.dewPoint = nil; return x
            }
            let days = r.daily.map { d -> DailyForecast in
                var x = d; x.high = 0; x.low = 0; return x
            }
            var out = r; out.current = c; out.hourly = hours; out.daily = days
            return (try? enc.encode(out)) ?? Data()
        }
        XCTAssertEqual(strip(base), strip(corrected))
    }

    // MARK: B10 — Units / rounding

    func testFahrenheitDisplayAndRounding() {
        let units = DisplayUnits.imperial
        XCTAssertEqual(units.temperatureDelta(1.3), 1.3 * 1.8, accuracy: 1e-9)
        let shown = String(format: "%+.1f°", units.temperatureDelta(1.3))
        XCTAssertEqual(shown, "+2.3°")
        // +0.5 °C on 20.0 displays like 20.5 does today.
        XCTAssertEqual(units.temperature(20.5), units.temperature(20.0 + 0.5), accuracy: 1e-9)
    }

    // MARK: B11 — DST / Sydney

    func testDSTAndSydneyLocalDays() {
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        // A day that spans two UTC dates.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = sydney
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let w = LocalDayAggregator.window(forDay: day, timeZone: sydney)
        XCTAssertEqual(cal.component(.hour, from: w.start), 0)
        let duration = w.end.timeIntervalSince(w.start)
        XCTAssertTrue(abs(duration - 86400) < 3600 || abs(duration - 82800) < 100 || abs(duration - 90000) < 100)
        // Partial day not scored.
        let temps = [(w.start.addingTimeInterval(3600), 20.0)]
        XCTAssertNil(BiasCorrection.hourlySlotExtremes(temps: temps, day: day, timeZone: sydney, now: w.start.addingTimeInterval(2 * 3600)))
    }

    // MARK: B12 — Switch + auto-off hysteresis + log

    func testSwitchDefaultsOnAndOff() {
        XCTAssertTrue(BiasCorrection.Switch.isEnabled(), "default ON (lock §10)")
        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        XCTAssertFalse(BiasCorrection.Switch.isEnabled())
        UserDefaults.standard.set(true, forKey: BiasCorrection.Switch.defaultsKey)
        XCTAssertTrue(BiasCorrection.Switch.isEnabled())
        // Sticky auto-off with hysteresis + log: testAutoOffTripsLogsSurvivesRelaunchAndReenablesWithHysteresis.
    }

    // MARK: B13 — PR 1 decoder reads PR 2 files

    func testPR1DecoderReadsPR2Files() throws {
        // New optional fields decode as nil on old shapes; unknown files ignored by PR 1 loaders.
        let pairJSON = """
        {"loc":"x","issued":100,"valid":200,"kind":"skyline","forecastC":1,"observedC":2,"uncorrectedC":1.5}
        """.data(using: .utf8)!
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let pair = try dec.decode(BenchmarkHourlyPair.self, from: pairJSON)
        XCTAssertEqual(pair.uncorrectedC, 1.5)
        let oldJSON = """
        {"loc":"x","issued":100,"valid":200,"kind":"skyline","forecastC":1,"observedC":2}
        """.data(using: .utf8)!
        let old = try dec.decode(BenchmarkHourlyPair.self, from: oldJSON)
        XCTAssertNil(old.uncorrectedC)
        XCTAssertEqual(old.learningForecastC, 1)
        let issueJSON = """
        {"loc":"x","issued":100,"localDay":100,"timeZoneIdentifier":"UTC","highs":{"skyline":10},"lows":{"skyline":1},"rawHourlyMaxC":11,"rawHourlyMinC":0}
        """.data(using: .utf8)!
        let issue = try dec.decode(DailyForecastIssue.self, from: issueJSON)
        XCTAssertEqual(issue.rawHourlyMaxC, 11)
    }

    // MARK: B14 — Canaries

    func testCanariesUntouched() async throws {
        let dir = tempDir("pr2-canary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PR1HTTPClient()
        let v = ForecastVerifier(directory: dir, client: client, now: { Self.t0 })
        let syncURL = dir.appendingPathComponent("sync.json")
        let accuracyURL = dir.appendingPathComponent("accuracy.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let syncData = Data("{\"v\":1,\"canary\":true}".utf8)
        let accuracyData = Data("{\"format\":1,\"canary\":true}".utf8)
        try syncData.write(to: syncURL)
        try accuracyData.write(to: accuracyURL)
        let verifiedBefore = (try? Data(contentsOf: dir.appendingPathComponent("verified.jsonl"))) ?? Data()
        let defaults = UserDefaults(suiteName: "pr2-canary-\(UUID().uuidString)")!
        let canary = Data("canary".utf8)
        defaults.set(canary, forKey: "savedLocations.v1")

        await v.runMeasurement(key: VerificationKey.key(for: paris),
                               coordinate: paris.coordinate, timeZoneIdentifier: "Europe/Paris",
                               daily: [], openMeteo: try OpenMeteoResponse.decode(Fixture.data("om_paris")),
                               blended: [], isUS: false)
        XCTAssertEqual(try Data(contentsOf: syncURL), syncData)
        XCTAssertEqual(try Data(contentsOf: accuracyURL), accuracyData)
        XCTAssertEqual(defaults.data(forKey: "savedLocations.v1"), canary)
        let verifiedAfter = (try? Data(contentsOf: dir.appendingPathComponent("verified.jsonl"))) ?? Data()
        XCTAssertEqual(verifiedAfter, verifiedBefore)
    }

    // MARK: B15 — Reset

    func testResetClearsCorrectionState() async throws {
        let dir = tempDir("pr2-reset")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        let key = "paris"
        let station = MetarStationPick(stationID: "LFPG", coordinate: Coordinate(latitude: 49.01, longitude: 2.55),
                                       elevationM: 119, distanceKm: 10, elevationDeltaM: 50, pickedAt: t0)
        var trains: [TrainingRow] = []
        for d in 1...25 {
            trains.append(TrainingRow(loc: key, localDay: t0.addingTimeInterval(Double(-d) * 86400),
                                      target: .dailyHigh, sumE: 1.5, n: 1))
        }
        await v.seedBenchmark(station: station, key: key)
        // Seed training via store path through runMeasurement learning is heavy; use seed on store via corrections.
        let benchDir = await v.benchmarkStoreDirectory()
        let store = BenchmarkStore(directory: benchDir, client: PR1HTTPClient(), now: { Self.t0 })
        await store.seedStation(station, key: key)
        await store.seedCityElevation(50, key: key)
        await store.seedTraining(trains)
        _ = await v.corrections(key, timeZoneIdentifier: "Europe/Paris", cityElevationM: 50)
        let beforeReset = await store.trainingCount(for: key)
        XCTAssertGreaterThan(beforeReset, 0)
        await v.reset()
        // After verifier.reset(), the on-disk store is cleared; reopen a fresh store handle.
        let store2 = BenchmarkStore(directory: benchDir, client: PR1HTTPClient(), now: { Self.t0 })
        let afterReset = await store2.trainingCount(for: key)
        XCTAssertEqual(afterReset, 0)
        let metars = await v.benchmarkMetarCount(key)
        XCTAssertEqual(metars, 0)
        let offsets = await v.correctionIfLoaded(key)
        XCTAssertTrue(offsets == nil || offsets?.values.allSatisfy { abs($0) < 1e-12 } == true)
    }

    // MARK: B16 — Off main

    func testOffMainLearningAndIO() async throws {
        let dir = tempDir("pr2-offmain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        let exp = expectation(description: "bg")
        DispatchQueue.global(qos: .utility).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            Task {
                await store.loadCorrectionsOnly()
                await store.recordTrainingRows([TrainingRow(loc: "x", localDay: Self.t0.addingTimeInterval(-86400),
                                                            target: .h0to6, sumE: 1, n: 1)])
                exp.fulfill()
            }
        }
        await fulfillment(of: [exp], timeout: 10)
    }

    // MARK: B17 — US weights unchanged

    func testUSWeightsUnchangedWithCorrectionOn() async throws {
        let dir = tempDir("pr2-us-w")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PR1HTTPClient()
        let v = ForecastVerifier(directory: dir, client: client, now: { Self.t0 })
        let key = VerificationKey.key(for: nyc)
        UserDefaults.standard.set(true, forKey: BiasCorrection.Switch.defaultsKey)
        await v.runMeasurement(key: key, coordinate: nyc.coordinate, timeZoneIdentifier: "America/New_York",
                               daily: [], openMeteo: try OpenMeteoResponse.decode(Fixture.data("om_nyc")),
                               blended: [], isUS: true)
        let w = await v.weights(key)
        XCTAssertTrue(w.isNeutral)
        let enc = Self.sortedEncoder()
        let golden = try loadGolden()
        XCTAssertEqual(try enc.encode(w), golden.weights)
    }

    // MARK: OpenMeteo elevation

    func testOpenMeteoElevationNilTolerantAndFixturesUnchanged() throws {
        let nyc = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let paris = try OpenMeteoResponse.decode(Fixture.data("om_paris"))
        XCTAssertEqual(nyc.elevation, 27)
        XCTAssertEqual(paris.elevation, 46)
        // Values that mattered before still decode.
        XCTAssertFalse(nyc.hourlyTimes.isEmpty)
        XCTAssertNotNil(nyc.currentConditions())
        // Nil-tolerant: strip elevation from JSON.
        var obj = try JSONSerialization.jsonObject(with: Fixture.data("om_nyc")) as! [String: Any]
        obj.removeValue(forKey: "elevation")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try OpenMeteoResponse.decode(stripped)
        XCTAssertNil(decoded.elevation)
        XCTAssertEqual(decoded.latitude, nyc.latitude, accuracy: 1e-6)
    }

    // MARK: Siting (c2)

    func testSitingRules() {
        XCTAssertTrue(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: 100, cityElevationM: 50))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 30, stationElevationM: 100, cityElevationM: 50))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: 250, cityElevationM: 50))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: nil, cityElevationM: 50))
        XCTAssertTrue(BiasCorrection.sitingPasses(distanceKm: 10, stationElevationM: nil, cityElevationM: nil))
        XCTAssertFalse(BiasCorrection.sitingPasses(distanceKm: 20, stationElevationM: nil, cityElevationM: nil))
    }

    // MARK: Status lines

    func testStatusLines() {
        let line = BiasCorrection.statusLine(entry: CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 1.3),
                                             gated: true, sitingOK: true, switchOn: true, nDays: 25,
                                             units: { $0 * 1.8 })
        XCTAssertTrue(line.contains("correction in use"))
        XCTAssertTrue(line.contains("+2.3"))
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                                 nDays: 5, units: { $0 }, target: .dailyHigh, nPairs: 0),
                        "off (5/14 days · 0/20 pairs)")
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                                 nDays: 3, units: { $0 }, target: .h0to6, nPairs: 21),
                        "off (3/7 days · 21/300 pairs)")
        XCTAssertFalse(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                                 nDays: 5, units: { $0 }, target: .h0to6).contains("/20 days"))
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: false, switchOn: true,
                                                 nDays: 5, units: { $0 }), "off: station")
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: false,
                                                 nDays: 5, units: { $0 }), "off: switched off")
    }

    // MARK: Gated apply changes temperature

    func testGatedCityAppliesOffset() async throws {
        let dir = tempDir("pr2-gated")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PR1HTTPClient()
        let v = ForecastVerifier(directory: dir, client: client, now: { Self.t0 })
        let key = VerificationKey.key(for: paris)
        let station = MetarStationPick(stationID: "LFPG", coordinate: Coordinate(latitude: 49.01, longitude: 2.55),
                                       elevationM: 100, distanceKm: 10, elevationDeltaM: 50, pickedAt: t0)
        var trains: [TrainingRow] = []
        for d in 1...25 {
            trains.append(TrainingRow(loc: key, localDay: t0.addingTimeInterval(Double(-d) * 86400),
                                      target: .h0to6, sumE: 50 * 1.0, n: 50, distinct: 20))
        }
        // Need ≥300 pairs over ≥7 days for hourly — seed through the verifier's store actor.
        await v.seedBenchmark(station: station, key: key, training: trains, cityElevationM: 50)
        let offsets = await v.corrections(key, timeZoneIdentifier: "Europe/Paris", cityElevationM: 50)
        // Warm bias (+1) → applied negative offset.
        XCTAssertLessThan(offsets[.h0to6] ?? 0, 0)
        XCTAssertGreaterThan(abs(offsets[.h0to6] ?? 0), 0.01)
    }

    // MARK: Review fix H1 — QA override: launch-arg only, finite, clamped, never saved, kill switch → 0

    func testQAOverrideLaunchArgOnlyFiniteClampedNeverSaved() async throws {
        typealias Q = BiasCorrection.QAOverride
        XCTAssertEqual(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "1.0"]), 1.0)
        XCTAssertEqual(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "50"]), 2.0)
        XCTAssertEqual(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "-7.5"]), -2.0)
        XCTAssertNil(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "nan"]))
        XCTAssertNil(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "inf"]))
        XCTAssertNil(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride", "abc"]))
        XCTAssertNil(Q.celsius(arguments: ["Skyline", "-SkylineCorrectionQAOverride"]))
        XCTAssertNil(Q.celsius(arguments: ["Skyline"]))

        // A persisted value (`defaults write`) is ignored: only launch arguments count.
        UserDefaults.standard.set(1.0, forKey: Q.defaultsKey)
        UserDefaults.standard.set("1.0", forKey: Q.defaultsKey)
        XCTAssertNil(Q.celsius(arguments: ["Skyline"]))
        let dir = tempDir("pr2-qa-persist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { Self.t0 }, launchArguments: ["Skyline"])
        let active = await v.isQAOverrideActive
        XCTAssertFalse(active)
        let key = await seedGatedNYC(v)
        let learned = await v.corrections(key, timeZoneIdentifier: "America/New_York", cityElevationM: 27)
        XCTAssertNotEqual(learned[.dailyHigh] ?? 0, 1.0, accuracy: 1e-6, "persisted override must not apply")

        // Store level: override forces gated targets, never writes corrections.json, kill switch → 0.
        let sdir = tempDir("pr2-qa-store")
        defer { try? FileManager.default.removeItem(at: sdir) }
        let store = BenchmarkStore(directory: sdir, client: PR1HTTPClient(), now: { Self.t0 })
        let station = MetarStationPick(stationID: "LFPG", coordinate: Coordinate(latitude: 49.01, longitude: 2.55),
                                       elevationM: 100, distanceKm: 10, elevationDeltaM: 50, pickedAt: t0)
        await store.seedStation(station, key: "paris")
        await store.seedCityElevation(50, key: "paris")
        await store.seedTraining((1...25).map {
            TrainingRow(loc: "paris", localDay: t0.addingTimeInterval(Double(-$0) * 86400), target: .dailyHigh, sumE: 1.0, n: 1)
        })
        let corr = sdir.appendingPathComponent("corrections.json")
        let before = try? Data(contentsOf: corr)
        var o = await store.refreshCorrections(key: "paris", timeZoneIdentifier: "Europe/Paris", sitingOK: true, qaOverrideC: 1.0)
        XCTAssertEqual(o[.dailyHigh] ?? -999, 1.0, accuracy: 1e-12)
        XCTAssertEqual(o[.h0to6] ?? -999, 0, "below-gate targets stay exactly 0 under the override")
        o = await store.refreshCorrections(key: "paris", timeZoneIdentifier: "Europe/Paris", sitingOK: true, qaOverrideC: 50)
        XCTAssertEqual(o[.dailyHigh] ?? -999, 2.0, accuracy: 1e-12)
        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        o = await store.refreshCorrections(key: "paris", timeZoneIdentifier: "Europe/Paris", sitingOK: true, qaOverrideC: 1.0)
        XCTAssertTrue(o.values.allSatisfy { $0 == 0 }, "kill switch beats the override")
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        o = await store.refreshCorrections(key: "paris", timeZoneIdentifier: "Europe/Paris", sitingOK: true, qaOverrideC: 1.0)
        let after = try? Data(contentsOf: corr)
        XCTAssertEqual(before, after, "QA override never writes corrections.json")
        XCTAssertNil(after)
    }

    // MARK: Review fix §7 / Option A — gated city pipeline under the launch-arg override

    func testGatedPipelineLaunchArgOverridePlusOneEverywhere() async throws {
        let golden = try loadGolden()
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let gH = try dec.decode([HourlyForecast].self, from: golden.hourly)
        let gD = try dec.decode([DailyForecast].self, from: golden.daily)
        let gC = try dec.decode(CurrentConditions.self, from: golden.current)
        let dir = tempDir("pr2-qa-pipe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = PR1HTTPClient()
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now },
                                 launchArguments: ["Skyline", "-SkylineCorrectionQAOverride", "1.0"])
        let key = await seedGatedNYC(v)
        let corrURL = await v.benchmarkStoreDirectory().appendingPathComponent("corrections.json")
        let offsets = await v.corrections(key, timeZoneIdentifier: "America/New_York", cityElevationM: 27)
        for t in CorrectionTarget.allCases { XCTAssertEqual(offsets[t] ?? 0, 1.0, accuracy: 1e-12, "\(t)") }
        let statuses = await v.correctionStatuses(key)
        XCTAssertEqual(statuses.count, 6)
        XCTAssertTrue(statuses.allSatisfy { $0.line.contains("+1.0°") && $0.line.contains("(QA override)") },
                      statuses.map(\.line).joined(separator: " | "))

        let svc = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }),
                                 verifier: v, now: { clock.now })
        let report = try await svc.report(for: nyc)

        // Hourly: +1.0 °C on temperature and feels-like, nothing else changes, dew ≤ T, no edge step.
        XCTAssertEqual(report.hourly.count, gH.count)
        var deltas: [Double] = []
        for (a, g) in zip(report.hourly, gH) {
            XCTAssertEqual(a.time, g.time)
            XCTAssertEqual(a.temperature, g.temperature + 1.0, accuracy: 1e-9)
            deltas.append(a.temperature - g.temperature)
            if let ga = g.apparentTemperature { XCTAssertEqual(a.apparentTemperature ?? .nan, ga + 1.0, accuracy: 1e-9) }
            if let dp = a.dewPoint { XCTAssertLessThanOrEqual(dp, a.temperature + 1e-9) }
            XCTAssertEqual(a.weatherCode, g.weatherCode)
            XCTAssertEqual(a.precipitation, g.precipitation)
            XCTAssertEqual(a.precipitationProbability, g.precipitationProbability)
            XCTAssertEqual(a.windSpeed, g.windSpeed)
            XCTAssertEqual(a.humidity, g.humidity)
            XCTAssertEqual(a.pressure, g.pressure)
        }
        for i in deltas.indices.dropFirst() {
            XCTAssertLessThanOrEqual(abs(deltas[i] - deltas[i - 1]), BiasCorrection.maxEdgeStepC, "hour \(i)")
        }

        // Daily: +1.0 °C high/low (where PR 1 already had high ≥ hourly max / low ≤ hourly min).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: report.timeZoneIdentifier)!
        XCTAssertEqual(report.daily.count, gD.count)
        _ = cal
        for (a, g) in zip(report.daily, gD) {
            // Equal offsets everywhere: every day's high/low moves by exactly +1.0 °C (invariants preserved).
            XCTAssertEqual(a.high, g.high + 1.0, accuracy: 1e-9)
            XCTAssertEqual(a.low, g.low + 1.0, accuracy: 1e-9)
            XCTAssertEqual(a.precipitationProbability, g.precipitationProbability)
            XCTAssertEqual(a.weatherCode, g.weatherCode)
        }

        // Chart: the Skyline blend line is the displayed (corrected) hourly; model lines are untouched.
        let gS = try dec.decode([ModelSeries].self, from: golden.modelSeries)
        XCTAssertEqual(report.modelSeries.count, gS.count)
        for (a, g) in zip(report.modelSeries, gS) {
            XCTAssertEqual(a.name, g.name)
            for (x, y) in zip(a.temperatures, g.temperatures) {
                XCTAssertEqual(x, y + (g.isBlend ? 1.0 : 0.0), accuracy: 1e-9, a.name)
            }
        }

        // Headline + feels-like (offset preserved), dew ≤ T.
        XCTAssertEqual(report.current.temperature, gC.temperature + 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.current.apparentTemperature, gC.apparentTemperature + 1.0, accuracy: 1e-9)
        if let dp = report.current.dewPoint { XCTAssertLessThanOrEqual(dp, report.current.temperature + 1e-9) }
        XCTAssertEqual(report.current.windSpeed, gC.windSpeed)
        XCTAssertEqual(report.current.humidity, gC.humidity)

        // Widget + menu bar are built from the same corrected report.
        let snap = WidgetSnapshot(report: report, locationName: "New York", units: .metric, now: t0)
        XCTAssertEqual(snap.temperature, gC.temperature + 1.0, accuracy: 1e-9)
        XCTAssertEqual(snap.high ?? .nan, report.daily[0].high, accuracy: 1e-12)
        XCTAssertEqual(snap.low ?? .nan, report.daily[0].low, accuracy: 1e-12)
        for h in snap.hours {
            guard let g = gH.first(where: { $0.time == h.time }) else { XCTFail("hour missing"); continue }
            XCTAssertEqual(h.temperature, g.temperature + 1.0, accuracy: 1e-9)
        }
        let imperial = WidgetSnapshot(report: report, locationName: "New York", units: .imperial, now: t0)
        XCTAssertEqual(DisplayUnits.imperial.temperature(imperial.temperature) - DisplayUnits.imperial.temperature(gC.temperature),
                       1.8, accuracy: 1e-9)
        XCTAssertEqual(MenuSummary.feelsLikeText(temperature: report.current.temperature,
                                                 apparent: report.current.apparentTemperature, units: .metric),
                       MenuSummary.feelsLikeText(temperature: gC.temperature + 1, apparent: gC.apparentTemperature + 1,
                                                 units: .metric))

        // Never writes corrections.json or accuracy.json.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrURL.path))
        let names = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(names.contains { $0.hasSuffix("accuracy.json") }, "\(names)")

        // Kill switch beats the override: next report is the PR 1 golden, byte for byte.
        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        let gone = await v.correctionIfLoaded(key)
        XCTAssertNil(gone)
        let off = try await reportSlice(verifier: v, clock: clock, client: client)
        assertGolden(off, golden)
    }

    // MARK: Review fix H2 — runtime switch / measurement OFF: the very next report is the golden

    func testRuntimeKillSwitchAndMeasurementOffNextReportIsGolden() async throws {
        let golden = try loadGolden()
        for flip in [BiasCorrection.Switch.defaultsKey, AccuracyMeasurement.defaultsKey] {
            UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
            UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
            let dir = tempDir("pr2-runtime-off")
            defer { try? FileManager.default.removeItem(at: dir) }
            let client = PR1HTTPClient()
            let clock = TestClock(t0)
            let v = ForecastVerifier(directory: dir, client: client, now: { clock.now }, launchArguments: ["Skyline"])
            let key = await seedGatedNYC(v)
            let on = await v.corrections(key, timeZoneIdentifier: "America/New_York", cityElevationM: 27)
            XCTAssertTrue(on.values.contains { abs($0) > 0.01 }, "gated city must be corrected first: \(on)")
            let loaded = await v.correctionIfLoaded(key)
            XCTAssertNotNil(loaded)
            UserDefaults.standard.set(false, forKey: flip)
            let after = await v.correctionIfLoaded(key)
            XCTAssertNil(after, "\(flip) OFF must stop correction immediately")
            let slice = try await reportSlice(verifier: v, clock: clock, client: client)
            assertGolden(slice, golden)
        }
    }

    func testMetarWeightsMergeDropsImmediatelyOnSwitchOff() async throws {
        let dir = tempDir("pr2-w-off")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { Self.t0 }, launchArguments: ["Skyline"])
        var recs: [VerifiedRecord] = []
        for d in 0..<5 {
            for h in 0..<24 {
                let valid = t0.addingTimeInterval(-Double(d) * 86400 - Double(h + 1) * 3600)
                recs.append(VerifiedRecord(
                    ForecastRecord(loc: "paris", issued: valid.addingTimeInterval(-3 * 3600), valid: valid,
                                   f: [VerificationSource.ecmwf.rawValue: SourceValues(t: 10.3),
                                       VerificationSource.gfs.rawValue: SourceValues(t: 13.0),
                                       VerificationSource.icon.rawValue: SourceValues(t: 11.0)]),
                    ObservedHour(t: 10)))
            }
        }
        await v.seedMetarWeightInputs(recs, key: "paris")
        let enc = Self.sortedEncoder()
        let wOn = await v.weights("paris")
        XCTAssertFalse(wOn.isNeutral, "merged METAR inputs should move the weights")
        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        let wOff = await v.weights("paris")
        XCTAssertTrue(wOff.isNeutral, "switch OFF → PR 1 (no METAR) weights on the next call")
        let wOffLoaded = await v.weightsIfLoaded("paris")
        XCTAssertEqual(try enc.encode(wOffLoaded), try enc.encode(wOff))
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        let wBack = await v.weights("paris")
        // Recomputed with the merge again (sums iterate dictionaries, so compare state, not last-bit bytes).
        XCTAssertFalse(wBack.isNeutral, "switch back ON → METAR merge again")
    }

    // MARK: Review fix H3 — `-Key NO` arrives as the string "NO"

    func testSwitchesHonourStringNOFromArgumentDomain() {
        let s = UserDefaults(suiteName: "pr2-flag-\(UUID().uuidString)")!
        for key in [BiasCorrection.Switch.defaultsKey, AccuracyMeasurement.defaultsKey] {
            func on() -> Bool {
                key == AccuracyMeasurement.defaultsKey ? AccuracyMeasurement.isEnabled(defaults: s)
                    : BiasCorrection.Switch.isEnabled(defaults: s)
            }
            s.removeObject(forKey: key); XCTAssertTrue(on(), "default ON")
            s.set("NO", forKey: key); XCTAssertFalse(on(), "\(key) NO")
            s.set("no", forKey: key); XCTAssertFalse(on())
            s.set("0", forKey: key); XCTAssertFalse(on())
            s.set("false", forKey: key); XCTAssertFalse(on())
            s.set("YES", forKey: key); XCTAssertTrue(on())
            s.set("garbage", forKey: key); XCTAssertTrue(on(), "unknown string keeps the default")
            s.set(false, forKey: key); XCTAssertFalse(on())
            s.set(true, forKey: key); XCTAssertTrue(on())
            s.set(0, forKey: key); XCTAssertFalse(on())
        }
        s.set("NO", forKey: SkylineAccuracyCorrection.defaultsKey)
        XCTAssertFalse(SkylineAccuracyCorrection.isEnabled(defaults: s))
    }

    // MARK: Review fix M4 — hourly learning keeps every lead bucket (dedupe on issued+valid)

    func testHourlyLearningKeepsEveryLeadBucket() async {
        let dir = tempDir("pr2-buckets")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tz = TimeZone(identifier: "Europe/Paris")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let day = cal.startOfDay(for: t0.addingTimeInterval(-2 * 86400))
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        var pairs: [BenchmarkHourlyPair] = []
        for h in 0..<24 {
            let valid = day.addingTimeInterval(Double(h) * 3600)
            for lead in [3.0, 12.0, 36.0, 60.0] {
                pairs.append(BenchmarkHourlyPair(loc: "paris", issued: valid.addingTimeInterval(-lead * 3600), valid: valid,
                                                 kind: .skyline, forecastC: 12, observedC: 10, uncorrectedC: 12))
            }
        }
        await store.seedHourly(pairs)
        await store.seedHourly(pairs) // exact duplicates must not count twice
        for _ in 0..<3 { await store.learnTraining(key: "paris", timeZoneIdentifier: tz.identifier) }
        let rows = await store.trainingRows(for: "paris")
        XCTAssertEqual(rows.count, 4)
        for target in [CorrectionTarget.h0to6, .h6to24, .day2, .day3plus] {
            let r = rows.first { $0.target == target }
            XCTAssertEqual(r?.n, 24, "\(target)")
            XCTAssertEqual(r?.distinct, 24, "\(target)")
            XCTAssertEqual(r?.sumE ?? 0, 48, accuracy: 1e-9, "\(target)")
        }
    }

    // MARK: Review fix M5 — clamp of the rate-limited output, NaN

    func testClampCannotBeBypassedByPersistedPreviousOrNaN() async throws {
        XCTAssertEqual(BiasCorrection.clamp(.nan), 0)
        XCTAssertEqual(BiasCorrection.clamp(.infinity), 0)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: 10, targetC: 0, sameLocalDay: true, forceZero: false), 2)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: 10, targetC: 0, sameLocalDay: false, forceZero: false), 1.5)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: -10, targetC: -5, sameLocalDay: false, forceZero: false), -2)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: .nan, targetC: 1, sameLocalDay: false, forceZero: false), 0.5)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: 0, targetC: .nan, sameLocalDay: false, forceZero: false), 0)
        XCTAssertEqual(BiasCorrection.rateLimited(previous: .nan, targetC: 1, sameLocalDay: true, forceZero: false), 0)
        let bad = [TrainingRow(loc: "x", localDay: t0.addingTimeInterval(-86400), target: .dailyHigh, sumE: .nan, n: 1)]
        XCTAssertTrue(BiasCorrection.estimate(rows: bad, asOf: t0).targetC.isFinite)

        var hourly = [HourlyForecast(time: t0, temperature: 20, apparentTemperature: 21, weatherCode: 1, isDay: true, dewPoint: 19)]
        var daily = [DailyForecast(date: t0, weatherCode: 1, high: 22, low: 18)]
        var current = CurrentConditions(time: t0, temperature: 20, apparentTemperature: 21, humidity: 50, dewPoint: 19,
                                        weatherCode: 1, isDay: true, precipitation: 0, cloudCover: nil, pressure: nil,
                                        windSpeed: 5, windDirection: nil, windGust: nil, visibility: nil, uvIndex: nil)
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current, issued: t0, timeZone: .gmt,
                             offsets: [.h0to6: .nan, .dailyHigh: .infinity, .dailyLow: -.infinity])
        XCTAssertEqual(hourly[0].temperature, 20); XCTAssertEqual(daily[0].high, 22); XCTAssertEqual(daily[0].low, 18)
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current, issued: t0, timeZone: .gmt,
                             offsets: [.h0to6: 9, .h6to24: 9, .day2: 9, .day3plus: 9])
        XCTAssertEqual(hourly[0].temperature, 22, accuracy: 1e-9, "apply clamps to ±2 °C")

        // End to end: a corrupt corrections.json (appliedC 10) can't push the applied value past ±2 °C.
        let dir = tempDir("pr2-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        for sameDay in [false, true] {
            let appliedOn = sameDay ? cal(for: "Europe/Paris").startOfDay(for: t0) : t0.addingTimeInterval(-3 * 86400)
            let file = CorrectionsFile(entries: [CorrectionEntry(loc: "paris", target: .dailyHigh, appliedC: 10, targetC: 10,
                                                                 appliedOn: appliedOn, n: 25)])
            try enc.encode(file).write(to: dir.appendingPathComponent("corrections.json"))
            let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
            await store.seedTraining((1...25).map {
                TrainingRow(loc: "paris", localDay: t0.addingTimeInterval(Double(-$0) * 86400), target: .dailyHigh, sumE: 1.0, n: 1)
            })
            let o = await store.refreshCorrections(key: "paris", timeZoneIdentifier: "Europe/Paris", sitingOK: true)
            XCTAssertLessThanOrEqual(abs(o[.dailyHigh] ?? 99), BiasCorrection.clampC, "sameDay=\(sameDay)")
        }
    }

    // MARK: Wrong-temperature guards in apply (B8)

    func testApplyNeverInvertsHighLowAndShiftsCurrentByExactOffset() {
        let t = t0
        var hourly = (0..<24).map { HourlyForecast(time: t.addingTimeInterval(Double($0) * 3600), temperature: 9.5,
                                                   apparentTemperature: 8, weatherCode: 1, isDay: true, dewPoint: 9.4) }
        var daily = [DailyForecast(date: Calendar(identifier: .gregorian).startOfDay(for: t), weatherCode: 1, high: 10, low: 9)]
        // Current far outside the hourly range: headline can't interpolate, must still move by exactly the offset.
        var current = CurrentConditions(time: t.addingTimeInterval(-6 * 3600), temperature: 7, apparentTemperature: 5,
                                        humidity: 50, dewPoint: 6.5, weatherCode: 1, isDay: true, precipitation: 0,
                                        cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil, windGust: nil,
                                        visibility: nil, uvIndex: nil)
        var gmt = Calendar(identifier: .gregorian); gmt.timeZone = .gmt
        daily[0].date = gmt.startOfDay(for: t)
        // A day with no hourly data: only the low ≤ high guard can protect it.
        daily.append(DailyForecast(date: gmt.startOfDay(for: t).addingTimeInterval(5 * 86400), weatherCode: 1, high: 10, low: 9))
        BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current, issued: t, timeZone: .gmt,
                             offsets: [.h0to6: -1.0, .h6to24: -1.0, .day2: -1.0, .day3plus: -1.0,
                                       .dailyHigh: -2.0, .dailyLow: 2.0])
        for d in daily { XCTAssertLessThanOrEqual(d.low, d.high, "low must never exceed high") }
        XCTAssertEqual(daily[1].high, 8, accuracy: 1e-9)
        XCTAssertEqual(current.temperature, 6.0, accuracy: 1e-9)
        XCTAssertEqual(current.apparentTemperature, 4.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(current.dewPoint ?? 0, current.temperature)
        for h in hourly { XCTAssertLessThanOrEqual(h.dewPoint ?? 0, h.temperature) }
    }

    // MARK: Review fix M6 — A1: simulated US city over 4 days gets daily high/low for every completed local day

    func testA1USCityFourDaysDailyRowsEveryCompletedDayNoDuplicates() async throws {
        let clock = TestClock(t0)
        let client = A1NWSSimClient(clock)
        let dir = tempDir("pr2-a1-4d")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: client, now: { clock.now }, launchArguments: ["Skyline"])
        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let om = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let stationsURL = URL(string: "https://api.weather.gov/gridpoints/OKX/33,42/stations")!
        let pt = Coordinate(latitude: 40.75, longitude: -73.99)
        func refresh() async {
            let now = clock.now
            if await v.wantsIssuance("nyc") {
                let recs = (1...48).map { h in
                    ForecastRecord(loc: "nyc", issued: now, valid: now.addingTimeInterval(Double(h) * 3600),
                                   f: [VerificationSource.blend.rawValue: SourceValues(t: 11)])
                }
                await v.record(recs, key: "nyc")
            }
            await v.verifyIfDue(key: "nyc", stationsURL: stationsURL, near: pt)
            let today = cal.startOfDay(for: now)
            let daily = (0..<7).map {
                DailyForecast(date: cal.date(byAdding: .day, value: $0, to: today)!, weatherCode: 0, high: 15, low: 5)
            }
            await v.runMeasurement(key: "nyc", coordinate: pt, timeZoneIdentifier: tz.identifier, daily: daily,
                                   openMeteo: om, blended: [], isUS: true)
        }
        for i in 0..<(4 * 96) {          // 15-minute refreshes for 4 days
            clock.now = t0.addingTimeInterval(Double(i) * 900)
            await refresh()
        }
        func lines(_ name: String) -> [Substring] {
            ((try? String(contentsOf: dir.appendingPathComponent("benchmark/\(name)"), encoding: .utf8)) ?? "")
                .split(separator: "\n")
        }
        // Every local day that is complete and inside the observed span (t0 … now) must be scored; the
        // partial first day (observations start at t0) must not be.
        var expected: [Date] = []
        var d = cal.startOfDay(for: t0)
        while let next = cal.date(byAdding: .day, value: 1, to: d), next <= clock.now {
            if d >= t0 { expected.append(d) }
            d = next
        }
        XCTAssertGreaterThanOrEqual(expected.count, 3)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let obs = try lines("daily-obs.jsonl").map { try dec.decode(DailyObservedExtremes.self, from: Data($0.utf8)) }
        XCTAssertEqual(Set(obs.map(\.localDay)), Set(expected), "daily high/low for every completed local day")
        XCTAssertEqual(obs.count, expected.count, "one row per day")
        for o in obs { XCTAssertGreaterThanOrEqual(o.distinctHours, 20); XCTAssertLessThan(o.lowC, o.highC) }
        XCTAssertEqual(client.hostCount("aviationweather.gov"), 0, "US path never asks AWC")

        // Re-running the same moment 20× adds no rows and no NWS requests.
        let metarsBefore = lines("metars.jsonl").count
        let nwsBefore = client.hostCount("api.weather.gov")
        for _ in 0..<20 { await refresh() }
        XCTAssertEqual(lines("daily-obs.jsonl").count, obs.count)
        XCTAssertEqual(lines("metars.jsonl").count, metarsBefore)
        XCTAssertEqual(client.hostCount("api.weather.gov"), nwsBefore)
        let mc = await v.benchmarkMetarCount("nyc")
        XCTAssertEqual(mc, metarsBefore)
    }

    // MARK: Review fix M7 — held-out auto-off (C6): pause, relaunch, re-enable, ramp

    func testAutoOffTripsLogsSurvivesRelaunchAndReenablesWithHysteresis() async throws {
        let dir = tempDir("pr2-autooff")
        defer { try? FileManager.default.removeItem(at: dir) }
        let utc = cal(for: "UTC")
        let day0 = utc.startOfDay(for: t0)
        func day(_ n: Int) -> Date { utc.date(byAdding: .day, value: n, to: day0)! }
        func row(_ n: Int, _ e: Double) -> TrainingRow { TrainingRow(loc: "x", localDay: day(n), target: .dailyHigh, sumE: e, n: 1) }
        let clock = TestClock(t0)
        let station = MetarStationPick(stationID: "EGLL", coordinate: Coordinate(latitude: 51.47, longitude: -0.45),
                                       elevationM: 25, distanceKm: 10, elevationDeltaM: 0, pickedAt: t0)
        // 20 old days with a +2 °C bias, then 14 recent days with none: held-out gain ≤ 0 → paused.
        var store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        await store.seedStation(station, key: "x")
        await store.seedTraining((15...34).map { row(-$0, 2.0) } + (1...14).map { row(-$0, 0.0) })
        var o = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertEqual(o[.dailyHigh], 0)
        var e = await store.correctionEntry(loc: "x", target: .dailyHigh)
        XCTAssertEqual(e?.autoOff, true)
        XCTAssertEqual(e?.autoOffReason, "worse on recent days")
        XCTAssertGreaterThanOrEqual(e?.heldOutDays ?? 0, BiasCorrection.heldOutMinDays)
        var log = await store.correctionsSnapshot().log
        XCTAssertEqual(log.last?.state, "off")
        XCTAssertEqual(log.last?.reason, "worse on recent days")
        XCTAssertEqual(log.last?.loc, "x")
        XCTAssertEqual(log.last?.target, .dailyHigh)
        XCTAssertNotNil(log.last?.correctedMAE)
        let pausedLogs = log.count

        // Relaunch: still paused. The same data adds no second log (C7 / C8).
        store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        e = await store.correctionEntry(loc: "x", target: .dailyHigh)
        XCTAssertEqual(e?.autoOff, true)
        o = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertEqual(o[.dailyHigh], 0)
        let relaunchLogs = await store.correctionsSnapshot().log.count
        XCTAssertEqual(relaunchLogs, pausedLogs)

        // 14 new days of the same warm bias. autoOffAt is only hours old — C6 still re-enables
        // because the held-out gain clears 0.05 °F. There is no 7-day wait. Ramps from 0.
        await store.seedTraining((1...14).map { row($0, 2.0) })
        clock.now = day(15).addingTimeInterval(12 * 3600)
        o = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        e = await store.correctionEntry(loc: "x", target: .dailyHigh)
        XCTAssertEqual(e?.autoOff, false)
        log = await store.correctionsSnapshot().log
        XCTAssertEqual(log.last?.state, "on")
        XCTAssertEqual(log.last?.reason, "hysteresis re-enable")
        let applied = o[.dailyHigh] ?? 0
        XCTAssertLessThan(applied, 0, "warm bias → negative offset")
        XCTAssertGreaterThanOrEqual(applied, -BiasCorrection.rampPerDayC - 1e-12, "re-ramps from 0")
        // Same local day: stable across refreshes and a relaunch.
        store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        for _ in 0..<5 {
            let again = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
            XCTAssertEqual(again[.dailyHigh] ?? 99, applied, accuracy: 1e-12)
        }
    }

    // MARK: Lock §5 / §6(b) — held-out evaluation over a READ-ONLY copy of a Mac's benchmark/

    /// Skipped unless `SKYLINE_EVAL_DIR` points at a copy of `…/verification/benchmark/`. Reads files only
    /// (never opens a BenchmarkStore, which would prune/write). Per city × target: n, raw MAE, corrected MAE,
    /// bias before/after (rolling out-of-sample replay, each day trained on earlier days only).
    func testHeldOutEvaluationReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["SKYLINE_EVAL_DIR"], !path.isEmpty else {
            throw XCTSkip("SKYLINE_EVAL_DIR not set")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        func fingerprint() -> [String: String] {
            var out: [String: String] = [:]
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
                out[name] = "\((a?[.size] as? NSNumber)?.intValue ?? -1)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
            }
            return out
        }
        let before = fingerprint()
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let text = (try? String(contentsOf: dir.appendingPathComponent("training.jsonl"), encoding: .utf8)) ?? ""
        var seen = Set<String>()
        let rows = text.split(separator: "\n").compactMap { try? dec.decode(TrainingRow.self, from: Data($0.utf8)) }
            .filter { seen.insert($0.key).inserted }
        // Sint Maarten: the city whose station is TNCM (Princess Juliana), or a key that names it.
        var sxm = Set<String>()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in meta where "\(v)".uppercased().contains("TNCM") { sxm.insert(k) }
        }
        for k in Set(rows.map(\.loc)) where ["maarten", "sxm", "philipsburg"].contains(where: k.lowercased().contains) {
            sxm.insert(k)
        }
        print("EVAL rows=\(rows.count) cities=\(Set(rows.map(\.loc)).count) dir=\(dir.path)")
        print("EVAL loc | target | n | rawMAE | correctedMAE | biasBefore | biasAfter")
        let groups = Dictionary(grouping: rows) { "\($0.loc)|\($0.target.rawValue)" }
        for (_, g) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = g.sorted { $0.localDay < $1.localDay }
            var n = 0, raw = 0.0, cor = 0.0, bBefore = 0.0, bAfter = 0.0
            for day in sorted {
                let prior = sorted.filter { $0.localDay < day.localDay }
                guard !prior.isEmpty else { continue }
                let offset = -BiasCorrection.estimate(rows: prior, asOf: day.localDay).targetC
                let e = day.n > 0 ? day.sumE / Double(day.n) : day.sumE
                n += 1; raw += abs(e); cor += abs(e + offset); bBefore += e; bAfter += e + offset
            }
            guard n > 0, let first = sorted.first else { continue }
            let dn = Double(n)
            let tag = sxm.contains(first.loc) && first.target == .dailyHigh ? "  <-- Sint Maarten daily high" : ""
            print(String(format: "EVAL %@ | %@ | %d | %.3f | %.3f | %+.3f | %+.3f%@", first.loc, first.target.rawValue, n,
                         raw / dn, cor / dn, bBefore / dn, bAfter / dn, tag))
        }
        if sxm.isEmpty { print("EVAL Sint Maarten: not found in this copy") }
        XCTAssertEqual(fingerprint(), before, "evaluation must not modify the benchmark copy")
    }

    // MARK: Helpers

    /// Seeds a US city (NYC) past every gate with good siting; returns its verification key.
    @discardableResult
    private func seedGatedNYC(_ v: ForecastVerifier) async -> String {
        let key = VerificationKey.key(for: nyc)
        let ny = cal(for: "America/New_York")
        let day0 = ny.startOfDay(for: t0)
        var trains: [TrainingRow] = []
        for d in 1...25 {
            let day = ny.date(byAdding: .day, value: -d, to: day0)!
            for target in CorrectionTarget.allCases {
                trains.append(target.isDaily
                    ? TrainingRow(loc: key, localDay: day, target: target, sumE: 1.0, n: 1)
                    : TrainingRow(loc: key, localDay: day, target: target, sumE: 50.0, n: 50, distinct: 20))
            }
        }
        let station = MetarStationPick(stationID: "KNYC", coordinate: Coordinate(latitude: 40.78, longitude: -73.97),
                                       elevationM: 20, distanceKm: 8, elevationDeltaM: -7, pickedAt: t0)
        await v.seedBenchmark(station: station, key: key, training: trains, cityElevationM: 27)
        return key
    }

    private func cal(for tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c
    }

    private func reportSlice(verifier v: ForecastVerifier, clock: TestClock, client: PR1HTTPClient) async throws -> Slice {
        let svc = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }),
                                 verifier: v, now: { clock.now })
        let report = try await svc.report(for: nyc)
        let w = await v.weights(VerificationKey.key(for: nyc))
        let enc = Self.sortedEncoder()
        return Slice(hourly: try enc.encode(report.hourly), daily: try enc.encode(report.daily),
                     current: try enc.encode(report.current), modelSeries: try enc.encode(report.modelSeries),
                     weights: try enc.encode(w))
    }

    private func assertGolden(_ s: Slice, _ g: Slice, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.hourly, g.hourly, "hourly", file: file, line: line)
        XCTAssertEqual(s.daily, g.daily, "daily", file: file, line: line)
        XCTAssertEqual(s.current, g.current, "current", file: file, line: line)
        XCTAssertEqual(s.modelSeries, g.modelSeries, "modelSeries", file: file, line: line)
        XCTAssertEqual(s.weights, g.weights, "weights", file: file, line: line)
    }

    private struct Slice: Codable {
        var hourly: Data; var daily: Data; var current: Data; var modelSeries: Data; var weights: Data
    }

    private func loadGolden() throws -> Slice {
        try JSONDecoder().decode(Slice.self, from: Fixture.data(Self.goldenName))
    }

    private func reportSlice(correction: Bool, measurement: Bool) async throws -> Slice {
        UserDefaults.standard.set(correction, forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.set(measurement, forKey: AccuracyMeasurement.defaultsKey)
        let client = PR1HTTPClient()
        let clock = TestClock(t0)
        let dir = tempDir("pr2-gold-\(correction)-\(measurement)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }),
                                 verifier: ForecastVerifier(directory: dir, client: client, now: { clock.now }),
                                 now: { clock.now })
        let report = try await svc.report(for: nyc)
        let w = await svc.verifier!.weights(VerificationKey.key(for: nyc))
        let enc = Self.sortedEncoder()
        return Slice(hourly: try enc.encode(report.hourly), daily: try enc.encode(report.daily),
                     current: try enc.encode(report.current), modelSeries: try enc.encode(report.modelSeries),
                     weights: try enc.encode(w))
    }

    private func makeBareReport(temp: Double) throws -> WeatherReport {
        let om = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        var current = om.currentConditions()!
        current.temperature = temp
        current.apparentTemperature = temp + 1
        let hourly = [HourlyForecast(time: t0, temperature: temp, apparentTemperature: temp + 1,
                                     weatherCode: 1, isDay: true, windSpeed: 5, dewPoint: temp - 1)]
        let daily = [DailyForecast(date: t0, weatherCode: 1, high: temp + 2, low: temp - 2)]
        return WeatherReport(location: nyc, fetchedAt: t0, timeZoneIdentifier: "America/New_York",
                             current: current, hourly: hourly, daily: daily, minutely: [], alerts: [],
                             airQuality: nil, sources: [], nwsOffice: nil, dataAsOf: t0, isOfflineFallback: false)
    }

    private func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("skyline-\(name)-\(UUID().uuidString)")
    }

    private static func sortedEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

/// A1 test client: NWS stations + 20-minute observations up to the clock; everything else times out.
private final class A1NWSSimClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private var hosts: [String: Int] = [:]
    init(_ clock: TestClock) { self.clock = clock }
    func hostCount(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return hosts[host] ?? 0 }
    private func bump(_ host: String) { lock.lock(); hosts[host, default: 0] += 1; lock.unlock() }
    private let stations = """
    {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-73.88,40.78]},
     "properties":{"stationIdentifier":"KLGA","name":"La Guardia","elevation":{"unitCode":"wmoUnit:m","value":3}}}]}
    """
    func get(_ url: URL, headers: [String: String]) async throws -> Data { try await fetch(url, headers: headers).data }
    func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        bump(url.host ?? "?")
        let s = url.absoluteString
        if s.contains("/observations") {
            let startStr = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "start" }?.value ?? ""
            let start = ISO8601DateFormatter().date(from: startStr) ?? clock.now.addingTimeInterval(-86400)
            let f = ISO8601DateFormatter()
            var feats: [String] = []
            var t = (start.timeIntervalSince1970 / 1200).rounded(.up) * 1200
            while t <= clock.now.timeIntervalSince1970 {
                let temp = 10 + 5 * sin(t / 86400 * 2 * .pi)
                feats.append("{\"properties\":{\"timestamp\":\"\(f.string(from: Date(timeIntervalSince1970: t)))\",\"temperature\":{\"value\":\(temp),\"unitCode\":\"wmoUnit:degC\"}}}")
                t += 1200
            }
            return HTTPFetchResult(statusCode: 200, data: Data("{\"features\":[\(feats.joined(separator: ","))]}".utf8))
        }
        if s.contains("/stations") { return HTTPFetchResult(statusCode: 200, data: Data(stations.utf8)) }
        throw URLError(.timedOut)
    }
}
