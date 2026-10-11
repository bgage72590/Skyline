import XCTest
@testable import SkylineCore

final class VerificationTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000) // on the hour

    // MARK: Observations

    func testParsesNWSObservationsFixture() throws {
        let obs = try NWSObservationParser.decode(try Fixture.data("nws_observations"))
        XCTAssertEqual(obs.count, 40)
        XCTAssertTrue(obs.first!.time < obs.last!.time, "sorted oldest first")
        XCTAssertEqual(obs.last!.temperatureC, 15)
        XCTAssertTrue(obs.last!.precipitating, "+RA is precipitation")
        XCTAssertTrue(obs.contains { $0.windKmh != nil })
        XCTAssertTrue(obs.contains { $0.precipLastHourMM != nil })
        let v = ISO8601DateFormatter().date(from: "2026-10-11T18:00:00Z")!
        let hour = try XCTUnwrap(ObservationAggregator.observe(obs, validTime: v))
        XCTAssertEqual(hour.t, 15)
        XCTAssertEqual(hour.wet, true)
        XCTAssertNotNil(hour.w)
    }

    func testAggregatorDryHourAndGaps() {
        var obs: [StationObservation] = []
        for i in 0..<12 {
            let minutes = Double(i * 5 - 55)
            let temp = 10 + Double(i) * 0.1
            let wind: Double? = i == 11 ? 12 : nil
            obs.append(StationObservation(time: t0.addingTimeInterval(minutes * 60), temperatureC: temp,
                                          windKmh: wind, precipLastHourMM: nil, precipitating: false))
        }
        let h = ObservationAggregator.observe(obs, validTime: t0)!
        XCTAssertEqual(h.wet, false)
        XCTAssertEqual(h.t!, 11.1, accuracy: 1e-9)
        XCTAssertEqual(h.w, 12)
        XCTAssertNil(ObservationAggregator.observe(obs, validTime: t0.addingTimeInterval(5 * 3600)))
    }

    // MARK: Scoring

    private func record(lead: Double, valid: Date, _ f: [VerificationSource: SourceValues]) -> ForecastRecord {
        ForecastRecord(loc: "x", issued: valid.addingTimeInterval(-lead * 3600), valid: valid,
                       f: Dictionary(uniqueKeysWithValues: f.map { ($0.key.rawValue, $0.value) }))
    }

    /// `n` hours over `days` days: ECMWF is 1° warm, GFS 3° cold, HRRR right on; every 4th hour is wet.
    private func fixture(n: Int, days: Double, lead: Double = 3) -> [VerifiedRecord] {
        (0..<n).map { i in
            let valid = t0.addingTimeInterval(Double(i) / Double(max(n - 1, 1)) * days * 86400)
            let obsT = 10.0 + Double(i % 7)
            let wet = i % 4 == 0
            return VerifiedRecord(record(lead: lead, valid: valid, [
                .ecmwf: SourceValues(t: obsT + 1, p: wet ? 0.5 : 0, w: 10),
                .gfs: SourceValues(t: obsT - 3, p: 0.5, w: 20),
                .hrrr: SourceValues(t: obsT, p: wet ? 1 : 0, w: 12),
                .nws: SourceValues(t: obsT + 0.5, pop: wet ? 80 : 10),
                .blend: SourceValues(t: obsT + 0.2, pop: wet ? 70 : 20),
            ]), ObservedHour(t: obsT, w: 12, wet: wet))
        }
    }

    func testScoresMAEBiasRainAndBrier() {
        let s = AccuracyScorer.score(fixture(n: 40, days: 5), now: t0, halfLifeDays: 0)
        XCTAssertEqual(s.pairs, 40)
        XCTAssertEqual(s.days, 5, accuracy: 1e-9)
        let e = s.overall[.ecmwf]!, g = s.overall[.gfs]!, h = s.overall[.hrrr]!
        XCTAssertEqual(e.tempMAE!, 1, accuracy: 1e-9)
        XCTAssertEqual(e.tempBiasMean!, 1, accuracy: 1e-9)
        XCTAssertEqual(g.tempBiasMean!, -3, accuracy: 1e-9)
        XCTAssertEqual(h.tempMAE!, 0, accuracy: 1e-9)
        XCTAssertEqual(e.windMAE!, 2, accuracy: 1e-9)
        XCTAssertEqual(g.hitRate!, 1, accuracy: 1e-9)
        XCTAssertEqual(g.falseAlarms, 30, accuracy: 1e-9)
        XCTAssertEqual(g.falseAlarmRatio!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(h.rainAccuracy!, 1, accuracy: 1e-9)
        XCTAssertEqual(s.overall[.nws]!.brier!, (10 * 0.04 + 30 * 0.01) / 40, accuracy: 1e-9)
        XCTAssertNil(e.brier, "no probability, no Brier")
        XCTAssertEqual(s.samplesByBucket[.h0to6], 40)
    }

    func testAgeWeightingFavoursRecentPairs() {
        let old = (0..<10).map { i in VerifiedRecord(record(lead: 3, valid: t0.addingTimeInterval(Double(i) * 3600),
                                                             [.ecmwf: SourceValues(t: 14)]), ObservedHour(t: 10)) }
        let recent = (0..<10).map { i in VerifiedRecord(record(lead: 3, valid: t0.addingTimeInterval(10 * 86400 + Double(i) * 3600),
                                                                [.ecmwf: SourceValues(t: 10)]), ObservedHour(t: 10)) }
        let now = t0.addingTimeInterval(10.5 * 86400)
        XCTAssertEqual(AccuracyScorer.score(old + recent, now: now, halfLifeDays: 0).overall[.ecmwf]!.tempMAE!, 2, accuracy: 1e-9)
        XCTAssertLessThan(AccuracyScorer.score(old + recent, now: now, halfLifeDays: 1).overall[.ecmwf]!.tempMAE!, 0.01)
    }

    // MARK: Adaptive weights

    func testWeightsStayNeutralUntilEnoughData() {
        let short = AccuracyScorer.score(fixture(n: 200, days: 2), now: t0, halfLifeDays: 0)
        XCTAssertTrue(AdaptiveWeighting.weights(from: short).isNeutral, "under 3 days")
        let sparse = AccuracyScorer.score(fixture(n: 10, days: 5), now: t0, halfLifeDays: 0)
        XCTAssertTrue(AdaptiveWeighting.weights(from: sparse).isNeutral, "under 20 samples per bucket")
    }

    func testInverseMAEWeightsWithFloorCapAndShrinkage() {
        let s = AccuracyScorer.score(fixture(n: 400, days: 10), now: t0, halfLifeDays: 0)
        let w = AdaptiveWeighting.weights(from: s)
        let m = { (src: VerificationSource) in w.multiplier(.temperature, src, leadHours: 3) }
        XCTAssertGreaterThan(m(.hrrr), m(.nws))
        XCTAssertGreaterThan(m(.nws), m(.ecmwf))
        XCTAssertGreaterThan(m(.ecmwf), m(.gfs))
        let cfg = AdaptiveWeighting.Config()
        for src in VerificationSource.inputs {
            XCTAssertGreaterThanOrEqual(m(src), cfg.floor)
            XCTAssertLessThanOrEqual(m(src), cfg.cap)
        }
        XCTAssertEqual(m(.gfs), cfg.floor, accuracy: 1e-9, "worst source hits the floor, never zero")
        XCTAssertNil(w.multipliers[.temperature]?[.h0to6]?[.blend], "the blend never weights itself")
        XCTAssertEqual(w.multiplier(.temperature, .hrrr, leadHours: 30), 1)
        XCTAssertLessThan(w.multiplier(.rain, .gfs, leadHours: 3), w.multiplier(.rain, .hrrr, leadHours: 3))

        var cfg2 = AdaptiveWeighting.Config(); cfg2.floor = 0.01; cfg2.cap = 100
        let few = AdaptiveWeighting.weights(from: AccuracyScorer.score(fixture(n: 30, days: 10), now: t0, halfLifeDays: 0), config: cfg2)
        let many = AdaptiveWeighting.weights(from: s, config: cfg2)
        XCTAssertLessThan(abs(few.multiplier(.temperature, .ecmwf, leadHours: 3) - 1),
                          abs(many.multiplier(.temperature, .ecmwf, leadHours: 3) - 1))
    }

    func testLearnedWeightsMoveTheBlend() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let now = om.hourlyTimes[0]
        let neutral = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now)
        var w = BlendWeights()
        for b in LeadBucket.allCases {
            w.multipliers[.temperature, default: [:]][b] = Dictionary(uniqueKeysWithValues: VerificationSource.inputs.map { ($0, $0 == .ecmwf ? 100 : 0.01) })
        }
        let learned = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now, weights: w)
        let ecmwf = om.hourlyColumn("temperature_2m", model: .ecmwf)!
        var closer = 0, compared = 0
        for (i, (a, b)) in zip(neutral, learned).enumerated() where i < ecmwf.count {
            guard let e = ecmwf[i], abs(a.temperature - e) > 0.2 else { continue }
            compared += 1
            if abs(b.temperature - e) < abs(a.temperature - e) { closer += 1 }
        }
        XCTAssertGreaterThan(compared, 10)
        XCTAssertEqual(closer, compared)
    }

    // MARK: Nowcast weighting

    func testShortRangePrecipitationLeansOnHRRRAndNowcast() throws {
        XCTAssertGreaterThan(ForecastBlender.precipitationWeight(.model(.hrrr), leadHours: 1),
                             3 * ForecastBlender.precipitationWeight(.model(.gfs), leadHours: 1))
        XCTAssertEqual(ForecastBlender.precipitationWeight(.model(.gfs), leadHours: 12),
                       ForecastBlender.weight(.model(.gfs), leadHours: 12))
        XCTAssertEqual(ForecastBlender.nowcastShare(leadHours: 0), 0.6, accuracy: 1e-9)
        XCTAssertEqual(ForecastBlender.nowcastShare(leadHours: 3), 0)

        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let now = om.hourlyTimes[2].addingTimeInterval(-1800)
        let next = om.hourlyTimes[2]
        let wet = (0..<4).map { MinutelyPrecipitation(time: next.addingTimeInterval(Double(-45 + 15 * $0) * 60), precipitation: 2) }
        let dry = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now)
        let rainy = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now, minutely: wet)
        let a = dry.first { $0.time == next }!, b = rainy.first { $0.time == next }!
        XCTAssertGreaterThan(b.precipitation ?? 0, (a.precipitation ?? 0) + 2)
        XCTAssertGreaterThan(b.precipitationProbability ?? 0, a.precipitationProbability ?? 0)
        let far = om.hourlyTimes[8]
        XCTAssertEqual(dry.first { $0.time == far }?.precipitation, rainy.first { $0.time == far }?.precipitation)
    }

    // MARK: Sampler + store

    func testSamplerRecordsLeadLadderWithAllSources() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let issued = om.hourlyTimes[0]
        let blended = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: issued)
        let recs = ForecastSampler.records(location: "nyc", issued: issued, openMeteo: om, nwsHourly: [], blended: blended)
        XCTAssertFalse(recs.isEmpty)
        XCTAssertTrue(recs.allSatisfy { ForecastSampler.leads.contains(Int($0.leadHours.rounded())) })
        XCTAssertTrue(recs.allSatisfy { $0.values(.blend)?.t != nil })
        XCTAssertTrue(recs.contains { $0.values(.ecmwf)?.t != nil })
        XCTAssertLessThanOrEqual(recs.count, ForecastSampler.leads.count)
    }

    func testVerifierRecordsPairsPersistsAndThrottles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let recs = (1...6).map { h in
            record(lead: Double(h), valid: t0.addingTimeInterval(Double(h) * 3600),
                   [.blend: SourceValues(t: 11), .ecmwf: SourceValues(t: 12)])
        }
        await v.record(recs, key: "x")
        let throttled = await v.wantsIssuance("x")
        XCTAssertFalse(throttled)
        clock.now = t0.addingTimeInterval(7 * 3600)
        let obs = (0..<90).map { i in
            StationObservation(time: t0.addingTimeInterval(Double(i) * 5 * 60), temperatureC: 10, windKmh: nil,
                               precipLastHourMM: nil, precipitating: false)
        }
        await v.ingest(observations: obs, key: "x")
        let report = await v.report("x")
        XCTAssertEqual(report.verifiedPairs, 6)
        XCTAssertEqual(report.pendingForecasts, 0)
        XCTAssertEqual(report.status, .collecting)
        XCTAssertEqual(report.overall[.ecmwf]!.tempMAE!, 2, accuracy: 1e-6)
        XCTAssertTrue(report.weights.isNeutral)

        let v2 = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let again = await v2.report("x")
        XCTAssertEqual(again.verifiedPairs, 6)
        let wants = await v2.wantsIssuance("x")
        XCTAssertTrue(wants, "3 h passed")

        clock.now = t0.addingTimeInterval(91 * 86400)
        let v3 = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let pruned = await v3.report("x")
        XCTAssertEqual(pruned.verifiedPairs, 0)
    }

    func testCurrentLocationKeyIsCoarse() {
        let a = WeatherLocation(id: "current", name: "Here", coordinate: Coordinate(latitude: 41.141, longitude: -73.262), isCurrentLocation: true)
        let b = WeatherLocation(id: "current", name: "Here", coordinate: Coordinate(latitude: 41.152, longitude: -73.251), isCurrentLocation: true)
        XCTAssertEqual(VerificationKey.key(for: a), VerificationKey.key(for: b))
        XCTAssertEqual(VerificationKey.key(for: WeatherLocation(id: "nyc", name: "NYC", coordinate: Coordinate(latitude: 40.7, longitude: -74))), "nyc")
    }
}

