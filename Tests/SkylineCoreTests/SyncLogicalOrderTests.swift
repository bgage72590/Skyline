import XCTest
@testable import SkylineCore

/// Sint Maarten fix: delete vs re-add is ordered by a per-city logical version, not wall clocks.
final class SyncLogicalOrderTests: XCTestCase {
    let sx = WeatherLocation(id: "18.0425,-63.0548", name: "Sint Maarten",
                             coordinate: Coordinate(latitude: 18.0425, longitude: -63.0548))
    let ny = WeatherLocation(id: "40.7128,-74.0060", name: "New York",
                             coordinate: Coordinate(latitude: 40.7128, longitude: -74.0060))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Both Macs synced with both cities (Sint Maarten at version 1).
    func shared() -> SyncDocument {
        SyncDocument.noting(locations: [ny, sx], settings: [:], previous: SyncDocument(), now: t0, deletions: [:])
    }
    func ids(_ d: SyncDocument) -> [String] { d.locations.map(\.id) }

    func testAddAndDeleteBumpTheVersion() {
        let base = shared()
        XCTAssertEqual(base.version(sx.id), 1)
        let del = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 + 60, deletions: [sx.id: t0 + 60])
        XCTAssertEqual(del.version(sx.id), 2)
        XCTAssertEqual(del.version(ny.id), 1, "untouched cities keep their version")
    }

    /// CR H1: the iMac deletes; the MacBook (clock an hour fast, delete not seen yet) edits the city.
    /// Its later wall-clock stamp must not bring the city back, in either merge order.
    func testDeleteBeatsAFastClockEdit() {
        let base = shared()
        let iMac = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 + 60, deletions: [sx.id: t0 + 60])
        var renamed = sx; renamed.name = "Philipsburg"
        let macBook = SyncDocument.noting(locations: [ny, renamed], settings: [:], previous: base, now: t0 + 3600, deletions: [:])
        XCTAssertGreaterThan(macBook.locationStamps[sx.id]!, iMac.removed[sx.id]!, "wall clock alone would keep it")
        for m in [SyncDocument.merge(local: iMac, remote: macBook, now: t0 + 3700),
                  SyncDocument.merge(local: macBook, remote: iMac, now: t0 + 3700)] {
            XCTAssertEqual(ids(m), [ny.id])
            XCTAssertEqual(m.version(sx.id), 2)
        }
    }

    /// CR H1 the other way: the Mac that deletes has the slow clock; the delete is still the later event.
    func testDeleteFromASlowClockMacStillWins() {
        let base = shared()
        let slow = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 - 7200, deletions: [sx.id: t0 - 7200],
                                       deletionVersions: [sx.id: 1])
        var other = base; other.locationStamps[sx.id] = t0 + 7200   // skewed stamp from the other Mac
        XCTAssertEqual(ids(SyncDocument.merge(local: other, remote: slow, now: t0)), [ny.id])
        XCTAssertEqual(ids(SyncDocument.merge(local: slow, remote: other, now: t0)), [ny.id])
    }

    /// The Sint Maarten bug: the MacBook's synced state says deleted, but its list still has the city.
    /// It must not be noted as a fresh add (even with a fast clock), and the UI copy is purged.
    func testStaleCopyIsPurgedNotReAdded() {
        let base = shared()
        let iMac = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 + 60, deletions: [sx.id: t0 + 60])
        let macBookLast = SyncDocument.merge(local: base, remote: iMac, now: t0 + 120)
        XCTAssertEqual(ids(macBookLast), [ny.id])
        let noted = SyncDocument.noting(locations: [ny, sx], settings: [:], previous: macBookLast, now: t0 + 99_999, deletions: [:])
        XCTAssertEqual(ids(noted), [ny.id], "stale copy dropped, so applying the result removes it from the sidebar")
        XCTAssertNil(noted.locationStamps[sx.id])
        XCTAssertEqual(ids(SyncDocument.merge(local: noted, remote: iMac, now: t0 + 99_999)), [ny.id])
        // Rebasing (edits during a push) applies the same rule.
        let rebased = SyncDocument.rebasing(locations: [ny, sx], settings: [:], snapshot: macBookLast, onto: iMac,
                                            now: t0 + 99_999, deletions: [:])
        XCTAssertEqual(ids(rebased), [ny.id])
    }

    /// CR H2: re-adding from search (even when search just selects the stale copy) logs a re-add, which
    /// wins over the earlier delete on every Mac.
    func testLoggedReAddWinsEverywhere() {
        let base = shared()
        let iMac = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 + 60, deletions: [sx.id: t0 + 60])
        let macBookLast = SyncDocument.merge(local: base, remote: iMac, now: t0 + 120)
        // MacBook clock an hour slow: the re-add has an older wall-clock stamp than the delete.
        let reAdd = SyncDocument.noting(locations: [ny, sx], settings: [:], previous: macBookLast, now: t0 - 3600,
                                        deletions: [:], additions: [sx.id: t0 - 3600])
        XCTAssertEqual(ids(reAdd), [ny.id, sx.id])
        XCTAssertEqual(reAdd.version(sx.id), 3)
        for m in [SyncDocument.merge(local: iMac, remote: reAdd, now: t0 + 200),
                  SyncDocument.merge(local: reAdd, remote: iMac, now: t0 + 200)] {
            XCTAssertEqual(Set(ids(m)), [ny.id, sx.id])
            XCTAssertEqual(m.version(sx.id), 3)
            XCTAssertNil(m.removed[sx.id])
        }
    }

    /// Delete, re-add, delete, re-add across two Macs: each step wins and both Macs agree.
    func testPingPongConverges() {
        var a = shared(), b = a, t = t0
        for step in 0..<6 {
            t += 10
            let deleting = step % 2 == 0
            let actor = step % 4 < 2 ? a : b   // alternate which Mac acts
            let next = deleting
                ? SyncDocument.noting(locations: actor.locations.filter { $0.id != sx.id }, settings: [:], previous: actor,
                                      now: t - Double(step) * 1000, deletions: [sx.id: t - Double(step) * 1000],
                                      deletionVersions: [sx.id: actor.version(sx.id)])
                : SyncDocument.noting(locations: actor.locations + [sx], settings: [:], previous: actor,
                                      now: t + Double(step) * 1000, deletions: [:], additions: [sx.id: t])
            if step % 4 < 2 { a = next } else { b = next }
            let ab = SyncDocument.merge(local: a, remote: b, now: t), ba = SyncDocument.merge(local: b, remote: a, now: t)
            XCTAssertEqual(Set(ids(ab)), Set(ids(ba)), "step \(step)")
            XCTAssertEqual(ids(ab).contains(sx.id), !deleting, "step \(step)")
            XCTAssertEqual(ab.version(sx.id), step + 2)
            a = ab; b = ba
        }
    }

    /// An old build's sync.json has no versions: decode as nil, merge by timestamps, keep our versions.
    func testOldBuildFileUsesTimestampsAndKeepsVersions() throws {
        let base = shared()
        var old = base; old.versions = nil
        let data = try old.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"versions\""))
        let decoded = try XCTUnwrap(SyncDocument.decode(data))
        XCTAssertNil(decoded.versions)
        // Old build deletes later (by wall clock): timestamps decide, the delete wins.
        var oldDel = decoded
        oldDel.locations = [ny]; oldDel.locationStamps[sx.id] = nil; oldDel.removed[sx.id] = t0 + 500
        let m = SyncDocument.merge(local: base, remote: oldDel, now: t0 + 600)
        XCTAssertEqual(ids(m), [ny.id])
        XCTAssertEqual(m.versions?[ny.id], 1, "versions survive a merge with an old-build file")
        // Old build re-adds earlier than our delete (by wall clock): our delete wins (timestamp rule).
        let ourDel = SyncDocument.noting(locations: [ny], settings: [:], previous: base, now: t0 + 900, deletions: [sx.id: t0 + 900])
        var oldKeep = decoded; oldKeep.locationStamps[sx.id] = t0 + 800
        XCTAssertEqual(ids(SyncDocument.merge(local: ourDel, remote: oldKeep, now: t0 + 1000)), [ny.id])
    }

    /// A first-time migration has no versions, so a remote delete never removes what this Mac had.
    func testMigrationKeepsTimestampRule() {
        let mig = SyncDocument.migrating(locations: [ny, sx], settings: [:], now: t0 + 1000)
        XCTAssertNil(mig.versions)
        let remoteDel = SyncDocument.noting(locations: [ny], settings: [:], previous: shared(), now: t0 + 60, deletions: [sx.id: t0 + 60])
        XCTAssertEqual(Set(ids(SyncDocument.merge(local: mig, remote: remoteDel, now: t0 + 1001))), [ny.id, sx.id])
    }

    /// Equal versions (concurrent edits) keep the timestamp rule: the newer copy's content wins.
    func testEqualVersionsFallBackToStamps() {
        let base = shared()
        var r1 = sx; r1.name = "A"; var r2 = sx; r2.name = "B"
        let a = SyncDocument.noting(locations: [ny, r1], settings: [:], previous: base, now: t0 + 10, deletions: [:])
        let b = SyncDocument.noting(locations: [ny, r2], settings: [:], previous: base, now: t0 + 20, deletions: [:])
        XCTAssertEqual(SyncDocument.merge(local: a, remote: b, now: t0 + 30).locations.last?.name, "B")
        XCTAssertEqual(SyncDocument.merge(local: b, remote: a, now: t0 + 30).locations.last?.name, "B")
    }

    /// A delete logged before another Mac re-added the city (higher version) doesn't remove the re-add,
    /// even when the re-add's wall-clock stamp is older than the delete.
    func testPendingDeleteLosesToALaterVersionReAdd() {
        let base = shared()
        var reAdded = base; reAdded.versions?[sx.id] = 3; reAdded.locationStamps[sx.id] = t0 - 9999
        let d = SyncDocument.noting(locations: [ny], settings: [:], previous: reAdded, now: t0 + 60,
                                    deletions: [sx.id: t0 + 60], deletionVersions: [sx.id: 1])
        XCTAssertEqual(ids(d), [ny.id, sx.id])
    }

    /// CR #10 M1: a tombstone an old build inferred (not a user delete) never purges the city here.
    func testInferredTombstoneDoesNotPurge() {
        var last = shared()
        last.locations = [ny]; last.locationStamps[sx.id] = nil; last.removed[sx.id] = t0 + 60   // no deletedByUser
        let noted = SyncDocument.noting(locations: [ny, sx], settings: [:], previous: last, now: t0 + 120, deletions: [:])
        XCTAssertEqual(ids(noted), [ny.id, sx.id], "kept and re-stamped, as before this PR")
        XCTAssertNil(noted.removed[sx.id])
        // The same tombstone marked as a user delete does purge.
        last.deletedByUser[sx.id] = t0 + 60
        XCTAssertEqual(ids(SyncDocument.noting(locations: [ny, sx], settings: [:], previous: last, now: t0 + 120, deletions: [:])), [ny.id])
    }

    /// CR #10 L4: the delete log and its version file round-trip together; a stray version without an entry is ignored.
    func testDeletionLogVersionsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("deletions.json")
        let log = DeletionLog(url: url, now: t0)
        log.record(sx.id, at: t0, seenVersion: 4)
        log.record(ny.id, at: t0)
        let again = DeletionLog(url: url, now: t0)
        XCTAssertEqual(again.seenVersions, [sx.id: 4])
        XCTAssertEqual(Set(again.entries.keys), [sx.id, ny.id])
        again.forget(sx.id)
        let third = DeletionLog(url: url, now: t0)
        XCTAssertTrue(third.seenVersions.isEmpty)
        // Version written but entry missing (crash between writes): ignored.
        try JSONEncoder().encode(["x": 9]).write(to: url.deletingPathExtension().appendingPathExtension("versions.json"))
        XCTAssertTrue(DeletionLog(url: url, now: t0).seenVersions.isEmpty)
    }

    /// A brand-new city (never removed) needs no log entry.
    func testNewCityNeedsNoLog() {
        let d = SyncDocument.noting(locations: [ny], settings: [:], previous: SyncDocument(), now: t0, deletions: [:])
        XCTAssertEqual(ids(d), [ny.id])
    }
}
