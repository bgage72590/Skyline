import XCTest
@testable import SkylineCore

/// Build 35: build-32 review Mediums (one-at-a-time sync, reset clamp bound, same-generation resets).
final class Build35AccuracyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func pair(issued: TimeInterval, valid: TimeInterval) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: "nyc", issued: t0.addingTimeInterval(issued), valid: t0.addingTimeInterval(valid),
                                      f: ["blend": SourceValues(t: 14)]), ObservedHour(t: 15))
    }

    // MARK: M1 overlapping syncs

    func testGateNeverOverlapsAndCoalescesBursts() {
        var g = CoalescingGate()
        XCTAssertTrue(g.begin(force: false))
        XCTAssertFalse(g.begin(force: false), "second caller doesn't start a parallel pass")
        XCTAssertFalse(g.begin(force: true))
        XCTAssertFalse(g.begin(force: false))
        XCTAssertEqual(g.next(), true, "one follow-up pass, force kept")
        XCTAssertTrue(g.running)
        XCTAssertNil(g.next(), "done")
        XCTAssertFalse(g.running)
        XCTAssertTrue(g.begin(force: false), "free again")
        XCTAssertNil(g.next())
    }

    func testGateSerializesConcurrentCallers() async {
        actor Runner {
            var gate = CoalescingGate(); var active = 0; var maxActive = 0; var passes = 0
            func run() async {
                guard gate.begin(force: false) else { return }
                repeat {
                    active += 1; maxActive = max(maxActive, active); passes += 1
                    await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000)
                    active -= 1
                } while gate.next() != nil
            }
        }
        let r = Runner()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await r.run() } }
        }
        let maxActive = await r.maxActive, passes = await r.passes
        XCTAssertEqual(maxActive, 1)
        XCTAssertLessThan(passes, 20, "bursts coalesce")
    }

    // MARK: M2 clamp bound

    func testFutureResetIsBoundedByWhenTheFileWasWrittenNotTheReadersClock() {
        // Mac A (clock a year ahead) reset; the file was really written at t0 (its mtime). Mac B reads it
        // two days later and must keep its pairs issued after t0.
        let now = t0.addingTimeInterval(2 * 86400)
        let remote = AccuracyFile(reset: AccuracyReset(generation: 1, at: t0.addingTimeInterval(365 * 86400)),
                                  writtenAt: t0.addingTimeInterval(365 * 86400)) // writer's clock is wrong too
        let mine = AccuracyFile(pairs: (1...24).map { pair(issued: Double($0) * 3600, valid: Double($0) * 3600 + 3600) })
        let m = AccuracyFile.merge(local: mine, remote: remote, now: now, remoteFileDate: t0)
        XCTAssertEqual(m.file.reset?.at, t0)
        XCTAssertEqual(m.file.pairs.count, 24, "pairs issued after the real reset are kept")
        // Writer's own stamp is used when it is plausible.
        let remote2 = AccuracyFile(reset: AccuracyReset(generation: 1, at: t0.addingTimeInterval(365 * 86400)),
                                   writtenAt: t0.addingTimeInterval(3600))
        XCTAssertEqual(AccuracyFile.merge(local: mine, remote: remote2, now: now).file.reset?.at, t0.addingTimeInterval(3600))
        // No bound at all: falls back to the reader's clock (old behaviour).
        XCTAssertEqual(AccuracyFile.merge(local: mine, remote: AccuracyFile(reset: remote.reset), now: now).file.reset?.at, now)
        // writtenAt round-trips through the file.
        var f = AccuracyFile(pairs: mine.pairs); f.writtenAt = t0
        XCTAssertEqual(AccuracyFile.decode(try! f.encoded())?.writtenAt, t0)
    }

    // MARK: M3 same-generation resets

    func testSameGenerationEarlierResetWinsInAnyOrder() {
        let a = AccuracyReset(generation: 3, at: t0)
        let b = AccuracyReset(generation: 3, at: t0.addingTimeInterval(86400))
        XCTAssertEqual(AccuracyReset.winner(a, b), a)
        XCTAssertEqual(AccuracyReset.winner(b, a), a)
        let now = t0.addingTimeInterval(2 * 86400)
        let m1 = AccuracyFile.merge(local: AccuracyFile(reset: a), remote: AccuracyFile(reset: b), now: now).file.reset
        let m2 = AccuracyFile.merge(local: AccuracyFile(reset: b), remote: AccuracyFile(reset: a), now: now).file.reset
        XCTAssertEqual(m1, a); XCTAssertEqual(m2, a)
        XCTAssertEqual(AccuracyReset.winner(AccuracyReset(generation: 4, at: t0), b)?.generation, 4)
    }
}

