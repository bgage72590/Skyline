import XCTest
@testable import SkylineCore

/// Item 1: saved cities wiped on every new build/install.
final class PersistLocationsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)
    func city(_ name: String, _ lat: Double, _ lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, coordinate: Coordinate(latitude: lat, longitude: lon))
    }
    lazy var ny = city("New York", 40.7128, -74.0060)
    lazy var sf = city("San Francisco", 37.7749, -122.4194)
    lazy var syd = city("Sydney", -33.8678, 151.2073)
    lazy var wpb = city("West Palm Beach", 26.7153, -80.0534)

    func synced(_ cities: [WeatherLocation]) -> SyncDocument {
        SyncDocument.migrating(locations: cities, settings: [:], now: t0)
    }

    /// The bug, reproduced: a process whose defaults hold only the seeded New York (the "Skyline"
    /// domain of an unbundled run) notes every other synced city as removed "now", and the merge
    /// then deletes them from sync.json for every Mac.
    func testOldBehaviourWipesCitiesThroughSync() {
        let last = synced([ny, sf, syd, wpb])
        let wiped = SyncDocument.noting(locations: [ny], settings: [:], previous: last, now: t0.addingTimeInterval(60))
        let merged = SyncDocument.merge(local: wiped, remote: last, now: t0.addingTimeInterval(60))
        XCTAssertEqual(merged.locations.map(\.id), [ny.id])
        XCTAssertEqual(Set(wiped.removed.values).count, 1, "all removals share one timestamp (the wipe signature)")
    }

    func testLaunchReconciliationKeepsSyncedCities() {
        let last = synced([ny, sf, syd, wpb])
        let local = LocationPersistence.launchLocations(local: [ny], lastSynced: last.locations)
        XCTAssertEqual(local.map(\.id), [ny, sf, syd, wpb].map(\.id))
        let noted = SyncDocument.noting(locations: local, settings: [:], previous: last, now: t0.addingTimeInterval(60))
        XCTAssertTrue(noted.removed.isEmpty)
        XCTAssertEqual(SyncDocument.merge(local: noted, remote: last, now: t0.addingTimeInterval(60)).locations.count, 4)
    }

    func testLaunchReconciliationKeepsLocalOrderAndAdditions() {
        let out = LocationPersistence.launchLocations(local: [sf, syd], lastSynced: [ny, sf])
        XCTAssertEqual(out.map(\.id), [sf, syd, ny].map(\.id))
        XCTAssertEqual(LocationPersistence.launchLocations(local: [], lastSynced: []), [])
    }

    func testSyncOnlyInTheRealBundle() {
        XCTAssertTrue(LocationPersistence.syncAllowed(bundleIdentifier: "com.briangage.Skyline", hasOverrideFile: false))
        XCTAssertFalse(LocationPersistence.syncAllowed(bundleIdentifier: nil, hasOverrideFile: false))
        XCTAssertFalse(LocationPersistence.syncAllowed(bundleIdentifier: "com.apple.dt.xctest.tool", hasOverrideFile: false))
        XCTAssertTrue(LocationPersistence.syncAllowed(bundleIdentifier: nil, hasOverrideFile: true))
    }

    func testWipedIDsAreBatchRemovalsOnly() {
        let wipe = t0, single = t0.addingTimeInterval(-3600)
        let removed = [syd.id: wipe, wpb.id: wipe, "18.0417,-63.0667": single]
        XCTAssertEqual(LocationRecovery.wipedIDs(removed: removed, present: []), [syd.id, wpb.id].sorted())
        XCTAssertEqual(LocationRecovery.wipedIDs(removed: removed, present: [syd.id]), [], "one left is not a batch")
    }

    func testCoordinateFromID() {
        XCTAssertEqual(LocationRecovery.coordinate(fromID: "-33.8678,151.2073"), Coordinate(latitude: -33.8678, longitude: 151.2073))
        XCTAssertNil(LocationRecovery.coordinate(fromID: "current-location"))
        XCTAssertNil(LocationRecovery.coordinate(fromID: "here@41.2,-73.2"))
        XCTAssertNil(LocationRecovery.coordinate(fromID: "95,10"))
    }

    func testRecoverPrefersLegacyRecordsAndNeverDuplicates() {
        let removed = [syd.id: t0, wpb.id: t0]
        let out = LocationRecovery.recover(current: [ny], legacy: [wpb, ny], removed: removed)
        XCTAssertEqual(out.map(\.id), [wpb.id, syd.id])
        XCTAssertEqual(out[0].name, "West Palm Beach")
        XCTAssertEqual(out[1].coordinate, syd.coordinate)
        XCTAssertEqual(out[1].id, syd.id, "same id, so the re-add matches the tombstone and wins (newer stamp)")
        XCTAssertEqual(LocationRecovery.recover(current: [ny, syd, wpb], legacy: [], removed: removed), [])
    }

    func testRecoveredCitiesSurviveTheMergeOnEveryMac() {
        let wipe = t0
        var remote = synced([ny]); remote.removed = [syd.id: wipe, wpb.id: wipe]
        let back = LocationRecovery.recover(current: [ny], legacy: [], removed: remote.removed)
        let local = SyncDocument.noting(locations: [ny] + back, settings: [:], previous: remote, now: t0.addingTimeInterval(60))
        let merged = SyncDocument.merge(local: remote, remote: local, now: t0.addingTimeInterval(60))
        XCTAssertEqual(Set(merged.locations.map(\.id)), [ny.id, syd.id, wpb.id])
        XCTAssertTrue(merged.removed.isEmpty)
    }
}
