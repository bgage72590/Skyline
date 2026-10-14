import XCTest
@testable import SkylineCore

/// Build 32: accuracy.json (H1 compact, push only when new), generation-counted reset (H3).
final class Build32AccuracyFileTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func pair(_ loc: String = "nyc", issued: TimeInterval, valid: TimeInterval, t: Double = 14,
              wet: Bool? = nil) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: loc, issued: t0.addingTimeInterval(issued), valid: t0.addingTimeInterval(valid),
                                      f: ["blend": SourceValues(t: t, pop: 40, p: nil, w: 12.5),
                                          "ecmwf_ifs025": SourceValues(t: t - 1, pop: nil, p: 0.3, w: nil)]),
                       ObservedHour(t: 15.25, w: nil, wet: wet, p: 0.1))
    }

    /// Realistic volume: 3 locations × 30 days × 8 issuances × 21 rows.
    func bigFile() -> AccuracyFile {
        var pairs: [VerifiedRecord] = []
        for loc in ["nyc", "bos", "here@41.2,-73.2"] {
            for issue in 0..<(30 * 8) {
                let issued = TimeInterval(issue) * 3 * 3600
                for row in 1...21 { pairs.append(pair(loc, issued: issued, valid: issued + TimeInterval(row) * 3600, t: 10 + Double(row) / 7)) }
            }
        }
        return AccuracyFile(pairs: AccuracySync.merge(pairs, []))
    }

    func testCompactRoundTripIsLossless() throws {
        let f = AccuracyFile(reset: AccuracyReset(generation: 2, at: t0),
                             pairs: AccuracySync.merge([pair(issued: 0, valid: 3600, wet: true),
                                                        pair(issued: 0, valid: 7200, t: 16.288888888888888, wet: false),
                                                        pair(issued: 0, valid: 10800)], []))
        let data = try f.encoded()
        XCTAssertEqual(AccuracyFile.decode(data), f)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\n"), "not pretty-printed")
        XCTAssertFalse(text.contains("issued"), "short keys")
    }

    func testCompactFileIsMuchSmallerThanBuild31Encoding() throws {
        let f = bigFile()
        XCTAssertGreaterThanOrEqual(f.pairs.count, AccuracySync.maxRecords)
        let compact = try f.encoded().count
        var doc = SyncDocument(); doc.accuracy = f.pairs
        let build31 = try doc.encoded().count
        XCTAssertLessThan(Double(compact), Double(build31) / 4, "compact \(compact) B vs build 31 \(build31) B")
    }

    func testNoWriteWhenOnlyTheWindowMoved() {
        // H1: the file has pairs from 29.99 days ago; an hour later the prune drops some. Nothing new → no write.
        let now = t0.addingTimeInterval(30 * 86400)
        let file = AccuracyFile(pairs: AccuracySync.merge((0..<48).map { pair(issued: 0, valid: TimeInterval($0) * 3600) }, []))
        let localSame = file
        let later = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(AccuracyFile.merge(local: localSame, remote: file, now: later).hasNew)
        XCTAssertFalse(AccuracyFile.merge(local: AccuracyFile(), remote: file, now: later).hasNew, "a Mac with nothing new")
        // A genuinely new pair is new.
        var withNew = file; withNew.pairs.append(pair(issued: 30 * 86400, valid: 30 * 86400 + 3600))
        XCTAssertTrue(AccuracyFile.merge(local: withNew, remote: file, now: later).hasNew)
        // A model the file lacks for an existing pair is new.
        var extra = file; extra.pairs[47].r.f["icon_seamless"] = SourceValues(t: 3)
        XCTAssertTrue(AccuracyFile.merge(local: extra, remote: file, now: later).hasNew)
        // No file yet: worth writing when there's anything.
        XCTAssertTrue(AccuracyFile.merge(local: file, remote: nil, now: now).hasNew)
    }

    func testFutureResetIsClampedAndALaterGenerationReplacesIt() {
        let now = t0.addingTimeInterval(10 * 86400)
        let future = AccuracyReset(generation: 1, at: now.addingTimeInterval(365 * 86400)) // clock a year ahead
        let pairs = [pair(issued: 9 * 86400, valid: 9 * 86400 + 3600), pair(issued: now.timeIntervalSince(t0) + 60, valid: now.timeIntervalSince(t0) + 3600)]
        // Clamped to the reader's now: pairs issued after now keep counting (not blocked for a year).
        let m = AccuracyFile.merge(local: AccuracyFile(pairs: pairs), remote: AccuracyFile(reset: future), now: now)
        XCTAssertEqual(m.file.reset?.at, now)
        XCTAssertEqual(m.file.pairs.count, 1)
        // Small skew within tolerance is kept as stamped.
        let skew = AccuracyReset(generation: 1, at: now.addingTimeInterval(300))
        XCTAssertEqual(skew.clamped(now: now).at, now.addingTimeInterval(300))
        // A later reset with a correct clock wins by generation even though its stamp is earlier.
        let fix = AccuracyReset(generation: 2, at: t0.addingTimeInterval(86400))
        XCTAssertEqual(AccuracyReset.winner(future, fix), fix)
        XCTAssertEqual(AccuracyReset.winner(fix, future), fix)
        let m2 = AccuracyFile.merge(local: AccuracyFile(reset: fix, pairs: pairs), remote: AccuracyFile(reset: future), now: now)
        XCTAssertEqual(m2.file.reset, fix)
        XCTAssertEqual(m2.file.pairs.count, 2)
    }

    func testVerifierResetBumpsGenerationAndTracksUnsynced() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b32-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        await v.absorb(AccuracyFile(reset: AccuracyReset(generation: 4, at: t0.addingTimeInterval(-86400))))
        await v.reset()
        let f = await v.syncFile()
        XCTAssertEqual(f.reset?.generation, 5, "a reset here outranks every reset seen so far")
        let pending = await v.hasUnsyncedReset
        XCTAssertTrue(pending)
        await v.markSynced(pairs: 0, reset: f.reset)
        let after = await v.hasUnsyncedAccuracy
        XCTAssertFalse(after)
        // Persisted across launches.
        let v2 = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let g = await v2.syncFile().reset?.generation
        XCTAssertEqual(g, 5)
    }

    func testBuild31ResetFileStillReads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b32r-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"resetAt":1800000000}"#.utf8).write(to: dir.appendingPathComponent("sync-reset.json"))
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { [t0] in t0.addingTimeInterval(60) })
        let r = await v.syncFile().reset
        XCTAssertEqual(r, AccuracyReset(generation: 1, at: t0))
    }

    func testMergeOfLargeFileIsFastEnoughOffMain() throws {
        let f = bigFile()
        let start = Date()
        _ = AccuracyFile.merge(local: f, remote: f, now: t0.addingTimeInterval(30 * 86400))
        _ = try f.encoded()
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "sanity bound (runs off the main thread in the app)")
    }
}
