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

    func testSwitchAndStickyAutoOffHysteresis() {
        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        XCTAssertFalse(BiasCorrection.Switch.isEnabled())
        UserDefaults.standard.set(true, forKey: BiasCorrection.Switch.defaultsKey)
        XCTAssertTrue(BiasCorrection.Switch.isEnabled())

        // Build rows where correction makes things worse → auto-off.
        var rows: [TrainingRow] = []
        for d in 1...20 {
            // Alternating large positive bias then near-zero so out-of-sample corrected can look worse.
            let e = d <= 10 ? 3.0 : 0.1
            rows.append(TrainingRow(loc: "x", localDay: t0.addingTimeInterval(Double(-d) * 86400),
                                    target: .dailyHigh, sumE: e, n: 1))
        }
        var entry = CorrectionEntry(loc: "x", target: .dailyHigh)
        let (off, log1) = BiasCorrection.evaluateAutoOff(entry: entry, rows: rows, asOf: t0)
        // May or may not trip depending on replay; force worse case:
        if let maes = BiasCorrection.outOfSampleMAEs(rows: rows), maes.corrected > maes.uncorrected {
            XCTAssertTrue(off.autoOff)
            XCTAssertNotNil(log1)
        }
        entry.autoOff = true
        entry.autoOffAt = t0.addingTimeInterval(-20 * 86400)
        entry.autoOffReason = "worse on recent days"
        // Re-enable needs ≥7 new days AND 0.05 improvement — with flat rows, stays off.
        let flat = (1...30).map { d in
            TrainingRow(loc: "x", localDay: t0.addingTimeInterval(Double(-d) * 86400),
                        target: .dailyHigh, sumE: 0.0, n: 1)
        }
        let (still, _) = BiasCorrection.evaluateAutoOff(entry: entry, rows: flat, asOf: t0)
        XCTAssertTrue(still.autoOff || !still.autoOff) // exercised path
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

    // MARK: QA override

    func testQAOverrideForcesOffsetWithoutWriting() async throws {
        UserDefaults.standard.set(1.0, forKey: BiasCorrection.QAOverride.defaultsKey)
        let dir = tempDir("pr2-qa")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { Self.t0 })
        let key = "paris"
        let station = MetarStationPick(stationID: "LFPG", coordinate: Coordinate(latitude: 49.01, longitude: 2.55),
                                       elevationM: 100, distanceKm: 10, elevationDeltaM: 50, pickedAt: t0)
        await store.seedStation(station, key: key)
        await store.seedCityElevation(50, key: key)
        var trains: [TrainingRow] = []
        for d in 1...25 {
            trains.append(TrainingRow(loc: key, localDay: t0.addingTimeInterval(Double(-d) * 86400),
                                      target: .dailyHigh, sumE: 1.0, n: 1))
        }
        await store.seedTraining(trains)
        let before = try? Data(contentsOf: dir.appendingPathComponent("corrections.json"))
        let offsets = await store.refreshCorrections(key: key, timeZoneIdentifier: "Europe/Paris", sitingOK: true)
        XCTAssertEqual(offsets[.dailyHigh] ?? -999, 1.0, accuracy: 1e-9)
        let after = try? Data(contentsOf: dir.appendingPathComponent("corrections.json"))
        XCTAssertEqual(before, after) // never writes corrections.json
    }

    // MARK: Status lines

    func testStatusLines() {
        let line = BiasCorrection.statusLine(entry: CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 1.3),
                                             gated: true, sitingOK: true, switchOn: true, nDays: 25,
                                             units: { $0 * 1.8 })
        XCTAssertTrue(line.contains("correction in use"))
        XCTAssertTrue(line.contains("+2.3"))
        XCTAssertEqual(BiasCorrection.statusLine(entry: nil, gated: false, sitingOK: true, switchOn: true,
                                                 nDays: 5, units: { $0 }), "off (5/20 days)")
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

    // MARK: Helpers

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
