import XCTest
@testable import SkylineCore

final class BlendingTests: XCTestCase {

    func testWeights() {
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 0), 3.0)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 27), 1.75, accuracy: 1e-9)
        XCTAssertEqual(ForecastBlender.weight(.model(.hrrr), leadHours: 40), 0.5)
        XCTAssertGreaterThan(ForecastBlender.weight(.model(.ecmwf), leadHours: 100),
                             ForecastBlender.weight(.model(.gfs), leadHours: 100))
        XCTAssertGreaterThan(ForecastBlender.weight(.nws, leadHours: 10),
                             ForecastBlender.weight(.model(.bestMatch), leadHours: 10))
    }

    func testWeightedMeanIgnoresMissing() {
        XCTAssertEqual(ForecastBlender.weightedMean([(10, 1), (nil, 5), (20, 3)]) ?? 0, 17.5, accuracy: 1e-9)
        XCTAssertNil(ForecastBlender.weightedMean([(nil, 1)]))
        XCTAssertNil(ForecastBlender.weightedMean([(5, 0)]))
    }

    func testSyntheticDailyBlendIncludesNWS() throws {
        // One day, two models, plus an NWS daytime period of 30 °C and a prior-night period of 5 °C.
        let json = #"""
        {"latitude":40,"longitude":-74,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":[86400],
                  "temperature_2m_max_best_match":[20],"temperature_2m_max_ecmwf_ifs025":[10],
                  "temperature_2m_min_best_match":[8],"temperature_2m_min_ecmwf_ifs025":[4],
                  "weather_code_best_match":[0],"precipitation_probability_max_best_match":[10]},
         "hourly":{"time":[86400],"temperature_2m_best_match":[15],"temperature_2m_ecmwf_ifs025":[12]}}
        """#
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let day = Date(timeIntervalSince1970: 86400)
        let nws = [
            NWSPeriod(name: "Tonight", startTime: day.addingTimeInterval(-6 * 3600), endTime: day.addingTimeInterval(6 * 3600),
                      isDaytime: false, temperatureC: 5, probabilityOfPrecipitation: 0, relativeHumidity: nil,
                      windSpeedKmh: nil, windDirection: nil, shortForecast: "Clear", detailedForecast: ""),
            NWSPeriod(name: "Friday", startTime: day.addingTimeInterval(6 * 3600), endTime: day.addingTimeInterval(18 * 3600),
                      isDaytime: true, temperatureC: 30, probabilityOfPrecipitation: 20, relativeHumidity: nil,
                      windSpeedKmh: nil, windDirection: nil, shortForecast: "Sunny", detailedForecast: "Sunny, high near 86."),
        ]
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: TimeZone(identifier: "UTC")!)
        let d = try XCTUnwrap(daily.first)
        XCTAssertEqual(d.high, wmean([(20, 2), (10, 1.5), (30, 2.5)]), accuracy: 1e-9)
        XCTAssertEqual(d.low, wmean([(8, 2), (4, 1.5), (5, 2.5)]), accuracy: 1e-9)
        XCTAssertEqual(d.precipitationProbability ?? 0, wmean([(10, 2), (20, 2.5)]), accuracy: 1e-9)
        XCTAssertEqual(d.summary, "Sunny, high near 86.")
        XCTAssertEqual(d.highSpread, 20)
        XCTAssertEqual(d.weatherCode, 0)
    }

    func testRealDailyBlendNYC() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let nws = try NWSPeriod.decodeList(try Fixture.data("nws_forecast"))
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(daily.count, 10)
        for d in daily { XCTAssertGreaterThanOrEqual(d.high, d.low) }

        // Day 0 high: best_match, HRRR and GFS are all 18.4 (one NOAA value, counted once at the largest
        // weight, HRRR's 3), ECMWF 16.1 (w1.5), ICON 14.9 (w1), NWS 66 °F (w2.5).
        let expected = wmean([(18.4, 3), (16.1, 1.5), (14.9, 1), (fToC(66), 2.5)])
        XCTAssertEqual(daily[0].high, expected, accuracy: 1e-6)
        XCTAssertEqual(daily[0].highSpread ?? 0, fToC(66) - 14.9, accuracy: 1e-6)
        XCTAssertTrue(daily[0].summary?.contains("high near 66") ?? false)
        XCTAssertNotNil(daily[0].sunrise)
        XCTAssertLessThan(daily[0].sunrise!, daily[0].sunset!)
        // NWS covers ~7 days; the last days are model-only.
        XCTAssertNil(daily[9].summary)
    }

    func testHourlyBlendNYC() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let nwsHourly = try NWSPeriod.decodeList(try Fixture.data("nws_hourly"))
        let now = try XCTUnwrap(om.currentConditions()).time
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nwsHourly, now: now)
        XCTAssertEqual(hourly.count, 240)

        // Hour 0 (local midnight, before NWS hourly starts): models only.
        let h0 = hourly[0]
        // best_match, HRRR and GFS are the same NOAA value (14.2): counted once, at HRRR's weight 3.
        let expected0 = wmean([(14.2, 3), (13.9, 1.5), (14.9, 1)])
        XCTAssertEqual(h0.temperature, expected0, accuracy: 1e-6)
        XCTAssertEqual(h0.temperatureSpread ?? 0, 1.0, accuracy: 1e-6)

        // An hour NWS covers must be pulled towards the NWS value.
        let nws = nwsHourly[5]
        let blended = try XCTUnwrap(hourly.first { $0.time == nws.startTime })
        let modelOnly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now).first { $0.time == nws.startTime }!
        XCTAssertLessThanOrEqual(abs(blended.temperature - nws.temperatureC!), abs(modelOnly.temperature - nws.temperatureC!) + 1e-9)
        for h in hourly {
            if let p = h.precipitationProbability { XCTAssertTrue((0...100).contains(p)) }
        }
    }

    func testReconcile() {
        // Drizzle icon but consensus is dry → cloudy.
        XCTAssertEqual(ForecastBlender.reconcile(code: 51, precipitationProbability: 10, precipitation: 0, temperature: 10), 3)
        // Cloudy icon but consensus is wet → rain.
        XCTAssertEqual(ForecastBlender.reconcile(code: 3, precipitationProbability: 80, precipitation: 2, temperature: 10), 63)
        XCTAssertEqual(ForecastBlender.reconcile(code: 3, precipitationProbability: 80, precipitation: 2, temperature: -3), 73)
        // Agreement → unchanged.
        XCTAssertEqual(ForecastBlender.reconcile(code: 61, precipitationProbability: 70, precipitation: 1, temperature: 10), 61)
        XCTAssertEqual(ForecastBlender.reconcile(code: 45, precipitationProbability: 90, precipitation: 3, temperature: 10), 45)
    }

    func testNowcast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func series(_ v: [Double]) -> [MinutelyPrecipitation] {
            v.enumerated().map { MinutelyPrecipitation(time: now.addingTimeInterval(Double($0.offset) * 900), precipitation: $0.element) }
        }
        XCTAssertEqual(Nowcast.summary(series([0, 0, 0.5, 1]), now: now, temperature: 10), "Rain starting in about 30 min")
        XCTAssertEqual(Nowcast.summary(series([0.4, 0.3, 0, 0]), now: now, temperature: 10), "Rain stopping in about 30 min")
        XCTAssertEqual(Nowcast.summary(series([0.4, 0.4]), now: now, temperature: -2), "Snow continuing for the next 2 hours")
        XCTAssertNil(Nowcast.summary(series([0, 0, 0]), now: now, temperature: 10))
        XCTAssertNil(Nowcast.summary([], now: now, temperature: 10))
    }

    func testUnits() {
        XCTAssertEqual(UnitPreference.imperial.temperatureString(0), "32°")
        XCTAssertEqual(UnitPreference.metric.temperatureString(21.6), "22°")
        XCTAssertEqual(UnitPreference.imperial.speedString(16.09344), "10 mph")
        XCTAssertEqual(UnitPreference.imperial.precipitationString(25.4), "1.00\"")
        XCTAssertEqual(UnitPreference.metric.visibilityString(16700), "17 km")
        XCTAssertEqual(UnitPreference.imperial.pressureString(1013.25), "29.92 inHg")
        XCTAssertEqual(Compass.abbreviation(68), "ENE")
        XCTAssertEqual(Compass.abbreviation(359), "N")
        XCTAssertEqual(Compass.degrees("SW"), 225)
        XCTAssertEqual(UVScale.category(7), "High")
    }
}
