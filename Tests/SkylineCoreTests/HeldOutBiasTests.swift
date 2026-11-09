import Foundation
import XCTest
@testable import SkylineCore

/// Held-out bias learner + auto-off (plan A1–A12, lock C1–C14).
final class HeldOutBiasTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
        super.tearDown()
    }

    // MARK: C5 — grader

    func testNoLeakageDayIsNeverInItsOwnFit() {
        let days = (0..<10).map { day($0) }
        let prior = days.dropLast().map { TrainingRow(loc: "c", localDay: $0, target: .h0to6, sumE: 2, n: 1) }
        let errors = days.map { HeldOutError(day: $0, error: 2) }
        let asOf = day(10)
        let clean = BiasCorrection.heldOutGain(rows: prior, pairErrors: errors, asOfDay: asOf)
        let leaked = prior + [TrainingRow(loc: "c", localDay: day(9), target: .h0to6, sumE: 500, n: 1)]
        let dirty = BiasCorrection.heldOutGain(rows: leaked, pairErrors: errors, asOfDay: asOf)
        XCTAssertEqual(clean, dirty, "day T's own training row must not change T's offset")
        let t = day(9)
        let est = BiasCorrection.estimate(rows: prior.filter { $0.localDay < t }, asOf: t).targetC
        let est2 = BiasCorrection.estimate(rows: leaked.filter { $0.localDay < t }, asOf: t).targetC
        XCTAssertEqual(est, est2)
    }

    func testPairLevelNotDailyMean() {
        // 80 identical prior days → estimate = +1 °C on the graded day. Errors [1, 1, 1, −5]:
        // daily-mean gain is negative; pair-level gain is positive.
        var rows: [TrainingRow] = (0..<80).map {
            TrainingRow(loc: "c", localDay: day($0), target: .h0to6, sumE: 1.5, n: 1)
        }
        let graded = day(80)
        let est = BiasCorrection.estimate(rows: rows, asOf: graded).targetC
        XCTAssertEqual(est, 1, accuracy: 1e-9)
        let samples = [1.0, 1.0, 1.0, -5.0]
        let errors = samples.map { HeldOutError(day: graded, error: $0) }
        rows.append(TrainingRow(loc: "c", localDay: graded, target: .h0to6, sumE: samples.reduce(0, +), n: samples.count))
        let gain = BiasCorrection.heldOutGain(rows: rows, pairErrors: errors, asOfDay: day(81))
        let mean = samples.reduce(0, +) / Double(samples.count)
        let dailyGain = abs(mean) - abs(mean - est)
        XCTAssertGreaterThan(gain.gain, 0, "pair-level correction helps")
        XCTAssertLessThan(dailyGain, 0, "daily-mean correction hurts")
        XCTAssertEqual(gain.days, 1)
    }

    func testFirstGradedDayUsesZeroOffsetAndWindowAndNaN() {
        let only = BiasCorrection.heldOutGain(
            rows: [],
            pairErrors: [HeldOutError(day: day(0), error: 3), HeldOutError(day: day(0), error: -1)],
            asOfDay: day(1))
        XCTAssertEqual(only.days, 1)
        XCTAssertEqual(only.gain, 0, accuracy: 1e-12)
        XCTAssertEqual(only.rawMAE ?? -1, only.corrMAE ?? -2, accuracy: 1e-12)

        let errors = (0..<20).map { HeldOutError(day: day($0), error: 1) }
        let window = BiasCorrection.heldOutGain(rows: [], pairErrors: errors, asOfDay: day(20))
        XCTAssertEqual(window.days, BiasCorrection.autoOffWindowDays)

        let skipped = BiasCorrection.heldOutGain(
            rows: [],
            pairErrors: [HeldOutError(day: day(0), error: .nan),
                         HeldOutError(day: day(0), error: .infinity),
                         HeldOutError(day: day(0), error: 2)],
            asOfDay: day(1))
        XCTAssertEqual(skipped.days, 1)
        XCTAssertEqual(skipped.rawMAE ?? -1, 2, accuracy: 1e-12)

        let empty = BiasCorrection.heldOutGain(
            rows: [],
            pairErrors: [HeldOutError(day: day(0), error: .nan), HeldOutError(day: day(0), error: .infinity)],
            asOfDay: day(1))
        XCTAssertEqual(empty.days, 0)
        XCTAssertEqual(empty.gain, 0)
        XCTAssertNil(empty.rawMAE)
        XCTAssertNil(empty.corrMAE)
    }

    // MARK: C6 — state machine

    func testFewerThanSevenDaysIsCollectingNotPaused() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = (1...3).map { TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 2, n: 1) }
        await store.seedTraining(rows)
        let offsets = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        let entry = await store.correctionEntry(loc: "x", target: .dailyHigh)
        XCTAssertEqual(offsets[.dailyHigh], 0)
        XCTAssertEqual(entry?.autoOff, false)
        XCTAssertNil(entry?.autoOffReason)
        XCTAssertNil(entry?.autoOffAt)
        XCTAssertEqual(entry?.heldOutDays, 3)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: entry!), .collecting)
        let logs = await store.correctionsSnapshot().log
        XCTAssertTrue(logs.isEmpty)
    }

    func testHysteresisBoundaries() {
        let eps = BiasCorrection.heldOutOnGainC
        XCTAssertFalse(BiasCorrection.heldOutOn(wasOn: false, days: 6, gainC: 1))
        XCTAssertFalse(BiasCorrection.heldOutOn(wasOn: false, days: 7, gainC: eps - 1e-9))
        XCTAssertTrue(BiasCorrection.heldOutOn(wasOn: false, days: 7, gainC: eps))
        XCTAssertTrue(BiasCorrection.heldOutOn(wasOn: true, days: 7, gainC: eps / 2))
        XCTAssertTrue(BiasCorrection.heldOutOn(wasOn: true, days: 7, gainC: 1e-9))
        XCTAssertFalse(BiasCorrection.heldOutOn(wasOn: true, days: 7, gainC: 0))
        XCTAssertFalse(BiasCorrection.heldOutOn(wasOn: true, days: 7, gainC: -0.01))
        XCTAssertFalse(BiasCorrection.heldOutOn(wasOn: true, days: 7, gainC: .nan))
    }

    func testGateStillBindsAndThresholdsUnchanged() async throws {
        XCTAssertEqual(BiasCorrection.hourlyGateDays, 7)
        XCTAssertEqual(BiasCorrection.hourlyGatePairs, 300)
        XCTAssertEqual(BiasCorrection.dailyGateDays, 14)
        XCTAssertEqual(BiasCorrection.dailyGatePairs, 20)
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 20 days × 10 pairs is past the day count and under the pair count, with a large warm bias.
        let rows = (1...20).map {
            TrainingRow(loc: "x", localDay: day(-$0), target: .h0to6, sumE: 20, n: 10, distinct: 10)
        }
        await store.seedTraining(rows)
        // Pair errors turn held-out on. 20×10 is still under the 300-pair gate, so the offset stays 0.
        let errors = rows.map { HeldOutError(day: $0.localDay, error: 2) }
        let offsets = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true,
                                                     gradingErrors: [.h0to6: errors])
        let rawEntry = await store.correctionEntry(loc: "x", target: .h0to6)
        let entry = try XCTUnwrap(rawEntry)
        XCTAssertGreaterThanOrEqual(entry.heldOutDays ?? 0, 7)
        XCTAssertEqual(entry.autoOff, false, "held-out can be on while the pair gate still fails")
        XCTAssertEqual(offsets[.h0to6], 0)
        XCTAssertEqual(entry.appliedC, 0, accuracy: 1e-12)
    }

    func testHourlyRowsWithoutPairErrorsStayCollecting() async throws {
        let clock = TestClock(t0)
        let dir = scratch("no-pairs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        let rows = (1...25).map {
            TrainingRow(loc: "x", localDay: day(-$0), target: .h0to6, sumE: 50, n: 50, distinct: 20)
        }
        let station = MetarStationPick(stationID: "KXXX", coordinate: Coordinate(latitude: 40, longitude: -74),
                                       elevationM: 10, distanceKm: 5, elevationDeltaM: 0, pickedAt: t0)
        await v.seedBenchmark(station: station, key: "x", training: rows, cityElevationM: 10)
        let offsets = await v.corrections("x", timeZoneIdentifier: "UTC", cityElevationM: 10)
        XCTAssertEqual(offsets[.h0to6] ?? -1, 0, "hourly rows, no pair errors → collecting, offset 0")
        let store = BenchmarkStore(directory: dir.appendingPathComponent("benchmark"), client: PR1HTTPClient(),
                                   now: { clock.now })
        let raw = await store.correctionEntry(loc: "x", target: .h0to6)
        let entry = try XCTUnwrap(raw)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: entry), .collecting)
        XCTAssertEqual(entry.autoOff, false)
        XCTAssertEqual(entry.heldOutDays, 0)
        XCTAssertEqual(entry.appliedC, 0, accuracy: 1e-12)
    }

    func testMeasurementOffDoesNotLearnTraining() async throws {
        UserDefaults.standard.set(false, forKey: AccuracyMeasurement.defaultsKey)
        let clock = TestClock(t0)
        let dir = scratch("meas-off")
        defer { try? FileManager.default.removeItem(at: dir) }
        let past = day(-3)
        var pairs: [BenchmarkHourlyPair] = []
        for h in 0..<24 {
            let valid = past.addingTimeInterval(Double(h) * 3600)
            pairs.append(BenchmarkHourlyPair(loc: "fx", issued: valid.addingTimeInterval(-3 * 3600), valid: valid,
                                             kind: .skyline, forecastC: 13, observedC: 10, uncorrectedC: 13))
        }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        await v.seedBenchmark(key: "fx", hourly: pairs)
        let trainingURL = dir.appendingPathComponent("benchmark/training.jsonl")
        _ = await v.corrections("fx", timeZoneIdentifier: "UTC")
        let offText = (try? String(contentsOf: trainingURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(offText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "measurement off must not learn training rows")

        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
        _ = await v.corrections("fx", timeZoneIdentifier: "UTC")
        let store = BenchmarkStore(directory: dir.appendingPathComponent("benchmark"), client: PR1HTTPClient(),
                                   now: { clock.now })
        let onRows = await store.trainingRows(for: "fx", target: .h0to6)
        XCTAssertEqual(onRows.first?.n, 24)
        XCTAssertEqual(onRows.first?.sumE ?? -1, 72, accuracy: 1e-6)
    }

    func testRelaunchDoesNotRewriteCorrectionsForSumOrder() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Newest-first, with values that are not exact in binary, so a reload that sorts by day
        // used to move targetC by ~1e-16 and rewrite corrections.json (N1).
        var rows: [TrainingRow] = []
        for i in 1...40 {
            let e = Double(i) * 0.1 + 1.23e-13
            rows.append(TrainingRow(loc: "x", localDay: day(-i), target: .dailyHigh, sumE: e, n: 1))
        }
        await store.seedTraining(rows)
        _ = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        let url = dir.appendingPathComponent("corrections.json")
        let afterFirst = try Data(contentsOf: url)
        let stamp = modificationDate(url)
        let logs = await store.correctionsSnapshot().log.count
        XCTAssertGreaterThan(logs, 0)

        let reloaded = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { self.t0 })
        _ = await reloaded.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        let logsAfter = await reloaded.correctionsSnapshot().log.count
        XCTAssertEqual(logsAfter, logs)
        XCTAssertEqual(try Data(contentsOf: url), afterFirst)
        XCTAssertEqual(modificationDate(url), stamp)
    }

    func testKillSwitchMeasurementAndSitingForceZero() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedTraining(helpfulDaily(loc: "x"))
        let on = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertLessThan(on[.dailyHigh] ?? 0, 0)

        let siting = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: false)
        XCTAssertEqual(siting[.dailyHigh], 0)

        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        let killed = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertEqual(killed[.dailyHigh], 0)
        UserDefaults.standard.removeObject(forKey: BiasCorrection.Switch.defaultsKey)

        UserDefaults.standard.set(false, forKey: AccuracyMeasurement.defaultsKey)
        let measured = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertEqual(measured[.dailyHigh], 0)
        UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey)
    }

    func testQAOverrideDoesNotChangeHeldOutState() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedTraining((1...20).map {
            TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 0, n: 1)
        } + (21...40).map {
            TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 2, n: 1)
        })
        _ = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        let pausedRaw = await store.correctionEntry(loc: "x", target: .dailyHigh)
        let paused = try XCTUnwrap(pausedRaw)
        XCTAssertTrue(paused.autoOff)
        let logs = await store.correctionsSnapshot().log.count
        let url = dir.appendingPathComponent("corrections.json")
        let before = try Data(contentsOf: url)
        let qa = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true, qaOverrideC: 1)
        XCTAssertEqual(qa[.dailyHigh] ?? -1, 1, accuracy: 1e-12)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, before)
        let stillRaw = await store.correctionEntry(loc: "x", target: .dailyHigh)
        let still = try XCTUnwrap(stillRaw)
        XCTAssertEqual(still.autoOff, true)
        let logsAfter = await store.correctionsSnapshot().log.count
        XCTAssertEqual(logsAfter, logs)
    }

    func testReenableRampsAtMostHalfDegreeAndSameDayIsStable() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.seedTraining(helpfulDaily(loc: "x"))
        let first = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        let applied = try XCTUnwrap(first[.dailyHigh])
        XCTAssertLessThan(applied, 0)
        XCTAssertGreaterThanOrEqual(applied, -BiasCorrection.rampPerDayC - 1e-12)
        let again = await store.refreshCorrections(key: "x", timeZoneIdentifier: "UTC", sitingOK: true)
        XCTAssertEqual(again[.dailyHigh] ?? 99, applied, accuracy: 1e-12)
    }

    func testLegacyApplyingEntryIsWasOn() {
        let legacy = CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 0.4, heldOutDays: nil)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: legacy), .on)
        let fresh = CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 0, heldOutDays: nil)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: fresh), .collecting)
        let paused = CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 0.4, autoOff: true, heldOutDays: nil)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: paused), .paused)

        // Small consistent bias: gain is positive and below ε, so only a wasOn entry stays on.
        let rows = (1...40).map { TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 0.04, n: 1) }
        let errors = rows.map { HeldOutError(day: $0.localDay, error: $0.sumE) }
        let gain = BiasCorrection.heldOutGain(rows: rows, pairErrors: errors, asOfDay: day(0))
        XCTAssertGreaterThanOrEqual(gain.days, 7)
        XCTAssertGreaterThan(gain.gain, 0)
        XCTAssertLessThan(gain.gain, BiasCorrection.heldOutOnGainC)
        let dayKey: @Sendable (Date) -> Date = { $0 }
        let (kept, noLog) = BiasCorrection.evaluateAutoOff(entry: legacy, rows: rows, pairErrors: errors,
                                                          asOf: day(0), dayKey: dayKey)
        XCTAssertFalse(kept.autoOff)
        XCTAssertNil(noLog)
        let (turned, log) = BiasCorrection.evaluateAutoOff(entry: fresh, rows: rows, pairErrors: errors,
                                                          asOf: day(0), dayKey: dayKey)
        XCTAssertTrue(turned.autoOff)
        XCTAssertEqual(log?.state, "off")
        XCTAssertEqual(log?.reason, "worse on recent days")
    }

    func testOneLogPerStateChangeUsesC8Strings() {
        let dayKey: @Sendable (Date) -> Date = { $0 }
        let helpful = (1...20).map { TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 2, n: 1) }
        let helpfulErrors = helpful.map { HeldOutError(day: $0.localDay, error: 2) }
        let zeros = (1...14).map { HeldOutError(day: day(-$0), error: 0) }
        let history = (15...40).map { TrainingRow(loc: "x", localDay: day(-$0), target: .dailyHigh, sumE: 2, n: 1) }

        let fresh = CorrectionEntry(loc: "x", target: .dailyHigh)
        let (paused, offLog) = BiasCorrection.evaluateAutoOff(entry: fresh, rows: history, pairErrors: zeros,
                                                             asOf: day(0), dayKey: dayKey)
        XCTAssertEqual(paused.autoOff, true)
        XCTAssertEqual(offLog?.state, "off")
        XCTAssertEqual(offLog?.reason, "worse on recent days")
        XCTAssertEqual(offLog?.n, paused.heldOutDays)
        let (_, again) = BiasCorrection.evaluateAutoOff(entry: paused, rows: history, pairErrors: zeros,
                                                       asOf: day(0), dayKey: dayKey)
        XCTAssertNil(again)

        let (back, onLog) = BiasCorrection.evaluateAutoOff(entry: paused, rows: helpful, pairErrors: helpfulErrors,
                                                          asOf: day(0), dayKey: dayKey)
        XCTAssertEqual(back.autoOff, false)
        XCTAssertEqual(onLog?.state, "on")
        XCTAssertEqual(onLog?.reason, "hysteresis re-enable")
        let (_, still) = BiasCorrection.evaluateAutoOff(entry: back, rows: helpful, pairErrors: helpfulErrors,
                                                       asOf: day(0), dayKey: dayKey)
        XCTAssertNil(still)

        let (collecting, short) = BiasCorrection.evaluateAutoOff(entry: back, rows: [], pairErrors: [],
                                                                asOf: day(0), dayKey: dayKey)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: collecting), .collecting)
        XCTAssertEqual(short?.state, "off")
        XCTAssertEqual(short?.reason, "held-out days < 7")
        XCTAssertNil(collecting.autoOffReason)
        XCTAssertNil(collecting.autoOffAt)
    }

    // MARK: C1 — upsert

    func testUpsertReplacesSurvivesRelaunchAndDoesNotChurn() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = "city"
        let legacy = TrainingRow(loc: key, localDay: day(-3), target: .h0to6, sumE: 9, n: 1, distinct: 1)
        await store.seedTraining([legacy])
        let replacement = TrainingRow(loc: key, localDay: day(-3), target: .h0to6, sumE: 48, n: 24, distinct: 24)
        await store.upsertHourlyTrainingRows([replacement])
        let firstRows = await store.trainingRows(for: key, target: .h0to6)
        var row = try XCTUnwrap(firstRows.first)
        XCTAssertEqual(row.n, 24)
        XCTAssertEqual(row.sumE, 48, accuracy: 1e-9)

        let reloaded = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { self.t0 })
        let reloadedRows = await reloaded.trainingRows(for: key, target: .h0to6)
        row = try XCTUnwrap(reloadedRows.first)
        XCTAssertEqual(row.n, 24)
        XCTAssertEqual(row.sumE, 48, accuracy: 1e-9)

        await reloaded.resetBytesWrittenSeam()
        let url = dir.appendingPathComponent("training.jsonl")
        let before = try Data(contentsOf: url)
        let stamp = modificationDate(url)
        for _ in 0..<20 { await reloaded.upsertHourlyTrainingRows([replacement]) }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(modificationDate(url), stamp)
        let written = await reloaded.bytesWrittenSinceSeamReset()
        XCTAssertEqual(written, 0)
    }

    func testSmallerPairCountDoesNotReplaceAndDailyStaysFirstWins() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hourly = TrainingRow(loc: "c", localDay: day(-2), target: .h6to24, sumE: 50, n: 50, distinct: 20)
        await store.seedTraining([hourly])
        await store.upsertHourlyTrainingRows([
            TrainingRow(loc: "c", localDay: day(-2), target: .h6to24, sumE: 1, n: 10, distinct: 10)
        ])
        let keptRows = await store.trainingRows(for: "c", target: .h6to24)
        let kept = try XCTUnwrap(keptRows.first)
        XCTAssertEqual(kept.n, 50)
        XCTAssertEqual(kept.sumE, 50, accuracy: 1e-9)

        let daily = TrainingRow(loc: "c", localDay: day(-2), target: .dailyHigh, sumE: 1, n: 1)
        await store.recordTrainingRows([daily])
        await store.recordTrainingRows([TrainingRow(loc: "c", localDay: day(-2), target: .dailyHigh, sumE: 9, n: 1)])
        await store.upsertHourlyTrainingRows([
            TrainingRow(loc: "c", localDay: day(-2), target: .dailyHigh, sumE: 9, n: 5)
        ])
        let highRows = await store.trainingRows(for: "c", target: .dailyHigh)
        let high = try XCTUnwrap(highRows.first)
        XCTAssertEqual(high.sumE, 1, accuracy: 1e-9)
        XCTAssertEqual(high.n, 1)
    }

    // MARK: C2 / C3 / C4 — pool

    func testVerifiedPoolReplacesSkylineAndForeignKeyKeepsIt() async throws {
        let clock = TestClock(t0)
        let dir = scratch("pool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        let past = day(-3)
        var verified: [VerifiedRecord] = []
        var skyline: [BenchmarkHourlyPair] = []
        for h in 0..<24 {
            let valid = past.addingTimeInterval(Double(h) * 3600)
            let issued = valid.addingTimeInterval(-3 * 3600)
            verified.append(VerifiedRecord(
                ForecastRecord(loc: "us", issued: issued, valid: valid,
                               f: [VerificationSource.blend.rawValue: SourceValues(t: 11)]),
                ObservedHour(t: 10)))
            skyline.append(BenchmarkHourlyPair(loc: "us", issued: issued, valid: valid, kind: .skyline,
                                               forecastC: 99, observedC: 10, uncorrectedC: 99))
        }
        var foreign: [BenchmarkHourlyPair] = []
        for h in 0..<24 {
            let valid = past.addingTimeInterval(Double(h) * 3600)
            foreign.append(BenchmarkHourlyPair(loc: "fx", issued: valid.addingTimeInterval(-3 * 3600), valid: valid,
                                               kind: .skyline, forecastC: 13, observedC: 10, uncorrectedC: 13))
        }
        await v.seedBenchmark(key: "us", hourly: skyline + foreign,
                              training: [TrainingRow(loc: "us", localDay: past, target: .h0to6, sumE: 9, n: 1, distinct: 1)])
        await v.testingSeedVerified(verified)
        _ = await v.corrections("us", timeZoneIdentifier: "UTC")
        _ = await v.corrections("fx", timeZoneIdentifier: "UTC")
        let store = BenchmarkStore(directory: dir.appendingPathComponent("benchmark"), client: PR1HTTPClient(),
                                   now: { clock.now })
        let usRows = await store.trainingRows(for: "us", target: .h0to6)
        let us = try XCTUnwrap(usRows.first)
        XCTAssertEqual(us.n, 24)
        XCTAssertEqual(us.sumE, 24, accuracy: 1e-6, "verified errors replace the legacy skyline row")
        let fxRows = await store.trainingRows(for: "fx", target: .h0to6)
        let fx = try XCTUnwrap(fxRows.first)
        XCTAssertEqual(fx.n, 24)
        XCTAssertEqual(fx.sumE, 72, accuracy: 1e-6, "no verified pairs → skyline learningForecastC − observedC")
    }

    func testPoolCacheBuildsOnceAndVerifierLoadsBeforeGrading() async throws {
        let clock = TestClock(t0)
        let dir = scratch("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let past = day(-2)
        let rec = VerifiedRecord(
            ForecastRecord(loc: "load-me", issued: past.addingTimeInterval(3600), valid: past.addingTimeInterval(3 * 3600),
                           f: [VerificationSource.blend.rawValue: SourceValues(t: 12)]),
            ObservedHour(t: 10))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        var bytes = try enc.encode(rec)
        bytes.append(0x0A)
        try bytes.write(to: dir.appendingPathComponent("verified.jsonl"))
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        let loadedBefore = await v.isLoaded
        XCTAssertFalse(loadedBefore)
        let built = await v.heldOutPoolBuildCount()
        _ = await v.corrections("load-me", timeZoneIdentifier: "UTC")
        _ = await v.corrections("load-me", timeZoneIdentifier: "UTC")
        let loadedAfter = await v.isLoaded
        XCTAssertTrue(loadedAfter)
        let builds = await v.heldOutPoolBuildCount()
        XCTAssertEqual(builds, built + 1)
        let store = BenchmarkStore(directory: dir.appendingPathComponent("benchmark"), client: PR1HTTPClient(),
                                   now: { clock.now })
        let loaded = await store.trainingRows(for: "load-me", target: .h0to6)
        XCTAssertEqual(loaded.count, 1, "corrections() must load verified.jsonl before grading")
        XCTAssertEqual(loaded.first?.sumE ?? -1, 2, accuracy: 1e-9)

        clock.now = t0.addingTimeInterval(86400)
        _ = await v.corrections("load-me", timeZoneIdentifier: "UTC")
        let buildsNextDay = await v.heldOutPoolBuildCount()
        XCTAssertEqual(buildsNextDay, built + 2)
    }

    func testLargeVerifiedPoolFinishesCorrections() async {
        let clock = TestClock(t0)
        let dir = scratch("big")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        let origin = t0.addingTimeInterval(-95 * 86400)
        var recs: [VerifiedRecord] = []
        recs.reserveCapacity(90 * 700)
        for d in 0..<90 {
            let start = origin.addingTimeInterval(Double(d) * 86400)
            for i in 0..<700 {
                let valid = start.addingTimeInterval(Double(i % 20 + 1) * 3600)
                let issued = valid.addingTimeInterval(-Double(2 + i / 20) * 3600)
                recs.append(VerifiedRecord(
                    ForecastRecord(loc: "busy", issued: issued, valid: valid,
                                   f: [VerificationSource.blend.rawValue: SourceValues(t: 15)]),
                    ObservedHour(t: 14)))
            }
        }
        await v.testingSeedVerified(recs)
        let offsets = await v.corrections("busy", timeZoneIdentifier: "UTC")
        XCTAssertEqual(offsets.count, CorrectionTarget.allCases.count)
    }

    // MARK: C7 / C9 — old file, idempotent re-grade, size

    func testOldCorrectionsDecodeAndPausedEntriesRegradeWithoutAWait() async throws {
        let json = """
        {"entries":[{"appliedOn":1793854800,"autoOff":true,"loc":"us-paused","target":"0-6h","autoOffAt":1793423167.08935,"n":8,"appliedC":0,"autoOffReason":"worse on recent days","targetC":0},{"appliedOn":1793854800,"autoOff":false,"loc":"us-on","target":"6-24h","n":15,"appliedC":0.2756434459659862,"targetC":0.28362852241507186}],"log":[{"loc":"us-paused","state":"off","n":3,"date":1793423167.08935,"target":"0-6h","correctedMAE":0.6729,"uncorrectedMAE":0.6598,"reason":"worse on recent days"}]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let decoded = try dec.decode(CorrectionsFile.self, from: Data(json.utf8))
        XCTAssertNil(decoded.entries[0].heldOutDays)
        XCTAssertEqual(decoded.entries[0].autoOff, true)
        XCTAssertEqual(decoded.entries[0].autoOffReason, "worse on recent days")
        XCTAssertEqual(decoded.entries[1].appliedC, 0.2756434459659862, accuracy: 1e-12)
        XCTAssertEqual(BiasCorrection.heldOutPhase(of: decoded.entries[1]), .on)

        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var entries: [CorrectionEntry] = []
        for i in 0..<33 {
            entries.append(CorrectionEntry(loc: "us-\(i)", target: .dailyHigh, appliedOn: day(-1),
                                           autoOff: true, autoOffReason: "worse on recent days",
                                           autoOffAt: t0, n: 3 + (i % 10)))
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try enc.encode(CorrectionsFile(entries: entries)).write(to: dir.appendingPathComponent("corrections.json"))
        for i in 0..<33 {
            _ = await store.refreshCorrections(key: "us-\(i)", timeZoneIdentifier: "UTC", sitingOK: true)
            let raw = await store.correctionEntry(loc: "us-\(i)", target: .dailyHigh)
            let entry = try XCTUnwrap(raw)
            XCTAssertEqual(entry.autoOff, false, "paused with no held-out days is collecting immediately")
            XCTAssertNil(entry.autoOffReason)
        }
        let logs = await store.correctionsSnapshot().log
        XCTAssertEqual(logs.count, 33)
        XCTAssertTrue(logs.allSatisfy { $0.reason == "held-out days < 7" && $0.state == "off" })

        // Strong bias and autoOffAt == now: the old 7-day wait would stay paused. C6 turns it on.
        await store.seedTraining(helpfulDaily(loc: "flip"))
        let paused = CorrectionEntry(loc: "flip", target: .dailyHigh, autoOff: true,
                                     autoOffReason: "worse on recent days", autoOffAt: t0, n: 12)
        var file = await store.correctionsSnapshot()
        file.upsert(paused)
        let url = dir.appendingPathComponent("corrections.json")
        try enc.encode(file).write(to: url)
        let fresh = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { self.t0 })
        let beforeLogs = await fresh.correctionsSnapshot().log.count
        _ = await fresh.refreshCorrections(key: "flip", timeZoneIdentifier: "UTC", sitingOK: true)
        let flippedRaw = await fresh.correctionEntry(loc: "flip", target: .dailyHigh)
        let flipped = try XCTUnwrap(flippedRaw)
        XCTAssertEqual(flipped.autoOff, false)
        XCTAssertGreaterThanOrEqual(flipped.heldOutDays ?? 0, 7)
        let reenableReason = await fresh.correctionsSnapshot().log.last?.reason
        XCTAssertEqual(reenableReason, "hysteresis re-enable")
        let afterFirst = try Data(contentsOf: url)
        let logCount = await fresh.correctionsSnapshot().log.count
        XCTAssertEqual(logCount, beforeLogs + 1)
        let stamp = modificationDate(url)
        _ = await fresh.refreshCorrections(key: "flip", timeZoneIdentifier: "UTC", sitingOK: true)
        _ = await fresh.refreshCorrections(key: "flip", timeZoneIdentifier: "UTC", sitingOK: true)
        let logsAfter = await fresh.correctionsSnapshot().log.count
        XCTAssertEqual(logsAfter, logCount)
        XCTAssertEqual(try Data(contentsOf: url), afterFirst)
        XCTAssertEqual(modificationDate(url), stamp)
    }

    func testWorstCaseCorrectionsFileStaysUnder64KBAndEncodesNoNaN() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        var entries: [CorrectionEntry] = []
        for i in 0..<15 {
            for target in CorrectionTarget.allCases {
                entries.append(CorrectionEntry(
                    loc: "city-\(i)", target: target, appliedC: -0.25, targetC: -0.5, appliedOn: t0,
                    autoOff: true, autoOffReason: "worse on recent days", autoOffAt: t0, n: 40,
                    heldOutDays: 14, heldOutRawMAEC: 1.2345, heldOutCorrMAEC: 1.1111))
            }
        }
        let logs = (0..<50).map { i in
            CorrectionLogEntry(state: "off", reason: "worse on recent days", n: 14,
                               correctedMAE: 1.1111, uncorrectedMAE: 1.2345, date: t0,
                               loc: "city-\(i % 15)", target: .h0to6)
        }
        let data = try enc.encode(CorrectionsFile(entries: entries, log: logs))
        XCTAssertLessThanOrEqual(data.count, BiasCorrection.correctionsMaxBytes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("NaN"))

        let nan = BiasCorrection.heldOutGain(
            rows: [],
            pairErrors: [HeldOutError(day: day(-1), error: .nan)],
            asOfDay: day(0))
        XCTAssertNil(nan.rawMAE)
        let (entry, _) = BiasCorrection.evaluateAutoOff(
            entry: CorrectionEntry(loc: "x", target: .h0to6), rows: [], pairErrors: [],
            asOf: day(0), dayKey: { $0 })
        XCTAssertNil(entry.heldOutRawMAEC)
        XCTAssertNil(entry.heldOutCorrMAEC)
        XCTAssertNoThrow(try enc.encode(CorrectionsFile(entries: [entry])))
    }

    // MARK: C11 — status precedence

    func testStatusPrecedenceFiveCases() {
        let paused = CorrectionEntry(loc: "x", target: .h0to6, appliedC: 0.4, autoOff: true,
                                     autoOffReason: "worse on recent days", heldOutDays: 14)
        XCTAssertEqual(BiasCorrection.statusLine(entry: paused, gated: true, sitingOK: true, switchOn: false,
                                                 nDays: 20, units: { $0 }, target: .h0to6, nPairs: 400),
                       "off: switched off")
        XCTAssertEqual(BiasCorrection.statusLine(entry: paused, gated: true, sitingOK: false, switchOn: true,
                                                 nDays: 20, units: { $0 }, target: .h0to6, nPairs: 400),
                       "off: station")
        XCTAssertEqual(BiasCorrection.statusLine(entry: paused, gated: false, sitingOK: true, switchOn: true,
                                                 nDays: 4, units: { $0 }, target: .h0to6, nPairs: 40),
                       "off (4/7 days · 40/300 pairs)")
        XCTAssertEqual(BiasCorrection.statusLine(entry: paused, gated: true, sitingOK: true, switchOn: true,
                                                 nDays: 20, units: { $0 }, target: .h0to6, nPairs: 400),
                       BiasCorrection.autoOffLine)
        let live = CorrectionEntry(loc: "x", target: .h0to6, appliedC: 0.4, heldOutDays: 14)
        let line = BiasCorrection.statusLine(entry: live, gated: true, sitingOK: true, switchOn: true,
                                             nDays: 20, units: { $0 }, target: .h0to6, nPairs: 400)
        XCTAssertTrue(line.hasPrefix("correction in use:"))
    }

    // MARK: A1 / A9

    func testRawScoresMatchWithCorrectionOnAndOffAndFilesStayUncorrected() async throws {
        let clock = TestClock(t0)
        let dir = scratch("raw")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: PR1HTTPClient(), now: { clock.now })
        let key = "score"
        var recs: [VerifiedRecord] = []
        var hourly: [BenchmarkHourlyPair] = []
        for d in 1...8 {
            let start = day(-d)
            for i in 0..<40 {
                let valid = start.addingTimeInterval(Double(i % 20 + 1) * 3600)
                let issued = valid.addingTimeInterval(-Double(3 + i / 20) * 3600)
                recs.append(VerifiedRecord(
                    ForecastRecord(loc: key, issued: issued, valid: valid,
                                   f: [VerificationSource.blend.rawValue: SourceValues(t: 12),
                                       VerificationSource.nws.rawValue: SourceValues(t: 11)]),
                    ObservedHour(t: 10)))
                if i == 0 {
                    hourly.append(BenchmarkHourlyPair(loc: key, issued: issued, valid: valid, kind: .skyline,
                                                      forecastC: 12, observedC: 10, uncorrectedC: 12))
                }
            }
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        var blob = Data()
        for rec in recs {
            blob.append(try enc.encode(rec))
            blob.append(0x0A)
        }
        try blob.write(to: dir.appendingPathComponent("verified.jsonl"))
        let station = MetarStationPick(stationID: "KXXX", coordinate: Coordinate(latitude: 40, longitude: -74),
                                       elevationM: 10, distanceKm: 5, elevationDeltaM: 0, pickedAt: t0)
        await v.seedBenchmark(station: station, key: key, hourly: hourly, cityElevationM: 10)
        let hourlyURL = dir.appendingPathComponent("benchmark/hourly.jsonl")
        let hourlyBefore = try Data(contentsOf: hourlyURL)
        let verifiedURL = dir.appendingPathComponent("verified.jsonl")
        let verifiedBefore = try Data(contentsOf: verifiedURL)

        let before = await v.report(key)
        let offsets = await v.corrections(key, timeZoneIdentifier: "UTC", cityElevationM: nil)
        XCTAssertTrue(offsets.values.contains { abs($0) > 0.01 }, "fixture must actually apply an offset")
        let onReport = await v.report(key)
        XCTAssertEqual(onReport.overall, before.overall)
        XCTAssertEqual(onReport.byBucket, before.byBucket)
        XCTAssertEqual(onReport.verifiedPairs, before.verifiedPairs)
        XCTAssertEqual(onReport.weights, before.weights)
        let summaryOn = await v.benchmarkSummary(key)

        UserDefaults.standard.set(false, forKey: BiasCorrection.Switch.defaultsKey)
        let offReport = await v.report(key)
        XCTAssertEqual(offReport.overall, before.overall)
        XCTAssertEqual(offReport.byBucket, before.byBucket)
        XCTAssertEqual(offReport.weights, before.weights)
        let summaryOff = await v.benchmarkSummary(key)
        XCTAssertEqual(summaryOn, summaryOff)

        let scored = AccuracyScorer.score(recs, now: t0)
        let scoredAfter = AccuracyScorer.score(recs, now: t0)
        XCTAssertEqual(scored, scoredAfter)

        XCTAssertEqual(try Data(contentsOf: verifiedURL), verifiedBefore)
        XCTAssertEqual(try Data(contentsOf: hourlyURL), hourlyBefore)
        let text = try String(contentsOf: verifiedURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"t\":12"))
        XCTAssertFalse(text.contains("\"t\":11.5"))
    }

    // MARK: C13 — Swift replay of the M1 snapshot

    func testSwiftReplayMatchesProposedEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["SKYLINE_M1_VERIFIED"], !path.isEmpty else {
            throw XCTSkip("SKYLINE_M1_VERIFIED not set")
        }
        let result = try Self.replay(path: path)
        print(result.table)
        XCTAssertEqual(result.fair6Raw, 1.962, accuracy: 0.0005, "G3 fair6 raw")
        XCTAssertEqual(result.fair6Corrected, 1.900, accuracy: 0.005, "fair6 corrected vs evidence")
        XCTAssertLessThanOrEqual(result.fair6Corrected, 1.932, "G1")
        XCTAssertEqual(result.allRaw, 2.279, accuracy: 0.005)
        XCTAssertEqual(result.allCorrected, 2.197, accuracy: 0.005)
        XCTAssertLessThanOrEqual(result.allCorrected, result.allRaw, "G3")
        XCTAssertEqual(result.nyc, 2.044, accuracy: 0.005)
        XCTAssertEqual(result.sf, 1.625, accuracy: 0.005)
        XCTAssertEqual(result.lead6to24, 2.137, accuracy: 0.005)
        XCTAssertLessThanOrEqual(result.worstDelta, 0.05, "G2 worst \(result.worstDelta)")
        XCTAssertEqual(result.daysOn, 187)
        XCTAssertEqual(result.daysOff, 595)
    }

    // MARK: Helpers

    /// UTC midnight. `t0` itself is 08:00 UTC, so tests that need a whole local day anchor here.
    private func day(_ offset: Int) -> Date {
        let midnight = (t0.timeIntervalSince1970 / 86400).rounded(.down) * 86400
        return Date(timeIntervalSince1970: midnight + Double(offset) * 86400)
    }

    private func helpfulDaily(loc: String) -> [TrainingRow] {
        (1...30).map { TrainingRow(loc: loc, localDay: day(-$0), target: .dailyHigh, sumE: 2, n: 1) }
    }

    private func makeStore() throws -> (BenchmarkStore, URL) {
        let dir = scratch("store")
        let store = BenchmarkStore(directory: dir, client: PR1HTTPClient(), now: { self.t0 })
        return (store, dir)
    }

    private func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heldout-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private struct ReplayResult {
        var fair6Raw: Double
        var fair6Corrected: Double
        var allRaw: Double
        var allCorrected: Double
        var nyc: Double
        var sf: Double
        var lead6to24: Double
        var worstDelta: Double
        var daysOn: Int
        var daysOff: Int
        var table: String
    }

    /// Product `heldOutGain` + `heldOutOn`. UTC valid-day. No ramp. Mirrors replay_proposed.py (C13).
    private static func replay(path: String) throws -> ReplayResult {
        struct Series: Hashable { var loc: String; var target: CorrectionTarget }
        struct ValidKey: Hashable { var loc: String; var valid: Date }
        struct Latest { var issued: Date; var lead: Double; var fair: Bool; var error: Double }
        let utc: @Sendable (Date) -> Date = { d in
            Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 86400).rounded(.down) * 86400)
        }
        let fairSources: [VerificationSource] = [.blend, .nws, .ecmwf, .icon, .hrrr, .bestMatch]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var seen = Set<String>()
        var pairs: [Series: [(day: Date, error: Double)]] = [:]
        var latest: [ValidKey: Latest] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let rec = try? dec.decode(VerifiedRecord.self, from: Data(line)) else { continue }
            guard let blend = rec.r.values(.blend)?.t, blend.isFinite, let obs = rec.o.t, obs.isFinite else { continue }
            let dedupe = "\(rec.r.loc)|\(rec.r.issued.timeIntervalSince1970)|\(rec.r.valid.timeIntervalSince1970)"
            guard seen.insert(dedupe).inserted else { continue }
            let lead = rec.r.leadHours
            let fair = fairSources.allSatisfy { rec.r.values($0)?.t != nil }
            let key = ValidKey(loc: rec.r.loc, valid: rec.r.valid)
            if latest[key] == nil || rec.r.issued > latest[key]!.issued {
                latest[key] = Latest(issued: rec.r.issued, lead: lead, fair: fair, error: blend - obs)
            }
            guard lead >= BiasCorrection.minLeadHoursForLearning else { continue }
            let target = CorrectionTarget(bucket: LeadBucket(leadHours: lead))
            pairs[Series(loc: rec.r.loc, target: target), default: []].append((utc(rec.r.valid), blend - obs))
        }

        var offset: [Series: [Date: Double]] = [:]
        var daysOn = 0, daysOff = 0
        for (series, samples) in pairs {
            var sums: [Date: (sum: Double, n: Int)] = [:]
            for sample in samples {
                var slot = sums[sample.day] ?? (0, 0)
                slot.sum += sample.error
                slot.n += 1
                sums[sample.day] = slot
            }
            let rows = sums.map {
                TrainingRow(loc: series.loc, localDay: $0.key, target: series.target, sumE: $0.value.sum, n: $0.value.n)
            }
            let errors = samples.map { HeldOutError(day: $0.day, error: $0.error) }
            let days = sums.keys.sorted()
            var on = false
            var byDay: [Date: Double] = [:]
            for t in days {
                let gain = BiasCorrection.heldOutGain(rows: rows, pairErrors: errors, asOfDay: t, dayKey: utc)
                on = BiasCorrection.heldOutOn(wasOn: on, days: gain.days, gainC: gain.gain)
                let prior = rows.filter { $0.localDay < t }
                let nDays = Set(prior.map { Int($0.localDay.timeIntervalSince1970) }).count
                let nPairs = prior.reduce(0) { $0 + max(0, $1.n) }
                let est = BiasCorrection.estimate(rows: prior, asOf: t).targetC
                let gated = nDays >= BiasCorrection.hourlyGateDays && nPairs >= BiasCorrection.hourlyGatePairs
                byDay[t] = (on && gated) ? est : 0
                if on && gated { daysOn += 1 } else { daysOff += 1 }
            }
            offset[series] = byDay
        }

        struct Acc { var n = 0; var raw = 0.0; var corr = 0.0 }
        func accumulate(_ into: inout [String: Acc], _ keys: [String], _ error: Double, _ off: Double) {
            for key in keys {
                var a = into[key] ?? Acc()
                a.n += 1
                a.raw += abs(error) * 1.8
                a.corr += abs(error - off) * 1.8
                into[key] = a
            }
        }
        var all: [String: Acc] = [:]
        for (series, samples) in pairs {
            for sample in samples {
                let off = offset[series]?[sample.day] ?? 0
                accumulate(&all, ["ALL", series.target.rawValue, "city:" + series.loc], sample.error, off)
            }
        }
        var fair: [String: Acc] = [:]
        for (key, item) in latest where item.fair {
            let target = CorrectionTarget(bucket: LeadBucket(leadHours: max(item.lead, 0)))
            let day = utc(key.valid)
            let off = offset[Series(loc: key.loc, target: target)]?[day] ?? 0
            accumulate(&fair, ["ALL", target.rawValue, "city:" + key.loc], item.error, off)
        }
        func mae(_ acc: [String: Acc], _ key: String, _ corrected: Bool) -> Double {
            guard let a = acc[key], a.n > 0 else { return -1 }
            return (corrected ? a.corr : a.raw) / Double(a.n)
        }
        var worst = -Double.greatestFiniteMagnitude
        var lines: [String] = []
        for (name, acc) in [("all", all), ("fair6", fair)] {
            for (key, a) in acc.sorted(by: { $0.key < $1.key }) {
                let d = (a.corr - a.raw) / Double(a.n)
                let city = key.hasPrefix("city:")
                if (!city || a.n >= 50), key != "ALL" { worst = max(worst, d) }
                if a.n >= 50 {
                    lines.append(String(format: "%@ %@ n=%d raw=%.3f corr=%.3f d=%+.3f",
                                        name, key, a.n, a.raw / Double(a.n), a.corr / Double(a.n), d))
                }
            }
        }
        return ReplayResult(fair6Raw: mae(fair, "ALL", false), fair6Corrected: mae(fair, "ALL", true),
                            allRaw: mae(all, "ALL", false), allCorrected: mae(all, "ALL", true),
                            nyc: mae(fair, "city:40.7128,-74.0060", true),
                            sf: mae(fair, "city:37.7749,-122.4194", true),
                            lead6to24: mae(fair, CorrectionTarget.h6to24.rawValue, true),
                            worstDelta: worst, daysOn: daysOn, daysOff: daysOff,
                            table: lines.joined(separator: "\n"))
    }
}
