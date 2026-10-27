import Foundation
import XCTest
@testable import SkylineCore

/// Form 4: rain headline, US bias station/statusLine, MET Norway pending, Decision 2 boundaries.
final class Fix4Tests: XCTestCase {
    private var clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))

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

    // MARK: Fix 3 — statusLine / gate constants / siting / units

    func testGateThresholdConstants() {
        XCTAssertEqual(BiasCorrection.hourlyGateDays, 7)
        XCTAssertEqual(BiasCorrection.hourlyGatePairs, 300)
        XCTAssertEqual(BiasCorrection.dailyGateDays, 14)
        XCTAssertEqual(BiasCorrection.dailyGatePairs, 20)
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
        let meters = """
        {"features":[{"properties":{"stationIdentifier":"KBDR","name":"Bridgeport",
        "elevation":{"value":2,"unitCode":"wmoUnit:m"}},
        "geometry":{"coordinates":[-73.13,41.16]}}]}
        """.data(using: .utf8)!
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
}
