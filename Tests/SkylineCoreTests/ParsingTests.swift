import XCTest
@testable import SkylineCore

final class ParsingTests: XCTestCase {

    func testOpenMeteoMultiModelUS() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        XCTAssertEqual(om.timezone, "America/New_York")
        XCTAssertEqual(om.hourlyTimes.count, 240)
        XCTAssertEqual(om.dailyTimes.count, 10)
        XCTAssertEqual(Set(om.modelsWithData), Set(ForecastModel.allCases))
        XCTAssertEqual(om.hourlyColumn("temperature_2m", model: .ecmwf)?.first ?? nil, 13.9)
        // HRRR only runs ~48 h: later hours are null.
        let hrrr = try XCTUnwrap(om.hourlyColumn("temperature_2m", model: .hrrr))
        XCTAssertNotNil(hrrr[0])
        XCTAssertNil(hrrr[200])

        let current = try XCTUnwrap(om.currentConditions())
        XCTAssertEqual(current.temperature, 15.6, accuracy: 0.001)
        XCTAssertEqual(current.weatherCode, 51)
        XCTAssertTrue(current.isDay)
        XCTAssertEqual(current.visibility ?? 0, 16700, accuracy: 0.1)
        XCTAssertEqual(current.condition.description, "Light Drizzle")

