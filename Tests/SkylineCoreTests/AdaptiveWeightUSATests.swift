import XCTest
@testable import SkylineCore

/// USA temperature-only adaptive weights: per-bucket gates, rate limit, no city boosts.
final class AdaptiveWeightUSATests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(lead: Double, valid: Date, _ f: [VerificationSource: SourceValues]) -> ForecastRecord {
        ForecastRecord(loc: "x", issued: valid.addingTimeInterval(-lead * 3600), valid: valid,
                       f: Dictionary(uniqueKeysWithValues: f.map { ($0.key.rawValue, $0.value) }))
    }

    /// Hours of two sources at a fixed lead, spread across `days` distinct UTC days.
    private func series(days: Int, perDay: Int, lead: Double, ecmwfError: Double, gfsError: Double,
                        wind: Bool = true, rain: Bool = true) -> [VerifiedRecord] {
        var out: [VerifiedRecord] = []
        for d in 0..<days {
            for h in 0..<perDay {
                let valid = t0.addingTimeInterval(Double(d) * 86400 + Double(h) * 3600)
                let obs = 10.0
                let wet = h % 2 == 0
                out.append(VerifiedRecord(record(lead: lead, valid: valid, [
                    .ecmwf: SourceValues(t: obs + ecmwfError, p: wet ? 0 : 1, w: wind ? 10 : nil),
                    .gfs: SourceValues(t: obs + gfsError, p: wet ? 1 : 0, w: wind ? 20 : nil),
                    .nws: SourceValues(t: obs + 0.4, pop: wet ? 80 : 10),
                ]), ObservedHour(t: obs, w: 12, wet: wet)))
            }
        }
        return out
    }

    private func scored(_ recs: [VerifiedRecord]) -> AccuracyScorer.Scores {
        AccuracyScorer.score(recs, now: t0.addingTimeInterval(20 * 86400), halfLifeDays: 0)
    }

    func testGlobalMinDaysStaysThreeWhileLongLeadGateIsSeparate() {
        let cfg = AdaptiveWeighting.Config()
        XCTAssertEqual(cfg.minDays, 3)
        XCTAssertEqual(cfg.minSamples, 20)
        XCTAssertEqual(cfg.floor, 0.35)
        XCTAssertEqual(cfg.cap, 3.0, "temperature cap is 3.0; floor, shrink, and half-life are unchanged")
        XCTAssertEqual(cfg.shrink, 40)
        XCTAssertFalse(cfg.longLeadStricterGates)
        XCTAssertEqual(cfg.longLeadMinSamples, 40)
        XCTAssertEqual(cfg.longLeadMinDays, 7)
        XCTAssertEqual(cfg.kinds, [.temperature])
    }

    /// One nearly perfect source against five poor ones clears the cap. The clamp is 3.0, not 2.5.
    func testTemperatureMultiplierClampsAtThree() {
        var recs: [VerifiedRecord] = []
        for d in 0..<10 {
            for h in 0..<40 {
                let valid = t0.addingTimeInterval(Double(d) * 86400 + Double(h) * 3600)
                var f: [VerificationSource: SourceValues] = [:]
                for src in VerificationSource.inputs {
                    f[src] = SourceValues(t: 10 + (src == .nws ? 0 : 12))
                }
                recs.append(VerifiedRecord(record(lead: 3, valid: valid, f), ObservedHour(t: 10)))
            }
        }
        let scores = AccuracyScorer.score(recs, now: t0.addingTimeInterval(20 * 86400), halfLifeDays: 0, dedupe: false)
        let w = AdaptiveWeighting.weights(from: scores)
        XCTAssertEqual(w.multiplier(.temperature, .nws, leadHours: 3), 3, accuracy: 1e-9)
        XCTAssertEqual(w.multiplier(.temperature, .gfs, leadHours: 3), AdaptiveWeighting.Config().floor, accuracy: 1e-9)
        XCTAssertEqual(w.multiplier(.rain, .nws, leadHours: 3), 1)
        XCTAssertEqual(w.multiplier(.wind, .nws, leadHours: 3), 1)
    }

    func testShortLeadKeeps20And3WhenLongLeadGateIsOn() {
        var cfg = AdaptiveWeighting.Config()
        cfg.longLeadStricterGates = true
        // 4 distinct days and 24 samples: clears 0–6h (20/3), not 6–24h (40/7).
        let short = scored(series(days: 4, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4))
        let w = AdaptiveWeighting.weights(from: short, config: cfg)
        XCTAssertGreaterThan(w.multiplier(.temperature, .ecmwf, leadHours: 3),
                             w.multiplier(.temperature, .gfs, leadHours: 3))
        XCTAssertEqual(w.multiplier(.temperature, .ecmwf, leadHours: 12), 1, "6–24h below 40/7 stays neutral")
        XCTAssertTrue(AdaptiveWeighting.isReady(short, config: cfg))
    }

    func testLongLeadRequires40SamplesAnd7Days() {
        var cfg = AdaptiveWeighting.Config()
        cfg.longLeadStricterGates = true
        let sparse = scored(series(days: 6, perDay: 8, lead: 12, ecmwfError: 0.2, gfsError: 4))
        XCTAssertTrue(AdaptiveWeighting.weights(from: sparse, config: cfg).isNeutral, "6 days < 7")
        XCTAssertFalse(AdaptiveWeighting.isReady(sparse, config: cfg))

        let thin = scored(series(days: 8, perDay: 4, lead: 12, ecmwfError: 0.2, gfsError: 4))
        XCTAssertTrue(AdaptiveWeighting.weights(from: thin, config: cfg).isNeutral, "32 samples < 40")

        let ready = scored(series(days: 8, perDay: 6, lead: 30, ecmwfError: 0.2, gfsError: 4))
        let w = AdaptiveWeighting.weights(from: ready, config: cfg)
        XCTAssertGreaterThan(w.multiplier(.temperature, .ecmwf, leadHours: 30),
                             w.multiplier(.temperature, .gfs, leadHours: 30))
        XCTAssertEqual(w.multiplier(.temperature, .ecmwf, leadHours: 12), 1, "other buckets stay 1")
        // day2 (36 h) and day3+ (72 h) use the same gate; one eligible bucket is enough.
        XCTAssertEqual(w.multiplier(.temperature, .ecmwf, leadHours: 60), 1)
    }

    func testBucketNeedsTwoEligibleSources() {
        var cfg = AdaptiveWeighting.Config()
        cfg.longLeadStricterGates = true
        var recs = series(days: 8, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4)
        // Drop GFS so only one input has temperature skill in the bucket.
        recs = recs.map { rec in
            var f = rec.r.f
            f.removeValue(forKey: VerificationSource.gfs.rawValue)
            f.removeValue(forKey: VerificationSource.nws.rawValue)
            return VerifiedRecord(ForecastRecord(loc: rec.r.loc, issued: rec.r.issued, valid: rec.r.valid, f: f), rec.o)
        }
        let w = AdaptiveWeighting.weights(from: scored(recs), config: cfg)
        XCTAssertTrue(w.isNeutral, "one eligible source does not move")
    }

    func testTemperatureOnlyLeavesWindAndRainAtOne() {
        var cfg = AdaptiveWeighting.Config()
        cfg.kinds = [.temperature, .wind, .rain]
        let w = AdaptiveWeighting.weights(from: scored(series(days: 8, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4)),
                                          config: cfg)
        XCTAssertGreaterThan(w.multiplier(.temperature, .ecmwf, leadHours: 3), 1)
        XCTAssertEqual(w.multiplier(.wind, .gfs, leadHours: 3), 1)
        XCTAssertEqual(w.multiplier(.rain, .gfs, leadHours: 3), 1)
        XCTAssertNil(w.multipliers[.wind])
        XCTAssertNil(w.multipliers[.rain])
        XCTAssertTrue(AdaptiveWeighting.isReady(scored(series(days: 8, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4)),
                                                config: cfg))
    }

    func testRainOnlyHistoryIsNotReady() {
        let recs = (0..<40).map { i -> VerifiedRecord in
            let valid = t0.addingTimeInterval(Double(i) * 6 * 3600)
            let wet = i % 2 == 0
            return VerifiedRecord(record(lead: 3, valid: valid, [
                .ecmwf: SourceValues(p: wet ? 0 : 1),
                .gfs: SourceValues(p: wet ? 1 : 0),
            ]), ObservedHour(wet: wet))
        }
        let s = scored(recs)
        XCTAssertTrue(AdaptiveWeighting.weights(from: s).isNeutral)
        XCTAssertFalse(AdaptiveWeighting.isReady(s))
    }

    func testRateLimitClampsStepsSameDayAndNaN() {
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: 1, proposed: 2.5, sameLocalDay: false), 1.25, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: 1.2, proposed: 0.35, sameLocalDay: false), 0.95, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: 1.4, proposed: 1.5, sameLocalDay: false), 1.5, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: 1.4, proposed: 0.2, sameLocalDay: true), 1.4, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: nil, proposed: 2, sameLocalDay: false), 1.25, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: 1.3, proposed: .nan, sameLocalDay: false), 1.3, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: .infinity, proposed: .nan, sameLocalDay: false), 1, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.rateLimited(previous: nil, proposed: .nan, sameLocalDay: true), 1, accuracy: 1e-12)
        XCTAssertEqual(AdaptiveWeighting.maxDailyMultiplierDelta, 0.25, accuracy: 1e-12)
    }

    func testSameScoresGiveSameWeightsWithNoCityArgument() {
        let s = scored(series(days: 8, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4))
        var usa = AdaptiveWeighting.Config()
        usa.longLeadStricterGates = true
        XCTAssertEqual(AdaptiveWeighting.weights(from: s, config: usa),
                       AdaptiveWeighting.weights(from: s, config: usa))
        XCTAssertNil(AppliedTemperatureWeightStore.coordinate(fromLocationKey: "paris"))
        XCTAssertNil(AppliedTemperatureWeightStore.coordinate(fromLocationKey: "x"))
        XCTAssertTrue(AppliedTemperatureWeightStore.isUSALocationKey("40.7128,-74.0060"))
        XCTAssertTrue(AppliedTemperatureWeightStore.isUSALocationKey("here@41.2,-73.2"))
        XCTAssertFalse(AppliedTemperatureWeightStore.isUSALocationKey("51.5074,-0.1278"))
        XCTAssertFalse(AppliedTemperatureWeightStore.isUSALocationKey("48.8534,2.3488"))
    }

    func testVerifierUSARateLimitForeignTipGatesAndReset() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-aw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0.addingTimeInterval(6 * 86400))
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let nyc = "40.7128,-74.0060"
        let london = "51.5074,-0.1278"
        // 6–24h, 5 days × 6 hours: clears tip 20/3, not USA 40/7.
        let longLead = series(days: 5, perDay: 6, lead: 12, ecmwfError: 0.2, gfsError: 4)
        func relocated(_ recs: [VerifiedRecord], _ key: String) -> [ForecastRecord] {
            recs.map { ForecastRecord(loc: key, issued: $0.r.issued, valid: $0.r.valid, f: $0.r.f) }
        }
        await v.record(relocated(longLead, nyc), key: nyc)
        await v.record(relocated(longLead, london), key: london)
        let obs = longLead.map {
            StationObservation(time: $0.r.valid, temperatureC: 10, windKmh: 12, precipLastHourMM: nil, precipitating: false)
        }
        await v.ingest(observations: obs, key: nyc)
        await v.ingest(observations: obs, key: london)
        let usa = await v.weights(nyc, timeZoneIdentifier: "America/New_York")
        let foreign = await v.weights(london, timeZoneIdentifier: "Europe/London")
        XCTAssertEqual(usa.multiplier(.temperature, .ecmwf, leadHours: 12), 1, "USA 6–24h stays neutral below 40/7")
        XCTAssertGreaterThan(foreign.multiplier(.temperature, .ecmwf, leadHours: 12), 1, "foreign keeps tip 20/3")
        XCTAssertEqual(foreign.multiplier(.rain, .gfs, leadHours: 12), 1)

        // 0–6h, plenty of days: USA proposal is far from 1, applied steps at most 0.25, same day freezes.
        let short = series(days: 8, perDay: 6, lead: 3, ecmwfError: 0.2, gfsError: 4)
        let v2dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-aw2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: v2dir) }
        let clock2 = TestClock(t0.addingTimeInterval(8 * 86400))
        let v2 = ForecastVerifier(directory: v2dir, client: MockHTTPClient(), now: { clock2.now })
        await v2.record(relocated(short, nyc), key: nyc)
        await v2.ingest(observations: short.map {
            StationObservation(time: $0.r.valid, temperatureC: 10, windKmh: nil, precipLastHourMM: nil, precipitating: false)
        }, key: nyc)
        let first = await v2.weights(nyc, timeZoneIdentifier: "America/New_York")
        let m1 = first.multiplier(.temperature, .ecmwf, leadHours: 3)
        XCTAssertLessThanOrEqual(abs(m1 - 1), 0.25 + 1e-9)
        XCTAssertGreaterThan(abs(m1 - 1), 0.2, "the raw proposal is past the daily cap, so the step is used")
        let again = await v2.weights(nyc, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(again.multiplier(.temperature, .ecmwf, leadHours: 3), m1, accuracy: 1e-12, "same local day")
        XCTAssertEqual(again.multiplier(.rain, .gfs, leadHours: 3), 1)
        XCTAssertEqual(again.multiplier(.wind, .ecmwf, leadHours: 3), 1)

        clock2.now = clock2.now.addingTimeInterval(36 * 3600)
        let next = await v2.weights(nyc, timeZoneIdentifier: "America/New_York")
        let m2 = next.multiplier(.temperature, .ecmwf, leadHours: 3)
        XCTAssertLessThanOrEqual(abs(m2 - m1), 0.25 + 1e-9)
        XCTAssertGreaterThan(m2, m1, "a new local day steps toward the better source")

        let reloaded = ForecastVerifier(directory: v2dir, client: MockHTTPClient(), now: { clock2.now })
        let stored = await reloaded.weights(nyc, timeZoneIdentifier: "America/New_York")
        XCTAssertEqual(stored.multiplier(.temperature, .ecmwf, leadHours: 3), m2, accuracy: 1e-6)
        let url = v2dir.appendingPathComponent(AppliedTemperatureWeightStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("corrections"))

        await reloaded.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "reset deletes the applied-weight file")
        let cleared = await reloaded.weights(nyc, timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(cleared.isNeutral, "reset forgets applied multipliers")
    }
}
