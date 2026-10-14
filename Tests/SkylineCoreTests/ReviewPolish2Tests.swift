import XCTest
@testable import SkylineCore

/// Code review, polish re-review (ba3ea8a): edits made while the background merge runs, and timing on
/// 500 KB hostile input for the new parsing paths.
final class ReviewPolish2Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func city(_ name: String, _ lat: Double, _ lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, country: "United States", coordinate: Coordinate(latitude: lat, longitude: lon), countryCode: "US")
    }
    lazy var nyc = city("New York", 40.71, -74.01)
    lazy var bos = city("Boston", 42.36, -71.06)
    lazy var den = city("Denver", 39.74, -104.99)
    lazy var sea = city("Seattle", 47.61, -122.33)

    /// What SyncCoordinator.finishPush does in ba3ea8a: apply(merged), then pushAgain re-notes against
    /// `last == merged`. An add made while the merge was running is reverted and never synced.
    func testEditDuringInFlightMergeIsLostWithoutRebase() {
        let last = SyncDocument.migrating(locations: [nyc], settings: [:], now: t0)
        let snapshot = SyncDocument.noting(locations: [nyc], settings: [:], previous: last, now: t0 + 10)
        let remote = SyncDocument.noting(locations: [nyc, bos], settings: [:], previous: last, now: t0 + 5)
        let merged = SyncDocument.merge(local: snapshot, remote: remote, now: t0 + 10)
        let storeDuringFlight = [nyc, den]                         // user added Denver meanwhile
        // ba3ea8a: apply(merged) replaces the store with merged.locations, then pushAgain notes:
        let afterApply = merged.locations
        XCTAssertFalse(afterApply.contains(den), "bug: Denver is reverted by apply(merged)")
        let again = SyncDocument.noting(locations: afterApply, settings: [:], previous: merged, now: t0 + 12)
        XCTAssertTrue(again.sameContent(as: merged), "bug: nothing left to push, so Denver is lost on every Mac")
        // Fix: rebase local edits onto the result before applying.
        let fixed = SyncDocument.rebasing(locations: storeDuringFlight, settings: [:], snapshot: snapshot, onto: merged, now: t0 + 12)
        XCTAssertEqual(Set(fixed.locations.map(\.name)), ["New York", "Boston", "Denver"])
        XCTAssertFalse(fixed.sameContent(as: merged), "a further push is needed and happens")
    }

    func testRemovalAndSettingDuringFlightSurvive() {
        let last = SyncDocument.migrating(locations: [nyc, sea], settings: ["clockStyle": "s:h12"], now: t0)
        let snapshot = SyncDocument.noting(locations: [nyc, sea], settings: ["clockStyle": "s:h12"], previous: last, now: t0 + 10)
        let merged = SyncDocument.merge(local: snapshot, remote: last, now: t0 + 10)
        let fixed = SyncDocument.rebasing(locations: [nyc], settings: ["clockStyle": "s:h24"], snapshot: snapshot, onto: merged, now: t0 + 11)
        XCTAssertEqual(fixed.locations.map(\.name), ["New York"])
        XCTAssertEqual(fixed.settings["clockStyle"], "s:h24")
        XCTAssertNotNil(fixed.removed[sea.id])
    }

    func testNoEditDuringFlightReturnsMergedUnchanged() {
        let last = SyncDocument.migrating(locations: [nyc], settings: [:], now: t0)
        let snapshot = SyncDocument.noting(locations: [nyc], settings: [:], previous: last, now: t0 + 10)
        let remote = SyncDocument.noting(locations: [bos, nyc], settings: [:], previous: last, now: t0 + 5)
        let merged = SyncDocument.merge(local: snapshot, remote: remote, now: t0 + 10)
        XCTAssertEqual(SyncDocument.rebasing(locations: [nyc], settings: [:], snapshot: snapshot, onto: merged, now: t0 + 11), merged)
    }

    /// 500 KB hostile inputs through SyncDocument.read (header + decode) and SearchSubmit: must be fast.
    func testHostileInputTiming() {
        let shapes: [String] = [
            String(repeating: "[", count: 500_000),
            "{\"format\":" + String(repeating: "9", count: 499_980) + "}",
            "{\"format\":1,\"locations\":[" + String(repeating: "{\"a\":\"\\u0000\"},", count: 30_000) + "]}",
            String(repeating: " ", count: 499_999) + "x",
        ]
        for s in shapes {
            let start = Date()
            _ = SyncDocument.read(Data(s.utf8))
            _ = SearchSubmit.pick(results: ["x"], resultsQuery: "x", currentText: s)
            let dt = Date().timeIntervalSince(start)
            print("[timing] \(s.prefix(12))… \(String(format: "%.3f", dt)) s")
            XCTAssertLessThan(dt, 2.0)
        }
    }
}
