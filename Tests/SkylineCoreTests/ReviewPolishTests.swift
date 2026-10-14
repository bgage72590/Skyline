import XCTest
@testable import SkylineCore

/// Code review, polish (4455c33): sync merge convergence, reorder, clock skew, corrupt files.
final class ReviewPolishTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func city(_ name: String, _ lat: Double, _ lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, country: "United States", coordinate: Coordinate(latitude: lat, longitude: lon), countryCode: "US")
    }
    lazy var nyc = city("New York", 40.71, -74.01)
    lazy var bos = city("Boston", 42.36, -71.06)
    lazy var den = city("Denver", 39.74, -104.99)

    /// Two Macs that migrated with different values must agree after one round trip each, or they
    /// rewrite sync.json on every refresh forever (each keeps "its" value on the distantPast tie).
    func testSettingsConvergeAfterMigration() {
        let a = SyncDocument.migrating(locations: [nyc], settings: ["clockStyle": "s:h24"], now: t0)
        let file = a                                          // Mac A wrote first
        let b = SyncDocument.migrating(locations: [nyc], settings: ["clockStyle": "s:h12"], now: t0 + 60)
        let fromB = SyncDocument.merge(local: b, remote: file, now: t0 + 60)   // B writes this
        let fromA = SyncDocument.merge(local: a, remote: fromB, now: t0 + 120) // A pulls it
        XCTAssertEqual(fromA.settings, fromB.settings, "both Macs end on the same value")
        XCTAssertTrue(fromA.sameContent(as: fromB), "no further write is needed")
    }

    /// A reorder on one Mac reaches the other, and the two don't ping-pong the order.
    func testReorderPropagatesAndConverges() {
        let shared = SyncDocument.migrating(locations: [nyc, bos], settings: [:], now: t0)
        let a = SyncDocument.noting(locations: [bos, nyc], settings: [:], previous: shared, now: t0 + 100)
        let b = SyncDocument.noting(locations: [nyc, bos], settings: [:], previous: shared, now: t0 + 200) // no change on B
        let onB = SyncDocument.merge(local: b, remote: a, now: t0 + 200)
        XCTAssertEqual(onB.locations.map(\.name), ["Boston", "New York"], "A's reorder wins")
        let onA = SyncDocument.merge(local: a, remote: onB, now: t0 + 300)
        XCTAssertTrue(onA.sameContent(as: onB), "no ping-pong")
    }

    /// Mac A's clock is 10 minutes fast. B sees A's add, then removes the city. The removal happened
    /// after the add (B had seen it), so it must win even though B's wall clock is earlier.
    func testRemovalAfterSeeingAddWinsDespiteClockSkew() {
        let shared = SyncDocument.migrating(locations: [nyc], settings: [:], now: t0)
        let a = SyncDocument.noting(locations: [nyc, den], settings: [:], previous: shared, now: t0 + 600) // fast clock
        let bSeen = SyncDocument.merge(local: shared, remote: a, now: t0 + 60)
        XCTAssertTrue(bSeen.locations.contains(den))
        let bRemoved = SyncDocument.noting(locations: [nyc], settings: [:], previous: bSeen, now: t0 + 120)
        let result = SyncDocument.merge(local: bRemoved, remote: a, now: t0 + 120)
        XCTAssertFalse(result.locations.contains(den), "Denver must not come back")
    }
}

extension ReviewPolishTests {
    func testCorruptAndNewerFilesAreTold() throws {
        let good = try SyncDocument.migrating(locations: [nyc], settings: [:], now: t0).encoded()
        guard case .document = SyncDocument.read(good) else { return XCTFail("good file") }
        XCTAssertEqual(SyncDocument.read(good.prefix(good.count / 2)), .unreadable, "truncated")
        XCTAssertEqual(SyncDocument.read(Data("{\"format\": 2, \"x\": 1}".utf8)), .newerFormat(2))
        XCTAssertEqual(SyncDocument.read(Data()), .unreadable)
    }
    func testFormat1FileWithoutOrderStampStillDecodes() throws {
        var json = String(data: try SyncDocument.migrating(locations: [nyc], settings: [:], now: t0).encoded(), encoding: .utf8)!
        XCTAssertFalse(json.contains("orderStamp"))
        json = json.replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 1")
        XCTAssertNotNil(SyncDocument.decode(Data(json.utf8)))
    }
    func testThreeMacsConverge() {
        var docs = [SyncDocument.migrating(locations: [nyc], settings: ["clockStyle": "s:h24"], now: t0),
                    SyncDocument.migrating(locations: [bos, nyc], settings: ["clockStyle": "s:h12"], now: t0 + 1),
                    SyncDocument.migrating(locations: [den], settings: ["unit.speed": "s:kmh"], now: t0 + 2)]
        var file = docs[0]
        for round in 0..<3 { for i in docs.indices {
            docs[i] = SyncDocument.merge(local: docs[i], remote: file, now: t0 + Double(10 * round + i)); file = docs[i] } }
        for d in docs { XCTAssertTrue(d.sameContent(as: file)) }
    }
}
