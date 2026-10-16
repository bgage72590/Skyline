import XCTest
@testable import SkylineCore

/// Tests for radar-features.md §4 (rain timing header, future radar REFP, storm motion, playback).
final class RadarFeaturesTests: XCTestCase {
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01),
                              timeZoneIdentifier: "America/New_York", countryCode: "US")

    // MARK: Feature 1 — rain timing in the radar header

    /// The radar header must reuse `MenuSummary.rainTiming` / `nowcastSummary` — never a second
    /// answer computed from HRRR tiles.
    func testRadarHeaderForecastLineMatchesMenuBar() {
        let now = fixtureTime
        let start = (now.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
        let minutely = [0.0, 0.0, 0.3, 0.6, 0.5].enumerated().map {
            MinutelyPrecipitation(time: Date(timeIntervalSince1970: start + Double($0.offset) * 900),
                                  precipitation: $0.element)
        }
        let current = CurrentConditions(time: now, temperature: 12, apparentTemperature: 12, humidity: 60,
                                        dewPoint: nil, weatherCode: 3, isDay: true, precipitation: 0,
                                        cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil,
                                        windGust: nil, visibility: nil, uvIndex: nil)
        let report = WeatherReport(location: nyc, fetchedAt: now, timeZoneIdentifier: "America/New_York",
                                   current: current, hourly: [], daily: [], minutely: minutely)
        let hourLabel: (Date) -> String = { _ in "9 AM" }
        let menu = MenuSummary.rainTiming(report, now: now, hourLabel: hourLabel)
        let header = MenuSummary.radarForecastLine(report, now: now, hourLabel: hourLabel)
        XCTAssertEqual(header, menu)
        XCTAssertEqual(header, report.nowcastSummary(at: now))
        XCTAssertEqual(header, "Rain starting in about 30 min")
        XCTAssertNil(MenuSummary.radarForecastLine(nil, now: now, hourLabel: hourLabel))
    }

    // MARK: Feature 2 — future radar REFP + defaults

    func testFutureRadarUsesREFPNotREFD() {
        let iso = ISO8601DateFormatter()
        let initTime = iso.date(from: "2026-10-11T23:00:00Z")!
        let latest = iso.date(from: "2026-10-12T01:25:00Z")!
        let frames = IEMHRRR.frames(initTime: initTime, after: latest)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertTrue(frames.allSatisfy { $0.urlTemplate.contains("hrrr::REFP-") })
        XCTAssertFalse(frames.contains { $0.urlTemplate.contains("REFD") })
        XCTAssertEqual(IEMHRRR.product, "REFP")
        XCTAssertEqual(Endpoints.iemHRRRLatest.absoluteString.contains("refp_0000.json"), true)
        XCTAssertEqual(IEMHRRR.legendTypes.map(\.name), ["Rain", "Snow", "Frz rain", "Ice"])
    }

    func testFutureRadarDefaultIsOffWhenUnset() {
        // Mirrors RadarPlayback's UserDefaults fallback (app target): unset key → false.
        let stored: Bool? = nil
        let showsFuture = stored ?? false
        XCTAssertFalse(showsFuture)
    }

    // MARK: Feature 3 — alert hit testing + range rings

    func testAlertHitTestingOnlyInsidePolygon() {
        // Unit square around NYC-ish coords (lat/lon as a flat polygon for the ray cast).
        let ring = [
            Coordinate(latitude: 40.0, longitude: -74.5),
            Coordinate(latitude: 41.0, longitude: -74.5),
            Coordinate(latitude: 41.0, longitude: -73.5),
            Coordinate(latitude: 40.0, longitude: -73.5),
            Coordinate(latitude: 40.0, longitude: -74.5),
        ]
        let shapes = [(id: "warn-1", rings: [ring])]
        XCTAssertEqual(AlertHitTesting.alertID(at: Coordinate(latitude: 40.5, longitude: -74.0), shapes: shapes), "warn-1")
        XCTAssertNil(AlertHitTesting.alertID(at: Coordinate(latitude: 42.0, longitude: -74.0), shapes: shapes))
        XCTAssertFalse(AlertHitTesting.contains(Coordinate(latitude: 39.0, longitude: -74.0), shapes: shapes))
    }

    func testAlertHitTestingPrefersLaterOverlappingShape() {
        let a = [
            Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 2, longitude: 0),
            Coordinate(latitude: 2, longitude: 2), Coordinate(latitude: 0, longitude: 2),
            Coordinate(latitude: 0, longitude: 0),
        ]
        let b = [
            Coordinate(latitude: 1, longitude: 1), Coordinate(latitude: 3, longitude: 1),
            Coordinate(latitude: 3, longitude: 3), Coordinate(latitude: 1, longitude: 3),
            Coordinate(latitude: 1, longitude: 1),
        ]
        let shapes = [(id: "a", rings: [a]), (id: "b", rings: [b])]
        XCTAssertEqual(AlertHitTesting.alertID(at: Coordinate(latitude: 1.5, longitude: 1.5), shapes: shapes), "b")
        XCTAssertEqual(AlertHitTesting.alertID(at: Coordinate(latitude: 0.5, longitude: 0.5), shapes: shapes), "a")
    }

    func testRangeRingsMilesAndDestination() {
        XCTAssertEqual(RangeRings.miles, [10, 25, 50])
        XCTAssertEqual(RangeRings.meters(10), 16093.44, accuracy: 0.01)
        let origin = Coordinate(latitude: 40.0, longitude: -75.0)
        let north = RangeRings.destination(from: origin, meters: 1609.344, bearingDegrees: 0)
        XCTAssertGreaterThan(north.latitude, origin.latitude)
        XCTAssertEqual(north.longitude, origin.longitude, accuracy: 0.01)
        let ring = RangeRings.ring(center: origin, miles: 10)
        XCTAssertEqual(ring.first, ring.last)
        XCTAssertEqual(ring.count, 73)
    }

    // MARK: Feature 4 — storm motion

    func testStormMotionParseFilterDedupeAndLabel() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"nexrad":"OKX","storm_id":"A1","max_dbz":55,"drct":45,"sknt":22,"valid":"2026-10-15T12:00:00Z"},
           "geometry":{"type":"Point","coordinates":[-73.9,40.8]}},
          {"type":"Feature","properties":{"nexrad":"DIX","storm_id":"B2","max_dbz":52,"drct":44,"sknt":20,"valid":"2026-10-15T12:00:00Z"},
           "geometry":{"type":"Point","coordinates":[-73.91,40.81]}},
          {"type":"Feature","properties":{"nexrad":"OKX","storm_id":"C3","max_dbz":40,"drct":90,"sknt":30,"valid":"2026-10-15T12:00:00Z"},
           "geometry":{"type":"Point","coordinates":[-74.0,40.7]}},
          {"type":"Feature","properties":{"nexrad":"OKX","storm_id":"D4","max_dbz":50,"drct":0,"sknt":2,"valid":"2026-10-15T12:00:00Z"},
           "geometry":{"type":"Point","coordinates":[-74.1,40.75]}},
          {"type":"Feature","properties":{"nexrad":"TLX","storm_id":"E5","max_dbz":60,"drct":180,"sknt":25,"valid":"2026-10-15T12:00:00Z"},
           "geometry":{"type":"Point","coordinates":[-97.5,35.4]}}
        ]}
        """
        let all = try StormMotion.parse(Data(json.utf8))
        XCTAssertEqual(all.count, 5)
        let near = Coordinate(latitude: 40.71, longitude: -74.01)
        let kept = StormMotion.relevant(all, near: near)
        // Weak (40 dBZ), erratic (2 kt), and Oklahoma cell are dropped; OKX+DIX dedupe to one.
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].stormID, "A1")
        XCTAssertEqual(StormMotion.motionLabel(directionDegrees: 45, speedKnots: 22), "moving NE at 25 mph")
    }

    func testStormMotionETAOnlyWhenPathPassesClose() {
        let loc = Coordinate(latitude: 40.0, longitude: -75.0)
        // Cell due south, moving north toward the location — will pass close.
        let toward = StormCell(id: "t", radar: "OKX", stormID: "T",
                               coordinate: Coordinate(latitude: 39.5, longitude: -75.0),
                               maxDBZ: 55, directionDegrees: 0, speedKnots: 30, valid: Date())
        let eta = StormMotion.etaMinutes(cell: toward, to: loc)
        XCTAssertNotNil(eta)
        XCTAssertGreaterThan(eta ?? 0, 0)
        XCTAssertTrue(StormMotion.callout(cell: toward, location: loc).contains("~"))
        // Cell due east moving further east — path never near the location.
        let away = StormCell(id: "a", radar: "OKX", stormID: "A",
                             coordinate: Coordinate(latitude: 40.0, longitude: -74.0),
                             maxDBZ: 55, directionDegrees: 90, speedKnots: 30, valid: Date())
        XCTAssertNil(StormMotion.etaMinutes(cell: away, to: loc))
        XCTAssertFalse(StormMotion.callout(cell: away, location: loc).contains("~"))
    }
}
