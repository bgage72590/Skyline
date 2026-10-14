import XCTest
@testable import SkylineCore

/// Polish: synced cities and settings (merge never loses a city) and the dropdown's summaries.
final class PolishTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func city(_ name: String, _ lat: Double, _ lon: Double) -> WeatherLocation {
        WeatherLocation(name: name, country: "United States", coordinate: Coordinate(latitude: lat, longitude: lon), countryCode: "US")
    }
    lazy var nyc = city("New York", 40.71, -74.01)
    lazy var bos = city("Boston", 42.36, -71.06)
    lazy var chi = city("Chicago", 41.88, -87.63)
    lazy var den = city("Denver", 39.74, -104.99)

    func testMigrationMergesBothMacsWithoutLosingAny() {
        let a = SyncDocument.migrating(locations: [nyc, bos], settings: ["clockStyle": "s:h24"], now: t0)
        let b = SyncDocument.migrating(locations: [chi, nyc], settings: ["clockStyle": "s:h12", "unit.speed": "s:mph"],
                                       now: t0.addingTimeInterval(60))
        let m = SyncDocument.merge(local: a, remote: b, now: t0)
        XCTAssertEqual(m.locations.map(\.name), ["New York", "Boston", "Chicago"], "local order, then the other Mac's extras")
        XCTAssertEqual(m.settings["unit.speed"], "s:mph", "a setting only one Mac had is kept")
        XCTAssertEqual(m.settings["clockStyle"], "s:h24", "equal (migration) stamps: this Mac's value stays")
        let other = SyncDocument.merge(local: b, remote: a, now: t0)
        XCTAssertEqual(Set(other.locations.map(\.id)), Set(m.locations.map(\.id)), "both Macs end up with the same cities")
    }

    func testRemovalSyncsButALaterReAddWins() {
        var a = SyncDocument.migrating(locations: [nyc, bos], settings: [:], now: t0)
        let shared = a
        // Mac A removes Boston at t0+100.
        a = SyncDocument.noting(locations: [nyc], settings: [:], previous: a, now: t0.addingTimeInterval(100))
        XCTAssertNotNil(a.removed[bos.id])
        let m = SyncDocument.merge(local: shared, remote: a, now: t0.addingTimeInterval(200))
        XCTAssertEqual(m.locations.map(\.name), ["New York"], "Mac B learns about the removal")
        // Mac B adds Boston back later: it returns everywhere.
        let b2 = SyncDocument.noting(locations: [nyc, bos], settings: [:], previous: m, now: t0.addingTimeInterval(300))
        let m2 = SyncDocument.merge(local: a, remote: b2, now: t0.addingTimeInterval(400))
        XCTAssertEqual(m2.locations.map(\.name), ["New York", "Boston"])
        XCTAssertNil(m2.removed[bos.id])
    }

    func testAddedOnOneMacWhileRemovedOnAnotherEarlierIsKept() {
        let base = SyncDocument.migrating(locations: [nyc], settings: [:], now: t0)
        let a = SyncDocument.noting(locations: [nyc, den], settings: [:], previous: base, now: t0.addingTimeInterval(50))
        let b = SyncDocument.noting(locations: [], settings: [:], previous: base, now: t0.addingTimeInterval(40))
        let m = SyncDocument.merge(local: b, remote: a, now: t0.addingTimeInterval(60))
        XCTAssertEqual(m.locations.map(\.name), ["Denver"], "NYC removed after it was added; Denver is new")
        // NYC changed on A after B removed it: kept.
        var renamed = nyc; renamed.name = "NYC"
        let a2 = SyncDocument.noting(locations: [renamed], settings: [:], previous: base, now: t0.addingTimeInterval(70))
        XCTAssertEqual(SyncDocument.merge(local: b, remote: a2, now: t0).locations.map(\.name), ["NYC"])
    }

    func testSettingsAreLastWriterWinsPerKey() {
        let base = SyncDocument.migrating(locations: [], settings: ["clockStyle": "s:system", "refreshMinutes": "i:15"], now: t0)
        let a = SyncDocument.noting(locations: [], settings: ["clockStyle": "s:h24", "refreshMinutes": "i:15"], previous: base,
                                    now: t0.addingTimeInterval(10))
        let b = SyncDocument.noting(locations: [], settings: ["clockStyle": "s:system", "refreshMinutes": "i:30"], previous: base,
                                    now: t0.addingTimeInterval(20))
        let m = SyncDocument.merge(local: a, remote: b)
        XCTAssertEqual(m.settings, ["clockStyle": "s:h24", "refreshMinutes": "i:30"], "each key from whoever changed it")
        // A reset (key removed) syncs as a removal.
        let c = SyncDocument.noting(locations: [], settings: ["refreshMinutes": "i:30"], previous: m, now: t0.addingTimeInterval(30))
        XCTAssertNil(SyncDocument.merge(local: m, remote: c).settings["clockStyle"])
    }

    func testFileRoundTripAndNewerFormatIsIgnored() throws {
        var d = SyncDocument.migrating(locations: [nyc], settings: ["unit.speed": "s:kmh"], now: t0)
        d.writtenBy = "MacBook Pro"
        let back = try XCTUnwrap(SyncDocument.decode(try d.encoded()))
        XCTAssertTrue(back.sameContent(as: d))
        d.format = 99
        XCTAssertNil(SyncDocument.decode(try d.encoded()), "a newer build's file isn't misread")
        XCTAssertNil(SyncDocument.decode(Data("not json".utf8)))
    }

    func testOldTombstonesArePruned() {
        var a = SyncDocument.migrating(locations: [nyc, bos], settings: [:], now: t0)
        a = SyncDocument.noting(locations: [nyc], settings: [:], previous: a, now: t0)
        XCTAssertNotNil(SyncDocument.merge(local: a, remote: a, now: t0.addingTimeInterval(10 * 86400)).removed[bos.id])
        XCTAssertNil(SyncDocument.merge(local: a, remote: a, now: t0.addingTimeInterval(200 * 86400)).removed[bos.id])
    }

    func testSyncValueRoundTrip() {
        XCTAssertEqual(SyncValue.decode(SyncValue.encode("h24")!) as? String, "h24")
        XCTAssertEqual(SyncValue.decode(SyncValue.encode(30)!) as? Int, 30)
        XCTAssertEqual(SyncValue.decode(SyncValue.encode(["a", "b"])!) as? [String], ["a", "b"])
        XCTAssertEqual(SyncValue.decode(SyncValue.encode(Data([1, 2, 3]))!) as? Data, Data([1, 2, 3]))
        XCTAssertNil(SyncValue.encode(nil))
    }

    // MARK: Dropdown summaries

    func testRainTiming() throws {
        let f = Batch6Fixture()
        var r = f.report()
        r.minutely = []
        let label: (Date) -> String = { d in
            var c = Calendar(identifier: .gregorian); c.timeZone = r.timeZone
            return "\(c.component(.hour, from: d))h"
        }
        for i in r.hourly.indices { r.hourly[i].precipitationProbability = 0; r.hourly[i].weatherCode = 3 }
        XCTAssertEqual(MenuSummary.rainTiming(r, now: f.now, hourLabel: label), "No rain expected in the next 12 hours")
        let i = try XCTUnwrap(r.hourly.firstIndex { $0.time > f.now.addingTimeInterval(3 * 3600) })
        r.hourly[i].precipitationProbability = 70
        r.hourly[i].weatherCode = 61
        let s = try XCTUnwrap(MenuSummary.rainTiming(r, now: f.now, hourLabel: label))
        XCTAssertTrue(s.hasSuffix("likely around \(label(r.hourly[i].time)) · 70%"), s)
    }

    func testNextSunEventAndComfort() {
        let f = Batch6Fixture()
        var r = f.report()
        r.daily[0].sunrise = f.now.addingTimeInterval(-3 * 3600)
        r.daily[0].sunset = f.now.addingTimeInterval(8 * 3600)
        let e = MenuSummary.nextSunEvent(r, now: f.now)
        XCTAssertEqual(e?.isSunrise, false)
        XCTAssertEqual(e?.time, f.now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(MenuSummary.comfort(dewPointC: 5), "Dry")
        XCTAssertEqual(MenuSummary.comfort(dewPointC: 22), "Muggy")
        XCTAssertNil(MenuSummary.comfort(dewPointC: nil))
    }
}
