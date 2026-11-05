import XCTest
@testable import SkylineCore

/// Daily icon caption: snow depth only under a snow icon; every other icon keeps `popText`.
final class DailyPrecipCaptionTests: XCTestCase {
    let imperial = DisplayUnits.imperial
    let metric = DisplayUnits.metric

    private func day(code: Int, snow: Double?, pop: Double?) -> DailyForecast {
        var day = DailyForecast(date: Date(timeIntervalSince1970: 0), weatherCode: code, high: 0, low: -5,
                                precipitationProbability: pop)
        day.snowfallSum = snow
        return day
    }

    private func widgetDay(code: Int, snow: Double?, pop: Double?) throws -> WidgetSnapshot.Day {
        var object: [String: Any] = ["date": 0, "weatherCode": code, "high": 0, "low": -5]
        if let snow { object["snowfallSum"] = snow }
        if let pop { object["precipitationProbability"] = pop }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(WidgetSnapshot.Day.self, from: data)
    }

    /// Primitive, `DailyForecast`, and `WidgetSnapshot.Day` agree.
    private func caption(code: Int, snow: Double?, pop: Double?, units: DisplayUnits = .imperial,
                          file: StaticString = #filePath, line: UInt = #line) throws -> DailyPrecipCaption? {
        let primitive = HourlyDisplay.dailyCaption(weatherCode: code, snowfallSum: snow,
                                                    precipitationProbability: pop, units: units)
        let fromDay = HourlyDisplay.dailyCaption(day(code: code, snow: snow, pop: pop), units: units)
        let fromWidget = HourlyDisplay.dailyCaption(try widgetDay(code: code, snow: snow, pop: pop), units: units)
        XCTAssertEqual(fromDay, primitive, file: file, line: line)
        XCTAssertEqual(fromWidget, primitive, file: file, line: line)
        return primitive
    }

    private func expectChance(code: Int, snow: Double?, pop: Double?, _ text: String?,
                              units: DisplayUnits = .imperial, file: StaticString = #filePath, line: UInt = #line) throws {
        let value = try caption(code: code, snow: snow, pop: pop, units: units, file: file, line: line)
        if let text {
            XCTAssertEqual(value, .chance(text), file: file, line: line)
        } else {
            XCTAssertNil(value, "code \(code) snow \(String(describing: snow)) pop \(String(describing: pop))",
                         file: file, line: line)
        }
        XCTAssertEqual(HourlyDisplay.popText(probability: pop,
                                              isPrecipitationIcon: WeatherCondition(wmoCode: code).isPrecipitation),
                       text, file: file, line: line)
    }

    private func expectSnow(code: Int, snow: Double, pop: Double?, units: DisplayUnits,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let amount = units.snowString(snow)
        let value = try caption(code: code, snow: snow, pop: pop, units: units, file: file, line: line)
        XCTAssertEqual(value, .snow(amount + " snow"), file: file, line: line)
        XCTAssertEqual(value?.accessibilityLabel, "Snow, \(amount)", file: file, line: line)
        XCTAssertFalse(value?.accessibilityLabel.lowercased().contains("snow snow") ?? true, file: file, line: line)
    }

    // MARK: Chance path (popText unchanged)

    func testChanceAndMissing() throws {
        try expectChance(code: 61, snow: 0, pop: 56, "56%")
        try expectChance(code: 2, snow: 0, pop: 12, nil)
        try expectChance(code: 0, snow: 0, pop: nil, nil)
        try expectChance(code: 61, snow: 0, pop: nil, nil)
        try expectChance(code: 3, snow: 0, pop: 0, nil)
        try expectChance(code: 61, snow: 0, pop: 0, "0%")
    }

