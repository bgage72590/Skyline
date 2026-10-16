import XCTest
@testable import SkylineCore

/// Code review, batch 7 (0872cce). SPC wording from the outlook's own valid times, the L28 allowlist,
/// the L4 location guard and US detection by ISO code.
final class ReviewBatch7Tests: XCTestCase {
    let iso = ISO8601DateFormatter()
    func d(_ s: String) -> Date { iso.date(from: s)! }
    let ny = TimeZone(identifier: "America/New_York")!
    let la = TimeZone(identifier: "America/Los_Angeles")!

    /// Live Oct 14, 2026: the Day 2 issued 05:21Z is valid Oct 15 12Z. At 4:30 AM EDT on the 14th that's tomorrow.
    func testDay2IssuedAt06ZSaysTomorrowInTheSmallHours() {
        let o = SevereOutlook(day: 2, risk: .marginal, validFrom: d("2026-10-15T12:00:00Z"), validUntil: d("2026-10-16T12:00:00Z"))
        XCTAssertTrue(o.sentence(now: d("2026-10-14T08:30:00Z"), timeZone: ny).contains("tomorrow"))
    }
    /// The new Day 1 (06Z issuance, valid 12Z) at 4:30 AM EDT is about the day starting, not "tonight".
    func testNewDay1BeforeItStartsSaysToday() {
        let o = SevereOutlook(day: 1, risk: .slight, validFrom: d("2026-10-14T12:00:00Z"), validUntil: d("2026-10-15T12:00:00Z"))
        XCTAssertTrue(o.sentence(now: d("2026-10-14T08:30:00Z"), timeZone: ny).contains("today"))
        XCTAssertTrue(o.sentence(now: d("2026-10-14T15:00:00Z"), timeZone: ny).contains("today"))
        XCTAssertTrue(o.sentence(now: d("2026-10-14T23:00:00Z"), timeZone: ny).contains("tonight"))
    }
    /// 11 PM PDT: the 06Z Day 1 is already out and covers the next day.
    func testPacificLateEveningNewDay1SaysTomorrow() {
        let o = SevereOutlook(day: 1, risk: .slight, validFrom: d("2026-10-14T12:00:00Z"), validUntil: d("2026-10-15T12:00:00Z"))
        XCTAssertTrue(o.sentence(now: d("2026-10-14T06:10:00Z"), timeZone: la).contains("tomorrow"))
    }
    /// Cases batch 7 got right stay right.
    func testOldOutlooksInTheSmallHours() {
        let d1 = SevereOutlook(day: 1, risk: .slight, validFrom: d("2026-10-14T01:00:00Z"), validUntil: d("2026-10-14T12:00:00Z"))
        XCTAssertTrue(d1.sentence(now: d("2026-10-14T05:30:00Z"), timeZone: ny).contains("tonight"), "1:30 AM, last night's Day 1")
        let d2 = SevereOutlook(day: 2, risk: .slight, validFrom: d("2026-10-14T12:00:00Z"), validUntil: d("2026-10-15T12:00:00Z"))
        XCTAssertTrue(d2.sentence(now: d("2026-10-14T05:30:00Z"), timeZone: ny).contains("today"), "1:30 AM, yesterday's Day 2")
        XCTAssertTrue(d2.sentence(now: d("2026-10-13T18:00:00Z"), timeZone: ny).contains("tomorrow"))
    }

    func testAllowlistEdges() {
        XCTAssertFalse(KnownHosts.isAllowed(URL(string: "http://api.weather.gov/x")), "plain HTTP")
        XCTAssertFalse(KnownHosts.isAllowed(URL(string: "https://api.weather.gov.evil.com/x")))
        XCTAssertFalse(KnownHosts.isAllowed(URL(string: "https://evil.com/?h=api.weather.gov")))
        XCTAssertTrue(KnownHosts.isAllowed(URL(string: "https://API.Weather.gov/points/1,2")))
        XCTAssertTrue(KnownHosts.isAllowed(URL(string: "https://tilecache.rainviewer.com/v2/radar/x/256/1/0/0/2/1_1.png")))
        XCTAssertTrue(KnownHosts.isAllowed(URL(string: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/x/1/0/0.png")))
    }

    func testLocationGuard() {
        let a = Coordinate(latitude: 40.7, longitude: -74.0), b = Coordinate(latitude: 41.0, longitude: -74.0)
        XCTAssertTrue(CurrentLocationGuard.isCurrent(a, current: a))
        XCTAssertFalse(CurrentLocationGuard.isCurrent(a, current: b), "a different place is still rejected")
        XCTAssertFalse(CurrentLocationGuard.isCurrent(a, current: nil))
        let jitter = Coordinate(latitude: 40.704, longitude: -74.003)
        XCTAssertNotEqual(jitter, a)
        XCTAssertTrue(CurrentLocationGuard.isCurrent(a, current: jitter), "same ~1 km cell")
    }

    /// MF2 still holds with ISO codes: the 11 towns with "US" are in NWS coverage; Windsor "CA" isn't.
    func testBorderTownsByCode() {
        let towns: [(Double, Double)] = [(44.906, -66.99), (44.86, -66.98), (45.18, -67.28), (47.16, -67.94), (47.36, -68.33),
                                         (45.0, -72.1), (42.97, -82.42), (48.37, -124.62), (26.40, -99.02), (26.10, -98.26), (55.91, -130.02)]
        for (lat, lon) in towns {
            let l = WeatherLocation(name: "t", country: nil, coordinate: Coordinate(latitude: lat, longitude: lon), countryCode: "US")
            XCTAssertTrue(l.isLikelyInNWSCoverage, "\(lat),\(lon)")
        }
        let windsor = WeatherLocation(name: "Windsor", coordinate: Coordinate(latitude: 42.30, longitude: -83.02), countryCode: "CA")
        XCTAssertFalse(windsor.isLikelyInNWSCoverage)
        XCTAssertFalse(windsor.isInCONUS)
    }
}