/// Build 35: build-34 review N-M1 / QA D1–D2 (order-independent dedupe), QA SF-A / SF-B (build-31 data).
final class Build35DedupeAndLegacyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func pair(_ issuedMin: Double, valid: TimeInterval = 10 * 3600, model: String) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: "nyc", issued: t0.addingTimeInterval(issuedMin * 60), valid: t0.addingTimeInterval(valid),
                                      f: [model: SourceValues(t: issuedMin)]), ObservedHour(t: 15))
    }

    /// Every way three Macs' files can be merged gives the same stored set and the same scored set.
    func testEveryMergeOrderGivesTheSameResult() {
        for minutes in [[0.0, 60, 120], [0, 80, 160], [0, 89, 200], [0, 15, 300]] {
            let a = [pair(minutes[0], model: "blend")], b = [pair(minutes[1], model: "nws")], c = [pair(minutes[2], model: "gfs_seamless")]
            let orders: [[VerifiedRecord]] = [
                AccuracySync.merge(AccuracySync.merge(a, b), c),
                AccuracySync.merge(AccuracySync.merge(b, c), a),
                AccuracySync.merge(AccuracySync.merge(c, a), b),
                AccuracySync.merge(c, AccuracySync.merge(b, a)),
                AccuracySync.merge(a + b + c, []),
                AccuracySync.merge(AccuracySync.merge(a, b), AccuracySync.merge(b, c)),
            ]
            for o in orders {
                XCTAssertEqual(o, orders[0], "stored set, \(minutes)")
                XCTAssertEqual(AccuracySync.collapsedForScoring(o), AccuracySync.collapsedForScoring(orders[0]), "scored set, \(minutes)")
            }
        }
        // D1/D2 expectations: gaps < 90 min chain into one run; a >= 90 min gap starts another.
        func scored(_ m: [Double]) -> Int {
            AccuracySync.collapsedForScoring(AccuracySync.merge(m.enumerated().map { pair($1, model: "m\($0)") }, [])).count
        }
        XCTAssertEqual(scored([0, 60, 120]), 2, "build 42: no chaining past 90 min from a run's first issuance")
        XCTAssertEqual(scored([0, 80, 160]), 2)
        XCTAssertEqual(scored([0, 89, 200]), 2)
        XCTAssertEqual(scored([0, 91]), 2)
        XCTAssertEqual(scored([0, 180, 360]), 3, "one Mac's own 3 h cadence never collapses")
    }

    func testBuild31PassthroughAgesOutAndIsNeverReAddedFromThisMac() {
        let now = t0.addingTimeInterval(40 * 86400)
        var old = SyncDocument()
        old.accuracy = [pair(0, valid: 3600, model: "blend")] // newest pair 40 days old
        XCTAssertNil(SyncDocument.merge(local: SyncDocument(), remote: old, now: now).accuracy, "aged out")
        var fresh = SyncDocument(); fresh.accuracy = [pair(0, valid: 39 * 86400, model: "blend")]
        XCTAssertEqual(SyncDocument.merge(local: SyncDocument(), remote: fresh, now: now).accuracy?.count, 1)
        // The file lacks the fields but this Mac's last copy has them: not re-added.
        XCTAssertNil(SyncDocument.merge(local: fresh, remote: SyncDocument(), now: now).accuracy)
        // A reset-only legacy stamp ages out too.
        var resetOnly = SyncDocument(); resetOnly.accuracyResetAt = t0
        XCTAssertNil(SyncDocument.merge(local: SyncDocument(), remote: resetOnly, now: now).accuracyResetAt)
        // Fingerprint changes only when the data does (absorb only on change).
        XCTAssertEqual(LegacyAccuracyFingerprint(fresh), LegacyAccuracyFingerprint(fresh))
        var more = fresh; more.accuracy?.append(pair(5, valid: 39 * 86400 + 3600, model: "nws"))
        XCTAssertNotEqual(LegacyAccuracyFingerprint(fresh), LegacyAccuracyFingerprint(more))
    }

    /// SF-A: a build-31 reset (absorbed as generation 0) never undoes a build-32+ reset (generation >= 1).
    func testLegacyResetNeverUndoesANewerReset() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b35sfa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0.addingTimeInterval(3 * 86400))
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        await v.reset() // generation 1 at T+3d
        let legacy = AccuracyFile(reset: AccuracyReset(generation: 0, at: t0), pairs: [pair(24 * 60, valid: 25 * 3600, model: "blend")])
        _ = await v.absorb(legacy)
        let f = await v.syncFile()
        XCTAssertEqual(f.reset?.generation, 1)
        XCTAssertEqual(f.reset?.at, t0.addingTimeInterval(3 * 86400))
        XCTAssertEqual(f.pairs.count, 0, "the pre-reset pair doesn't come back")
    }
}
