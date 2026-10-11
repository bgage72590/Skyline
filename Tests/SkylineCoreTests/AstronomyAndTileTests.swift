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
        // Highest weight on day 0. Best Match and GFS carry the same numbers as HRRR that day, so the three
        // are one row ("one model, one vote"): NOAA, ECMWF, ICON, NWS.
        XCTAssertEqual(names.first, "NOAA HRRR = Open-Meteo Best Match = NOAA GFS")
        XCTAssertTrue(names.contains("National Weather Service"))
        XCTAssertEqual(daily[0].sources.count, 4)
        XCTAssertFalse(daily[5].sources.contains { $0.name.contains("NOAA HRRR") })
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: Date(timeIntervalSince1970: 1_791_725_400))
        XCTAssertEqual(daily[1].hours(from: hourly, timeZone: tz).count, 24)
    }

    func testZoomFittingRespectsTileBudget() {
        // A large window over the US at a detailed zoom: 11 frames must fit a 240-tile budget.
        let visible = MapRectValue(x: 70_000_000, y: 95_000_000, width: 3_000_000, height: 2_000_000)
        let z = TileMath.zoom(fitting: visible, viewWidth: 1300, maxZ: 10, frames: 11, tileBudget: 240)
        XCTAssertLessThanOrEqual(TileMath.tiles(covering: visible, z: z).count * 11, 240)
        XCTAssertLessThanOrEqual(z, TileMath.zoom(visibleWidth: visible.width, viewWidth: 1300, maxZ: 10))
        // A generous budget leaves the natural zoom alone.
        XCTAssertEqual(TileMath.zoom(fitting: visible, viewWidth: 1300, maxZ: 10, frames: 1, tileBudget: 10_000),
                       TileMath.zoom(visibleWidth: visible.width, viewWidth: 1300, maxZ: 10))
    }

    /// Regression for the layout-loop crash: repeated progress reports must not re-deliver unchanged values.
    func testChangeGateSuppressesNoOpWrites() {
        var gate = ChangeGate(step: 0.02)
        XCTAssertEqual(gate.filter(0.5), 0.5)
        XCTAssertNil(gate.filter(0.5))
        XCTAssertNil(gate.filter(0.505))      // same quantised value
        XCTAssertEqual(gate.filter(0.53)!, 0.54, accuracy: 1e-9)
        var delivered = 0
        for _ in 0..<1000 where gate.filter(0.54) != nil { delivered += 1 }
        XCTAssertEqual(delivered, 0)
        gate.reset()
        XCTAssertNotNil(gate.filter(0.54))
    }
}

final class RedesignCoreTests: XCTestCase {
    func testIEMRangeFrames() {
        let latest = Date(timeIntervalSince1970: 1_791_740_100) // a 5-minute boundary
        let two = IEMNexrad.frames(latest: latest, range: .twoHours)
        XCTAssertEqual(two.count, 13)
        XCTAssertEqual(two.last?.time, latest)
        XCTAssertEqual(two.first?.time, latest.addingTimeInterval(-120 * 60))
        XCTAssertTrue(two.last!.urlTemplate.contains("ridge::USCOMP-N0Q-"), two.last!.urlTemplate)
        XCTAssertEqual(IEMNexrad.frames(latest: latest, range: .threeHours).count, 13)
        XCTAssertEqual(IEMNexrad.frames(latest: latest, range: .oneHour).count, 11)
    }

    func testAlertGeometryParsing() throws {
        let json = """
        {"features":[{"geometry":{"type":"Polygon","coordinates":[[[-74,40],[-73,40],[-73,41],[-74,40]]]},
          "properties":{"id":"a","event":"Flood Warning","severity":"Severe","affectedZones":["https://api.weather.gov/zones/forecast/NYZ072"]}},
         {"geometry":null,"properties":{"id":"b","event":"Rip Current Statement","severity":"Moderate",
          "affectedZones":["https://api.weather.gov/zones/forecast/NYZ075"]}}]}
        """
        let alerts = try NWSAlertParser.decode(Data(json.utf8))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[0].polygons.first?.count, 4)
        XCTAssertEqual(alerts[0].polygons.first?.first, Coordinate(latitude: 40, longitude: -74))
        XCTAssertTrue(alerts[1].polygons.isEmpty)
        XCTAssertEqual(alerts[1].affectedZones.first?.lastPathComponent, "NYZ075")
    }

    func testZoneMultiPolygonSimplified() throws {
        let ring = (0..<1000).map { i in "[\(-74 + Double(i) / 1000),\(40 + sin(Double(i)))]" }.joined(separator: ",")
        let json = "{\"geometry\":{\"type\":\"MultiPolygon\",\"coordinates\":[[[\(ring)]],[[[0,0],[1,0],[1,1],[0,0]]]]}}"
        let rings = try NWSZoneParser.decode(Data(json.utf8))
        XCTAssertEqual(rings.count, 2)
        XCTAssertLessThanOrEqual(rings[0].count, 402)
    }

    func testAirQualityHourly() throws {
        let json = """
        {"current":{"us_aqi":42},"hourly":{"time":[1791720000,1791723600],"us_aqi":[40,null]}}
        """
        let aq = try XCTUnwrap(OpenMeteoAirQualityResponse.decode(Data(json.utf8)))
        XCTAssertEqual(aq.hourly.count, 1)
        XCTAssertEqual(aq.hourly.first?.value, 40)
        XCTAssertEqual(AirQuality.category(42), "Good")
    }

    func testBriefingPeakAndRain() {
        let now = Date(timeIntervalSince1970: 1_791_720_000)
        let series = (0..<30).map { (now.addingTimeInterval(Double($0) * 3600), Double($0 == 5 ? 50 : 10)) }
        let peak = Briefing.peak(series, from: now)
        XCTAssertEqual(peak?.value, 50)
        XCTAssertEqual(peak?.time, now.addingTimeInterval(5 * 3600))
    }
}
