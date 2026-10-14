import XCTest
@testable import SkylineCore

/// Commit E: single-site NEXRAD (nearest station, URL building, persistence, fallbacks).
final class NexradStationTests: XCTestCase {
    func testStationListIsComplete() {
        XCTAssertGreaterThanOrEqual(NexradStation.all.count, 155)
        XCTAssertEqual(Set(NexradStation.all.map(\.id)).count, NexradStation.all.count, "unique ids")
        XCTAssertNotNil(NexradStation.station(id: "KOKX"))
        XCTAssertEqual(NexradStation.station(id: "okx")?.icao, "KOKX")
        XCTAssertFalse(NexradStation.conus.contains { $0.state == "AK" || $0.state == "HI" || $0.state == "PR" })
    }

    func testNearestStation() {
        let cases: [(Double, Double, String)] = [
            (40.7128, -74.0060, "DIX"),   // Manhattan: Fort Dix is 92 km, Upton 98 km
            (41.0534, -73.5387, "OKX"),   // Stamford
            (41.8781, -87.6298, "LOT"),   // Chicago
            (39.7392, -104.9903, "FTG"),  // Denver
            (47.6062, -122.3321, "ATX"),  // Seattle
            (25.7617, -80.1918, "AMX"),   // Miami
            (32.7767, -96.7970, "FWS"),   // Dallas
        ]
        for (lat, lon, id) in cases {
            XCTAssertEqual(NexradStation.nearest(to: Coordinate(latitude: lat, longitude: lon))?.id, id, "\(lat),\(lon)")
        }
        // Mid-Atlantic Ocean: nothing within range.
        XCTAssertNil(NexradStation.nearest(to: Coordinate(latitude: 35, longitude: -50)))
    }

    func testDistance() {
        let ny = Coordinate(latitude: 40.7128, longitude: -74.0060), la = Coordinate(latitude: 34.0522, longitude: -118.2437)
        XCTAssertEqual(NexradStation.distanceKm(ny, la), 3936, accuracy: 15)
        XCTAssertEqual(NexradStation.distanceKm(ny, ny), 0, accuracy: 0.001)
    }

    func testSiteChoicePersistenceAndResolution() {
        XCTAssertEqual(RadarSiteChoice(stored: nil), .auto)
        XCTAssertEqual(RadarSiteChoice(stored: "composite"), .composite)
        XCTAssertEqual(RadarSiteChoice(stored: "KOKX"), .site("OKX"))
        XCTAssertEqual(RadarSiteChoice(stored: "ZZZZ"), .auto, "unknown ids fall back to nearest")
        for c in [RadarSiteChoice.auto, .composite, .site("DIX")] { XCTAssertEqual(RadarSiteChoice(stored: c.stored), c) }
        let ny = Coordinate(latitude: 41.05, longitude: -73.54)
        XCTAssertEqual(RadarSiteChoice.auto.resolvedStation(for: ny, inCONUS: true)?.id, "OKX")
        XCTAssertNil(RadarSiteChoice.composite.resolvedStation(for: ny, inCONUS: true))
        XCTAssertEqual(RadarSiteChoice.site("DIX").resolvedStation(for: ny, inCONUS: true)?.id, "DIX")
        XCTAssertNil(RadarSiteChoice.site("DIX").resolvedStation(for: ny, inCONUS: false), "outside CONUS: no site")
    }

    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); return f.date(from: s)!
    }

    func testURLBuilding() {
        let t = utc("2026-10-14T16:01:00Z")
        XCTAssertEqual(IEMRidge.tileTemplate(site: "OKX", time: t),
                       "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::OKX-N0B-202610141601/{z}/{x}/{y}.png")
        let url = IEMRidge.scanListURL(site: "OKX", start: utc("2026-10-14T15:00:00Z"), end: t).absoluteString
        XCTAssertTrue(url.hasPrefix("https://mesonet.agron.iastate.edu/json/radar.py?"))
        for part in ["operation=list", "product=N0B", "radar=OKX", "start=2026-10-14T15:00Z", "end=2026-10-14T16:01Z"] {
            XCTAssertTrue(url.contains(part), part)
        }
        let frame = RadarFrame(time: t, urlTemplate: IEMRidge.tileTemplate(site: "OKX", time: t))
        XCTAssertEqual(frame.url(z: 7, x: 37, y: 48)?.absoluteString,
                       "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::OKX-N0B-202610141601/7/37/48.png")
    }

    func testScanDecodingAndFramePicking() throws {
        let json = #"{"scans": [{"ts": "2026-10-14T15:03Z"}, {"ts": "2026-10-14T15:08Z"}, {"ts": "2026-10-14T15:12Z"}, {"ts": "2026-10-14T15:16Z"}, {"ts": "2026-10-14T15:21Z"}, {"ts": "2026-10-14T15:25Z"}, {"ts": "2026-10-14T15:30Z"}, {"ts": "2026-10-14T15:34Z"}, {"ts": "2026-10-14T15:38Z"}, {"ts": "2026-10-14T15:42Z"}, {"ts": "2026-10-14T15:47Z"}, {"ts": "2026-10-14T15:51Z"}, {"ts": "2026-10-14T15:56Z"}, {"ts": "2026-10-14T16:01Z"}]}"#
        let scans = try IEMRidge.decodeScans(Data(json.utf8))
        XCTAssertEqual(scans.count, 14)
        let hour = IEMRidge.frames(site: "OKX", scans: scans, range: .oneHour)
        XCTAssertEqual(hour.last?.time, utc("2026-10-14T16:01:00Z"), "ends on the newest scan")
        XCTAssertTrue(hour.allSatisfy { $0.time >= utc("2026-10-14T15:11:00Z") }, "within 50 min")
        XCTAssertLessThanOrEqual(hour.count, 13)
        XCTAssertEqual(hour.map(\.time), hour.map(\.time).sorted())
        let three = IEMRidge.frames(site: "OKX", scans: scans, range: .threeHours)
        for (a, b) in zip(three, three.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time.timeIntervalSince(a.time), 14 * 60) }
        XCTAssertTrue(IEMRidge.frames(site: "OKX", scans: [], range: .oneHour).isEmpty, "no scans: caller falls back")
        XCTAssertTrue(try IEMRidge.decodeScans(Data(#"{"scans": []}"#.utf8)).isEmpty)
    }
}
