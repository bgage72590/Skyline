import XCTest
@testable import SkylineCore

/// Item 1: saved cities wiped on every new build/install (PR #3 + code review).
final class PersistLocationsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    func city(_ name: String, _ lat: Double, _ lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }
    lazy var ny = city("New York", 40.7128, -74.0060)
    lazy var sf = city("San Francisco", 37.7749, -122.4194)
    lazy var syd = city("Sydney", -33.8678, 151.2073)
    lazy var wpb = city("West Palm Beach", 26.7153, -80.0534)
    let home = URL(fileURLWithPath: "/Users/test")

    func synced(_ cities: [WeatherLocation], at t: Date? = nil) -> SyncDocument {
        SyncDocument.migrating(locations: cities, settings: [:], now: t ?? t0)
    }
    func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-pl-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }
    func suite() -> UserDefaults {
        let name = "skyline.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: The bug

    func testLegacyInferenceWipesCitiesThroughSync() {
        let last = synced([ny, sf, syd, wpb])
        let wiped = SyncDocument.noting(locations: [ny], settings: [:], previous: last, now: t0 + 60)
        XCTAssertEqual(SyncDocument.merge(local: wiped, remote: last, now: t0 + 60).locations.map(\.id), [ny.id])
    }

    // MARK: (2) explicit tombstones, no inference on push

    func testMissingCityIsNotInferredRemoved() {
        let last = synced([ny, sf, syd])
        let doc = SyncDocument.noting(locations: [ny], settings: [:], previous: last, now: t0 + 60, deletions: [:])
        XCTAssertTrue(doc.removed.isEmpty)
        XCTAssertEqual(Set(doc.locations.map(\.id)), [ny.id, sf.id, syd.id])
        XCTAssertEqual(SyncDocument.merge(local: doc, remote: last, now: t0 + 60).locations.count, 3)
    }

    func testRecordedDeleteBecomesAUserTombstone() {
        let last = synced([ny, sf, syd])
        let doc = SyncDocument.noting(locations: [ny, syd], settings: [:], previous: last, now: t0 + 60,
                                      deletions: [sf.id: t0 + 30])
        XCTAssertEqual(doc.locations.map(\.id), [ny.id, syd.id])
        XCTAssertEqual(doc.removed[sf.id].map { $0 >= t0 + 30 }, true)
        XCTAssertNotNil(doc.deletedByUser[sf.id])
        let merged = SyncDocument.merge(local: synced([ny, sf, syd]), remote: doc, now: t0 + 60)
        XCTAssertFalse(merged.locations.contains { $0.id == sf.id }, "delete reaches other Macs")
        XCTAssertNotNil(merged.deletedByUser[sf.id])
    }

    func testBulkDeleteIsExplicitAndStaysDeleted() {
        let last = synced([ny, sf, syd, wpb])
        let ds = [sf.id: t0 + 30, syd.id: t0 + 30, wpb.id: t0 + 30]
        let doc = SyncDocument.noting(locations: [ny], settings: [:], previous: last, now: t0 + 60, deletions: ds)
        XCTAssertEqual(doc.locations.map(\.id), [ny.id])
        // Recovery must not read it as a wipe, on this Mac (log) or another (deletedByUser).
        XCTAssertEqual(LocationRecovery.recover(current: [ny], legacy: [], removed: doc.removed,
                                                userDeleted: doc.deletedByUser, before: t0 + 999), [])
    }

    func testDeleteOlderThanAReAddElsewhereLosesToTheReAdd() {
        let last = synced([ny, sf], at: t0 + 100) // last saw sf (re-)added at t0+100
        let doc = SyncDocument.noting(locations: [ny], settings: [:], previous: last, now: t0 + 200,
                                      deletions: [sf.id: t0 + 50])
        XCTAssertTrue(doc.locations.contains { $0.id == sf.id })
        XCTAssertNil(doc.removed[sf.id])
    }

    func testUserTombstoneSurvivesDocumentRoundTripAndOldFiles() throws {
        var doc = synced([ny]); doc.removed[sf.id] = t0; doc.deletedByUser[sf.id] = t0
        let back = SyncDocument.decode(try doc.encoded())
        XCTAssertEqual(back?.deletedByUser, [sf.id: t0])
        var old = try JSONSerialization.jsonObject(with: try doc.encoded()) as! [String: Any]
        old["deletedByUser"] = nil
        XCTAssertEqual(SyncDocument.decode(try JSONSerialization.data(withJSONObject: old))?.deletedByUser, [:])
    }

    // MARK: (4) delete just before a quit or crash

    func testDeletionLogIsWrittenSynchronously() {
        let url = tmp().appendingPathComponent("deletions.json")
        DeletionLog(url: url).record(sf.id, at: t0)
        XCTAssertEqual(DeletionLog(url: url, now: t0 + 60).entries, [sf.id: t0], "a fresh process (after a crash) sees it")
        let log = DeletionLog(url: url, now: t0); log.forget(sf.id)
        XCTAssertEqual(DeletionLog(url: url).entries, [:])
        XCTAssertEqual(DeletionLog(url: url, now: t0 + 181 * 86400).entries, [:])
    }

    func testDeleteBeforeQuitDoesNotComeBackAtLaunch() {
        // Deleted sf, quit before the push: last still has it, the log has the delete.
        let plan = LaunchSync.plan(local: [ny], last: synced([ny, sf]), deletions: [sf.id: t0 + 30],
                                   legacy: [], defaults: suite(), now: t0 + 60)
        XCTAssertEqual(plan.cities.map(\.id), [ny.id])
        let pushed = SyncDocument.noting(locations: plan.cities, settings: [:], previous: synced([ny, sf]),
                                         now: t0 + 60, deletions: [sf.id: t0 + 30])
        XCTAssertNotNil(pushed.removed[sf.id])
    }

    // MARK: (3) gate, launch reconcile, recovery flag

    func testGateRealBundleOnly() {
        let real = SyncEnvironment.resolve(bundleIdentifier: "com.briangage.Skyline", arguments: ["Skyline"],
                                           home: home, iCloudAvailable: true)
        XCTAssertEqual(real?.stateURL.path, "/Users/test/Library/Application Support/com.briangage.Skyline/sync-state.json")
        XCTAssertEqual(real?.fileURL?.lastPathComponent, "sync.json")
        XCTAssertNil(real?.defaultsSuite)
        XCTAssertNil(SyncEnvironment.resolve(bundleIdentifier: nil, arguments: [], home: home, iCloudAvailable: true),
                     "unbundled .build run: no sync")
        XCTAssertNil(SyncEnvironment.resolve(bundleIdentifier: "com.apple.dt.xctest.tool", arguments: [], home: home, iCloudAvailable: true))
        XCTAssertNil(SyncEnvironment.resolve(bundleIdentifier: "com.briangage.Skyline", arguments: [], home: home,
                                             iCloudAvailable: false)?.fileURL, "iCloud off: no sync file")
    }

    // (1) override never touches the real files or defaults
    func testOverrideIsFullyIsolated() {
        let env = SyncEnvironment.resolve(bundleIdentifier: "com.briangage.Skyline",
                                          arguments: ["Skyline", "-SkylineSyncFile", "/tmp/qa/two.json"], home: home, iCloudAvailable: true)!
        XCTAssertEqual(env.fileURL?.path, "/tmp/qa/two.json")
        XCTAssertEqual(env.stateURL.path, "/tmp/qa/.two-state/sync-state.json")
        XCTAssertEqual(env.deletionsURL.path, "/tmp/qa/.two-state/deletions.json")
        XCTAssertEqual(env.defaultsSuite, "com.briangage.Skyline.synctest")
        for u in [env.fileURL!, env.stateURL, env.deletionsURL] {
            XCTAssertFalse(u.path.hasPrefix(home.path), "\(u.path) must not be under the real home")
        }
        let unbundled = SyncEnvironment.resolve(bundleIdentifier: nil, arguments: ["-SkylineSyncFile", "/tmp/qa/a.json"],
                                                home: home, iCloudAvailable: true)
        XCTAssertEqual(unbundled?.defaultsSuite, SyncEnvironment.overrideSuite)
    }

    func testLaunchReconcileKeepsSyncedCities() {
        let plan = LaunchSync.plan(local: [ny], last: synced([ny, sf, syd]), deletions: [:], legacy: [],
                                   defaults: suite(), now: t0 + 60)
        XCTAssertEqual(plan.cities.map(\.id), [ny, sf, syd].map(\.id))
        XCTAssertEqual(plan.recovered, [])
    }

    func testRecoveryRunsOnceAndSetsTheFlag() {
        let d = suite()
        var last = synced([ny]); last.removed = [syd.id: t0]
        let first = LaunchSync.plan(local: [ny], last: last, deletions: [:], legacy: [], defaults: d, now: t0 + 60)
        XCTAssertEqual(first.recovered.map(\.id), [syd.id])
        XCTAssertTrue(d.bool(forKey: LaunchSync.recoveryFlagKey))
        let second = LaunchSync.plan(local: [ny], last: last, deletions: [:], legacy: [], defaults: d, now: t0 + 120)
        XCTAssertEqual(second.recovered, [])
        XCTAssertEqual(second.cities.map(\.id), [ny.id])
    }

    // MARK: (5) recovery heuristic

    func testOneCityWipeIsRecovered() {
        let back = LocationRecovery.recover(current: [ny], legacy: [], removed: [syd.id: t0], before: t0 + 1)
        XCTAssertEqual(back.map(\.id), [syd.id])
        XCTAssertEqual(back[0].coordinate, syd.coordinate)
    }

    func testRecoveryIgnoresRecordedDeletesAndLaterTombstones() {
        let removed = [syd.id: t0, wpb.id: t0, sf.id: t0 + 500]
        let back = LocationRecovery.recover(current: [ny], legacy: [], removed: removed,
                                            userDeleted: [wpb.id: t0], localDeletions: [:], before: t0 + 100)
        XCTAssertEqual(back.map(\.id), [syd.id], "wpb was a user delete; sf tombstoned after the cutoff")
        XCTAssertEqual(LocationRecovery.recover(current: [ny], legacy: [], removed: [syd.id: t0],
                                                localDeletions: [syd.id: t0], before: t0 + 1), [])
    }

    func testRecoveryPrefersLegacyNamesAndNeverDuplicates() {
        let removed = [syd.id: t0, wpb.id: t0]
        let out = LocationRecovery.recover(current: [ny], legacy: [wpb, ny], removed: removed, before: t0 + 1)
        XCTAssertEqual(out.map(\.id), [syd.id, wpb.id].sorted())
        XCTAssertEqual(out.first { $0.id == wpb.id }?.name, "West Palm Beach")
        XCTAssertEqual(LocationRecovery.recover(current: [ny, syd, wpb], legacy: [], removed: removed), [])
        XCTAssertEqual(LocationRecovery.recover(current: [], legacy: [], removed: ["here@41.2,-73.2": t0]), [])
    }

    func testRecoveredCitiesSurviveTheMergeOnEveryMac() {
        var remote = synced([ny]); remote.removed = [syd.id: t0, wpb.id: t0]
        let back = LocationRecovery.recover(current: [ny], legacy: [], removed: remote.removed, before: t0 + 1)
        let local = SyncDocument.noting(locations: [ny] + back, settings: [:], previous: remote, now: t0 + 60, deletions: [:])
        let merged = SyncDocument.merge(local: remote, remote: local, now: t0 + 60)
        XCTAssertEqual(Set(merged.locations.map(\.id)), [ny.id, syd.id, wpb.id])
        XCTAssertTrue(merged.removed.isEmpty)
    }

    func testCoordinateFromID() {
        XCTAssertEqual(LocationRecovery.coordinate(fromID: "-33.8678,151.2073"), Coordinate(latitude: -33.8678, longitude: 151.2073))
        XCTAssertNil(LocationRecovery.coordinate(fromID: "current-location"))
        XCTAssertNil(LocationRecovery.coordinate(fromID: "95,10"))
    }
}
