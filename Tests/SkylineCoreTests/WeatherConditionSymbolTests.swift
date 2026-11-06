import XCTest
@testable import SkylineCore

/// Pins `WeatherCondition.symbolName(isDay:)` so drizzle, showers, and
/// thunder-with-hail stay readable rain glyphs. Descriptions and categories
/// are intentionally not asserted here.
final class WeatherConditionSymbolTests: XCTestCase {

    func testDrizzleUsesReadableRainSymbol() {
        for code in [51, 53, 55] {
            XCTAssertEqual(WeatherCondition(wmoCode: code).symbolName(isDay: true), "cloud.rain.fill", "WMO \(code) day")
            XCTAssertEqual(WeatherCondition(wmoCode: code).symbolName(isDay: false), "cloud.rain.fill", "WMO \(code) night")
        }
    }

    func testShowersUseRainCloudDayAndNight() {
        for code in [80, 81, 82] {
            let day = WeatherCondition(wmoCode: code).symbolName(isDay: true)
            let night = WeatherCondition(wmoCode: code).symbolName(isDay: false)
            XCTAssertEqual(day, "cloud.rain.fill", "WMO \(code) day")
            XCTAssertEqual(night, "cloud.rain.fill", "WMO \(code) night")
            XCTAssertNotEqual(day, "cloud.sun.rain.fill", "WMO \(code) day")
            XCTAssertNotEqual(night, "cloud.moon.rain.fill", "WMO \(code) night")
        }
    }

    func testRainAndHeavyRainSymbolsUnchanged() {
        for isDay in [true, false] {
            XCTAssertEqual(WeatherCondition(wmoCode: 61).symbolName(isDay: isDay), "cloud.rain.fill")
            XCTAssertEqual(WeatherCondition(wmoCode: 63).symbolName(isDay: isDay), "cloud.rain.fill")
            XCTAssertEqual(WeatherCondition(wmoCode: 65).symbolName(isDay: isDay), "cloud.heavyrain.fill")
        }
    }

    func testThunderstormSymbolsShowRain() {
        for code in [95, 96, 99] {
            XCTAssertEqual(WeatherCondition(wmoCode: code).symbolName(isDay: true), "cloud.bolt.rain.fill", "WMO \(code) day")
            XCTAssertEqual(WeatherCondition(wmoCode: code).symbolName(isDay: false), "cloud.bolt.rain.fill", "WMO \(code) night")
        }
    }

    func testDryFogAndSnowSymbolsUnchanged() {
        XCTAssertEqual(WeatherCondition(wmoCode: 0).symbolName(isDay: true), "sun.max.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 2).symbolName(isDay: true), "cloud.sun.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 3).symbolName(isDay: true), "cloud.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 45).symbolName(isDay: true), "cloud.fog.fill")
        XCTAssertEqual(WeatherCondition(wmoCode: 71).symbolName(isDay: true), "cloud.snow.fill")
    }
}