    /// Shipped `Double.rounded()` is toNearestOrAwayFromZero, including halves.
    func testRoundingHalvesAndCutoff() throws {
        try expectChance(code: 1, snow: 8, pop: 28.4, "28%")
        try expectChance(code: 1, snow: 8, pop: 28.5, "29%")
        try expectChance(code: 1, snow: 8, pop: 28.6, "29%")
        try expectChance(code: 3, snow: 8, pop: 29.5, "30%")
        try expectChance(code: 0, snow: 8, pop: 19.5, "20%")
        try expectChance(code: 2, snow: 8, pop: 19.4, nil)
        try expectChance(code: 61, snow: 8, pop: 12, "12%")
        try expectChance(code: 63, snow: nil, pop: 0, "0%")
        try expectChance(code: 80, snow: 3, pop: nil, nil)
        XCTAssertEqual(HourlyDisplay.popText(probability: 28.5, isPrecipitationIcon: false), "29%")
        XCTAssertEqual(HourlyDisplay.popText(probability: 29.5, isPrecipitationIcon: false), "30%")
        XCTAssertEqual(Int(28.5.rounded()), 29)
        XCTAssertEqual(Int(29.5.rounded()), 30)
    }

    // MARK: Dry icon with model snow (the screenshot)

    func testDryIconHidesSnowInches() throws {
        try expectChance(code: 0, snow: 1.524, pop: nil, nil)
        try expectChance(code: 1, snow: 1.524, pop: nil, nil)
        try expectChance(code: 3, snow: 1.78, pop: 10, nil)
        try expectChance(code: 3, snow: 1.78, pop: 46, "46%")
        try expectChance(code: 2, snow: 5, pop: nil, nil)
        try expectChance(code: 45, snow: 2, pop: 30, "30%")
    }

    func testRainMixedAndThunderKeepTheChance() throws {
        try expectChance(code: 61, snow: 8, pop: 46, "46%")
        try expectChance(code: 51, snow: 4, pop: 33, "33%")
        try expectChance(code: 66, snow: 3, pop: 55, "55%")
        try expectChance(code: 67, snow: 3, pop: 40, "40%")
        try expectChance(code: 95, snow: 2, pop: 70, "70%")
        try expectChance(code: 99, snow: 6, pop: 22, "22%")
    }

    // MARK: Actual snow

    func testSnowIconShowsLabeledDepth() throws {
        for code in [71, 72, 73, 74, 75, 76, 77, 85, 86] {
            try expectSnow(code: code, snow: 1.524, pop: 80, units: imperial)
            XCTAssertEqual(try caption(code: code, snow: 1.524, pop: nil, units: imperial), .snow("0.6 in snow"),
                           "code \(code) must not invent a percent")
        }
        try expectSnow(code: 73, snow: 7.6, pop: 40, units: imperial)
        XCTAssertEqual(try caption(code: 73, snow: 7.6, pop: 40), .snow("3 in snow"))
        try expectSnow(code: 71, snow: 1.5, pop: 90, units: metric)
        XCTAssertEqual(try caption(code: 71, snow: 1.5, pop: 90, units: metric), .snow("1.5 cm snow"))
        try expectSnow(code: 75, snow: 12.4, pop: nil, units: metric)
        XCTAssertEqual(try caption(code: 75, snow: 12.4, pop: nil, units: metric), .snow("12 cm snow"))
    }

    func testSnowIconBelowThresholdFallsThroughToChance() throws {
        try expectChance(code: 73, snow: 0.4, pop: 40, "40%")
        try expectChance(code: 85, snow: 0.4, pop: 19.4, "19%")
        try expectChance(code: 71, snow: 0, pop: 0, "0%")
        try expectChance(code: 73, snow: nil, pop: nil, nil)
        try expectChance(code: 86, snow: -1, pop: 25, "25%")
        XCTAssertEqual(try caption(code: 73, snow: 0.5, pop: 10), .snow("0.2 in snow"))
    }

    // MARK: blendDaily (read-only)

    func testWarmClearDayKeepsSnowOutOfTheCaption() throws {
        let day = try blendDay(warmClearJSON)
        XCTAssertEqual(day.condition.category, .clear)
        XCTAssertEqual(day.weatherCode, 0)
        XCTAssertTrue(day.hasSnow)
        XCTAssertNil(day.precipitationProbability)
        XCTAssertNil(try caption(code: day.weatherCode, snow: day.snowfallSum, pop: day.precipitationProbability))
        XCTAssertNil(HourlyDisplay.dailyCaption(day, units: imperial))
    }

