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
}
