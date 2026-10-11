import XCTest
@testable import SkylineCore

final class AstronomyAndTileTests: XCTestCase {
    func testMoonPhaseKnownDates() {
        // New moon of the 2024-04-08 total eclipse, 18:21 UTC.
        let eclipse = MoonPhase(date: Date(timeIntervalSince1970: 1_712_600_460))
        XCTAssertEqual(eclipse.name, "New Moon")
        XCTAssertLessThan(eclipse.illumination, 0.02)
        // Full moon 2024-04-23 23:49 UTC.
        let full = MoonPhase(date: Date(timeIntervalSince1970: 1_713_916_140))
        XCTAssertEqual(full.name, "Full Moon")
        XCTAssertGreaterThan(full.illumination, 0.98)
        XCTAssertLessThan(full.daysUntilFull, 1.0)
        XCTAssertEqual(eclipse.symbolName, "moonphase.new.moon")
        XCTAssertEqual(eclipse.daysUntilFull, 15, accuracy: 1.5)
    }

    func testZoomSelection() {
        // Whole world in a 1024-pt view → z ≈ log2(1024/384) ≈ 1.4 → 1.
        XCTAssertEqual(TileMath.zoom(visibleWidth: TileMath.worldSize, viewWidth: 1024, maxZ: 10), 1)
        // 1/256 of the world in 1024 pt → worldPoints = 262144 → log2(682.7) ≈ 9.4 → 9, clamped to 7.
        XCTAssertEqual(TileMath.zoom(visibleWidth: TileMath.worldSize / 256, viewWidth: 1024, maxZ: 10), 9)
        XCTAssertEqual(TileMath.zoom(visibleWidth: TileMath.worldSize / 256, viewWidth: 1024, maxZ: 7), 7)
    }

    func testTilesCoverVisibleRectCentreFirst() {
        let ts = TileMath.tileSize(4)
        let visible = MapRectValue(x: ts * 3.5, y: ts * 5.5, width: ts * 2, height: ts)
        let keys = TileMath.tiles(covering: visible, z: 4)
        XCTAssertEqual(Set(keys), Set([3, 4, 5].flatMap { x in [5, 6].map { TileKey(z: 4, x: x, y: $0) } }))
        XCTAssertEqual(keys.first?.x, 4)
        XCTAssertEqual(TileMath.tiles(covering: visible, z: 4, margin: 1).count, 5 * 4)
        XCTAssertEqual(TileMath.rect(TileKey(z: 4, x: 3, y: 5)).x, ts * 3)
        // Clamped at the world edge.
        XCTAssertEqual(TileMath.tiles(covering: MapRectValue(x: 0, y: 0, width: ts, height: ts), z: 4, margin: 2).count, 9)
    }

    func testDailySourceReadings() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let nws = try NWSPeriod.decodeList(try Fixture.data("nws_forecast"))
        let tz = TimeZone(identifier: "America/New_York")!
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: tz)
        let names = daily[0].sources.map(\.name)
        XCTAssertEqual(names.first, "NOAA HRRR") // highest weight on day 0
        XCTAssertTrue(names.contains("National Weather Service"))
        XCTAssertEqual(daily[0].sources.count, 6)
        XCTAssertFalse(daily[5].sources.contains { $0.name == "NOAA HRRR" })
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: Date(timeIntervalSince1970: 1_791_725_400))
        XCTAssertEqual(daily[1].hours(from: hourly, timeZone: tz).count, 24)
    }
}