    func testColdBlendShowsSnowCaption() throws {
        let day = try blendDay(coldSnowJSON)
        XCTAssertEqual(day.condition.category, .snow)
        XCTAssertTrue(day.hasSnow)
        let amount = imperial.snowString(day.snowfallSum)
        XCTAssertEqual(HourlyDisplay.dailyCaption(day, units: imperial), .snow(amount + " snow"))
        let widget = try widgetDay(code: day.weatherCode, snow: day.snowfallSum, pop: day.precipitationProbability)
        XCTAssertEqual(HourlyDisplay.dailyCaption(widget, units: imperial), .snow(amount + " snow"))
    }

    // MARK: View source (app and widget targets do not compile on Linux)

    func testDailyCardAndWidgetCallTheHelper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let detail = try String(contentsOf: root.appendingPathComponent("Sources/Skyline/Views/LocationDetailView.swift"),
                                 encoding: .utf8)
        let widget = try String(contentsOf: root.appendingPathComponent("Sources/SkylineWidget/WidgetViews.swift"),
                                 encoding: .utf8)
        let menu = try String(contentsOf: root.appendingPathComponent("Sources/Skyline/Views/MenuBarViews.swift"),
                               encoding: .utf8)
        XCTAssertTrue(detail.contains("dailyCaption"))
        XCTAssertTrue(detail.contains("DailyPrecipCaption"))
        XCTAssertFalse(detail.contains("if day.hasSnow"), "DailyCard must not gate the caption on hasSnow")
        XCTAssertTrue(widget.contains("dailyCaption"))
        XCTAssertTrue(widget.contains("DailyPrecipCaption"))
        XCTAssertFalse(widget.contains("(d.snowfallSum ?? 0) >= 0.5"))
        XCTAssertFalse(widget.contains("(snowfallSum ?? 0) >= 0.5"))
        XCTAssertTrue(menu.contains("HourlyDisplay.popText(day)"))
        XCTAssertFalse(menu.contains("dailyCaption"))
    }

    private func blendDay(_ json: String) throws -> DailyForecast {
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let days = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: TimeZone(identifier: "UTC")!)
        return try XCTUnwrap(days.first)
    }
}

private let warmClearJSON = """
{"latitude":44,"longitude":-73,"timezone":"UTC","utc_offset_seconds":0,
 "daily":{"time":[1790000000],"weather_code":[0],
          "temperature_2m_max_ecmwf_ifs025":[8.9],"temperature_2m_min_ecmwf_ifs025":[2.2],
          "snowfall_sum_ecmwf_ifs025":[1.52]},
 "hourly":{"time":[1790000000],"temperature_2m_ecmwf_ifs025":[5]}}
"""

private let coldSnowJSON = """
{"latitude":44,"longitude":-73,"timezone":"UTC","utc_offset_seconds":0,
 "daily":{"time":[1790000000],"weather_code_ecmwf_ifs025":[61],"weather_code_icon_seamless":[61],
          "temperature_2m_max_ecmwf_ifs025":[0],"temperature_2m_min_ecmwf_ifs025":[-4],
          "temperature_2m_max_icon_seamless":[0],"temperature_2m_min_icon_seamless":[-4],
          "precipitation_probability_max_ecmwf_ifs025":[90],"precipitation_probability_max_icon_seamless":[90],
          "precipitation_sum_ecmwf_ifs025":[12],"precipitation_sum_icon_seamless":[8],
          "snowfall_sum_ecmwf_ifs025":[8.4],"snowfall_sum_icon_seamless":[5.6]},
 "hourly":{"time":[1790000000,1790003600,1790007200],
           "temperature_2m_ecmwf_ifs025":[-2,-2,-2],"temperature_2m_icon_seamless":[-2,-2,-2],
           "weather_code_ecmwf_ifs025":[63,63,63],"weather_code_icon_seamless":[63,63,63],
           "precipitation_probability_ecmwf_ifs025":[90,90,90],"precipitation_probability_icon_seamless":[90,90,90],
           "precipitation_ecmwf_ifs025":[2,2,2],"precipitation_icon_seamless":[2,2,2],
           "snowfall_ecmwf_ifs025":[1.4,1.4,1.4],"snowfall_icon_seamless":[1.4,1.4,1.4]}}
"""