        let minutely = om.minutelyPrecipitation()
        XCTAssertEqual(minutely.count, 8)
        XCTAssertEqual(minutely[2].precipitation, 0.3, accuracy: 0.001)
    }

    func testOpenMeteoOutsideUSHasNoHRRR() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_paris"))
        XCTAssertEqual(om.timezone, "Europe/Paris")
        XCTAssertFalse(om.modelsWithData.contains(.hrrr))
        XCTAssertTrue(om.modelsWithData.contains(.icon))
        XCTAssertEqual(om.currentConditions()?.temperature ?? 0, 16.9, accuracy: 0.001)
    }

    func testBareKeysForSingleModelResponses() throws {
        let json = #"{"latitude":1,"longitude":2,"timezone":"UTC","utc_offset_seconds":0,"hourly":{"time":[0,3600],"temperature_2m":[1.5,2.5]}}"#
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        XCTAssertEqual(om.hourlyColumn("temperature_2m", model: .bestMatch)?.compactMap { $0 }, [1.5, 2.5])
        XCTAssertNil(om.hourlyColumn("temperature_2m", model: .ecmwf))
        XCTAssertEqual(om.modelsWithData, [.bestMatch])
    }

    func testNWSPoint() throws {
        let p = try NWSPoint.decode(try Fixture.data("nws_points"))
        XCTAssertEqual(p.gridID, "OKX")
        XCTAssertEqual(p.city, "New York")
        XCTAssertEqual(p.state, "NY")
        XCTAssertEqual(p.forecastHourlyURL.absoluteString, "https://api.weather.gov/gridpoints/OKX/33,42/forecast/hourly")
    }

    func testNWSHourlyPeriods() throws {
        let periods = try NWSPeriod.decodeList(try Fixture.data("nws_hourly"))
        XCTAssertEqual(periods.count, 60)
        let first = try XCTUnwrap(periods.first)
        XCTAssertEqual(first.temperatureC ?? .nan, fToC(62), accuracy: 0.001)
        XCTAssertEqual(first.probabilityOfPrecipitation, 54)
        XCTAssertEqual(first.relativeHumidity, 87)
        XCTAssertEqual(first.windSpeedKmh ?? 0, 13 * 1.609344, accuracy: 0.001)
        XCTAssertEqual(first.windDirection, 90) // "E"
        XCTAssertEqual(first.endTime.timeIntervalSince(first.startTime), 3600)
    }

    func testNWSDailyPeriods() throws {
        let periods = try NWSPeriod.decodeList(try Fixture.data("nws_forecast"))
        XCTAssertGreaterThanOrEqual(periods.count, 13)
        XCTAssertEqual(periods[0].name, "Today")
        XCTAssertTrue(periods[0].isDaytime)
        XCTAssertEqual(periods[0].temperatureC ?? .nan, fToC(66), accuracy: 0.001)
        XCTAssertFalse(periods[1].isDaytime)
        XCTAssertTrue(periods[0].detailedForecast.contains("high near 66"))
    }

    func testWindSpeedParsing() {
        XCTAssertEqual(NWSPeriod.parseWindSpeedKmh("13 to 17 mph") ?? 0, 15 * 1.609344, accuracy: 0.001, "range → midpoint")
        XCTAssertEqual(NWSPeriod.parseWindSpeedKmh("5 mph") ?? 0, 5 * 1.609344, accuracy: 0.001)
        XCTAssertEqual(NWSPeriod.parseWindSpeedKmh("10 kt") ?? 0, 18.52, accuracy: 0.001)
        XCTAssertNil(NWSPeriod.parseWindSpeedKmh("calm"))
    }

    func testNWSAlertsSortedBySeverity() throws {
        // 09:30 ET Oct 11, before the fixture Tornado Warning ends at 10:00 ET (expired alerts are dropped,
        // so a fixed time keeps this test stable; see Batch1Tests.testExpiredAlertsDropped).
        let alerts = try NWSAlertParser.decode(try Fixture.data("nws_alerts"), now: Date(timeIntervalSince1970: 1_791_725_400))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[0].event, "Tornado Warning")
        XCTAssertEqual(alerts[0].severity, .extreme)
        XCTAssertEqual(alerts[1].severity, .severe)
        XCTAssertNotNil(alerts[0].expires)
        XCTAssertGreaterThan(alerts[0].expires!, alerts[0].effective!)
    }

    func testAirQuality() throws {
        let aq = try XCTUnwrap(OpenMeteoAirQualityResponse.decode(try Fixture.data("om_aqi")))
        XCTAssertEqual(aq.usAQI, 79)
        XCTAssertEqual(aq.category, "Moderate")
        XCTAssertEqual(aq.pm25 ?? 0, 23.0, accuracy: 0.01)
    }

    func testGeocoding() throws {
        let results = try OpenMeteoGeocodingResponse.decode(try Fixture.data("om_geo"))
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results[0].name, "Portland")
        XCTAssertEqual(results[0].admin1, "Oregon")
        XCTAssertEqual(results[0].timeZoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(results[0].asLocation.subtitle, "Oregon, United States")
        XCTAssertEqual(try OpenMeteoGeocodingResponse.decode(Data("{}".utf8)).count, 0)
    }

    func testRainViewerFrames() throws {
        let frames = try RainViewerParser.decode(try Fixture.data("rainviewer"))
        XCTAssertEqual(frames.count, 13)
        XCTAssertEqual(frames, frames.sorted { $0.time < $1.time })
        XCTAssertEqual(frames.last?.url(z: 6, x: 18, y: 24)?.absoluteString,
                       "https://tilecache.rainviewer.com/v2/radar/8685092e4d3b/256/6/18/24/2/1_1.png")
    }

    func testIEMFrames() throws {
        let latest = try XCTUnwrap(IEMNexrad.latestValidTime(try Fixture.data("iem_n0q")))
        let frames = IEMNexrad.frames(latest: latest)
        XCTAssertEqual(frames.count, 11)
        XCTAssertEqual(frames.last?.time, latest)
        XCTAssertEqual(frames.first?.time, latest.addingTimeInterval(-50 * 60))
        let url = try XCTUnwrap(frames.first?.url(z: 7, x: 37, y: 48)?.absoluteString)
        // Absolute scan-time names (L6): a newer scan shifts the loop by one frame instead of changing
        // every URL, so 10 of 11 frames come from cache after each refresh.
        XCTAssertTrue(url.contains("/ridge::USCOMP-N0Q-") && url.hasSuffix("/7/37/48.png") && !url.contains("?v="), url)
        let next = IEMNexrad.frames(latest: latest.addingTimeInterval(300))
        XCTAssertEqual(Set(frames.map(\.urlTemplate)).intersection(next.map(\.urlTemplate)).count, 10)
    }

    func testWeatherConditionMapping() {
        XCTAssertEqual(WeatherCondition(wmoCode: 0).symbolName(isDay: true), "sun.max.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 0).symbolName(isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 95).category, .thunderstorm)
        XCTAssertTrue(WeatherCondition(wmoCode: 61).isPrecipitation)
        XCTAssertFalse(WeatherCondition(wmoCode: 3).isPrecipitation)
    }

    func testCoverageBoxes() {
        XCTAssertTrue(Coordinate(latitude: 40.71, longitude: -74.01).isInCONUS)
        XCTAssertTrue(Coordinate(latitude: 61.2, longitude: -149.9).isLikelyInNWSCoverage) // Anchorage
        XCTAssertFalse(Coordinate(latitude: 61.2, longitude: -149.9).isInCONUS)
        XCTAssertFalse(Coordinate(latitude: 48.85, longitude: 2.35).isLikelyInNWSCoverage)
        XCTAssertEqual(ForecastModel.models(for: Coordinate(latitude: 48.85, longitude: 2.35)).contains(.hrrr), false)
    }
}
