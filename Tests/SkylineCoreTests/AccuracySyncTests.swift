import XCTest
@testable import SkylineCore

/// Build 31: accuracy learning shared between Macs through sync.json.
final class AccuracySyncTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000) // on a whole hour

    func pair(_ loc: String = "nyc", issued: TimeInterval, valid: TimeInterval,
              _ f: [VerificationSource: SourceValues], obs: Double = 15) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: loc, issued: t0.addingTimeInterval(issued), valid: t0.addingTimeInterval(valid),
                                      f: Dictionary(uniqueKeysWithValues: f.map { ($0.key.rawValue, $0.value) })),
                       ObservedHour(t: obs))
    }

    func testSameVerificationFromBothMacsCountsOnce() {
        // Mac A and Mac B issued in the same 3 h slot for the same station hour: one record, each model once.
        let a = pair(issued: 600, valid: 7200, [.blend: SourceValues(t: 14), .ecmwf: SourceValues(t: 13)])
        let b = pair(issued: 1800, valid: 7200, [.blend: SourceValues(t: 16), .icon: SourceValues(t: 12)])
        let m = AccuracySync.merge([a], [b])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].r.f["blend"]?.t, 14, "earliest issuance wins for a model both have")
        XCTAssertEqual(m[0].r.f["ecmwf_ifs025"]?.t, 13)
        XCTAssertEqual(m[0].r.f["icon_seamless"]?.t, 12, "models only the other Mac had are filled in")
    }

    func testExactDuplicateAndRoundTripAreIdempotent() {
        let a = pair(issued: 600.75, valid: 7200, [.blend: SourceValues(t: 14)])
        let once = AccuracySync.merge([a], [a])
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(AccuracySync.merge(once, [a]), once)
        XCTAssertEqual(AccuracySync.merge(once, once), once)
    }

    func testDifferentStationTimeOrSlotAreKept() {
        let base = pair(issued: 0, valid: 7200, [.blend: SourceValues(t: 14)])
        let otherLoc = pair("bos", issued: 0, valid: 7200, [.blend: SourceValues(t: 14)])
        let otherHour = pair(issued: 0, valid: 10800, [.blend: SourceValues(t: 14)])
        let otherSlot = pair(issued: -3 * 3600, valid: 7200, [.blend: SourceValues(t: 14)]) // longer lead
        XCTAssertEqual(AccuracySync.merge([base, otherLoc], [otherHour, otherSlot]).count, 4)
    }

    func testMergeIsCommutativeSoMacsConverge() {
        let a = [pair(issued: 600, valid: 7200, [.blend: SourceValues(t: 14)]),
                 pair(issued: 600, valid: 10800, [.nws: SourceValues(t: 10)])]
        let b = [pair(issued: 600, valid: 7200, [.blend: SourceValues(t: 18)]), // same second, different value
                 pair("bos", issued: 900, valid: 7200, [.gfs: SourceValues(t: 9)])]
        XCTAssertEqual(AccuracySync.merge(a, b), AccuracySync.merge(b, a))
    }

    func testResetAndWindow() {
        let old = pair(issued: 0, valid: 3600, [.blend: SourceValues(t: 1)])
        let new = pair(issued: 40 * 86400, valid: 40 * 86400 + 3600, [.blend: SourceValues(t: 2)])
        XCTAssertEqual(AccuracySync.merge([old], [new], resetAt: t0.addingTimeInterval(86400)).map(\.r.f["blend"]?.t), [2])
        XCTAssertEqual(AccuracySync.merge([old], [new], now: t0.addingTimeInterval(41 * 86400)).count, 1, "30-day window")
    }

    func testSyncDocumentDropsBuild31AccuracyAndOldFilesStillDecode() throws {
        // Build 32 (H1): pairs moved to accuracy.json; a build-31 sync.json still reads, and merging drops them.
        var local = SyncDocument(); local.accuracy = [pair(issued: 0, valid: 3600, [.blend: SourceValues(t: 1)])]
        var remote = SyncDocument(); remote.accuracy = [pair(issued: 600, valid: 3600, [.ecmwf: SourceValues(t: 2)])]
        remote.accuracyResetAt = t0
        let back = try XCTUnwrap(SyncDocument.decode(try remote.encoded()))
        XCTAssertEqual(back.accuracy?.count, 1)
        let m = SyncDocument.merge(local: local, remote: remote, now: t0.addingTimeInterval(86400))
        XCTAssertNil(m.accuracy); XCTAssertNil(m.accuracyResetAt)
        XCTAssertFalse(m.sameContent(as: remote), "so the next write shrinks a build-31 file")
        XCTAssertFalse(String(decoding: try m.encoded(), as: UTF8.self).contains("accuracy"))
        let old = #"{"format":1,"locations":[],"locationStamps":{},"removed":{},"settings":{},"settingStamps":{},"writtenBy":"","writtenAt":"2026-10-14T00:00:00Z"}"#
        XCTAssertNotNil(SyncDocument.decode(Data(old.utf8)))
        XCTAssertEqual(SyncDocument.currentFormat, 1)
    }

    func testVerifierAbsorbsOtherMacAndPublishesPayload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-accsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0.addingTimeInterval(86400))
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let remote = AccuracyFile(pairs: [pair(issued: 0, valid: 3600, [.blend: SourceValues(t: 14)]),
                                          pair(issued: 3 * 3600, valid: 4 * 3600, [.blend: SourceValues(t: 15)])])
        let changed1 = await v.absorb(remote)
        let changed2 = await v.absorb(remote)
        XCTAssertTrue(changed1); XCTAssertFalse(changed2, "absorbing the same pairs again changes nothing")
        let unsynced = await v.hasUnsyncedAccuracy
        XCTAssertFalse(unsynced, "pairs from another Mac are not 'new here'")
        let payload = await v.syncFile()
        XCTAssertEqual(payload.pairs.count, 2)
        let v2 = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        let count = await v2.syncFile().pairs.count
        XCTAssertEqual(count, 2)
        // A reset on another Mac (generation 1) clears them here.
        let changed3 = await v2.absorb(AccuracyFile(reset: AccuracyReset(generation: 1, at: t0.addingTimeInterval(80000))))
        XCTAssertTrue(changed3)
        let after = await v2.syncFile()
        XCTAssertEqual(after.pairs.count, 0)
        XCTAssertEqual(after.reset, AccuracyReset(generation: 1, at: t0.addingTimeInterval(80000)))
    }
}
