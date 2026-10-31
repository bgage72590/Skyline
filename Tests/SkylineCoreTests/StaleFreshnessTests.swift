import XCTest
@testable import SkylineCore

/// Age-only staleness uses Open-Meteo's time (NWS time only when NWS is the sole source), and a
/// fresh-cadence city keeps the background threshold until its first fresh-cadence attempt.
/// Static dates and a hand-built report; no network. T1–T8.
final class StaleFreshnessTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshMinutes = 15
    var backgroundThreshold: TimeInterval { DataAge.staleAfter(refreshMinutes: refreshMinutes, role: .background) }
    var freshThreshold: TimeInterval { DataAge.staleAfter(refreshMinutes: refreshMinutes) }

    func report(dataAsOf: Date, forecastAsOf: Date?, mode: ForecastMode?) -> WeatherReport {
        let loc = WeatherLocation(id: "41.1400,-73.2600", name: "Fairfield", region: "CT", country: "United States",
                                  coordinate: Coordinate(latitude: 41.14, longitude: -73.26),
                                  timeZoneIdentifier: "America/New_York")
        let current = CurrentConditions(time: dataAsOf, temperature: 18, apparentTemperature: 18,
                                        humidity: 60, dewPoint: 12, weatherCode: 1, isDay: true,
                                        precipitation: 0, cloudCover: 20, pressure: 1015,
                                        windSpeed: 10, windDirection: 180, windGust: nil,
                                        visibility: 16_000, uvIndex: 3)
        var r = WeatherReport(location: loc, fetchedAt: dataAsOf, timeZoneIdentifier: "America/New_York",
                              current: current, hourly: [], daily: [], dataAsOf: dataAsOf)
        r.forecastAsOf = forecastAsOf
        r.forecastMode = mode
        return r
    }

    /// T1: Open-Meteo 5 min old, NWS 50 min old. The shown age is 5 min, so a 30 min threshold is not stale.
    func testT1OpenMeteoFiveMinutesOldWithNWSFiftyMinutesIsNotStale() {
        let r = report(dataAsOf: now.addingTimeInterval(-50 * 60),
                       forecastAsOf: now.addingTimeInterval(-5 * 60), mode: .blend)
        XCTAssertEqual(r.dataAge(at: now), 50 * 60, accuracy: 0, "oldest input is the cached NWS copy")
        XCTAssertEqual(r.freshnessAge(at: now), 5 * 60, accuracy: 0)
        XCTAssertEqual(freshThreshold, 30 * 60, accuracy: 0)
        XCTAssertFalse(r.freshnessAge(at: now) > freshThreshold)
        XCTAssertEqual(DataAge.updatedText(r, now: now), "Updated 5 min ago")
    }

    /// T2: NWS-only uses `dataAsOf` even when `forecastAsOf` is set. An older saved report (nil forecast
    /// time, nil mode) falls back to `dataAsOf` too.
    func testT2NWSOnlyAndNilForecastAsOfFallBackToDataAsOf() {
        let data = now.addingTimeInterval(-50 * 60)
        let nwsOnly = report(dataAsOf: data, forecastAsOf: now.addingTimeInterval(-5 * 60), mode: .nwsOnly)
        XCTAssertEqual(nwsOnly.freshnessDate, data)
        XCTAssertEqual(nwsOnly.freshnessAge(at: now), 50 * 60, accuracy: 0)

        let older = report(dataAsOf: data, forecastAsOf: nil, mode: nil)
        XCTAssertEqual(older.freshnessDate, data)
        XCTAssertEqual(older.freshnessAge(at: now), 50 * 60, accuracy: 0)

        let blendMissing = report(dataAsOf: data, forecastAsOf: nil, mode: .blend)
        XCTAssertEqual(blendMissing.freshnessDate, data)
    }

    /// T3: Open-Meteo 45 min old, after a fresh-cadence attempt, is past the 30 min threshold.
    func testT3FortyFiveMinuteOpenMeteoWithFreshAttemptIsStale() {
        let r = report(dataAsOf: now.addingTimeInterval(-3 * 3600),
                       forecastAsOf: now.addingTimeInterval(-45 * 60), mode: .blend)
        var book = FreshAttemptBook()
        book.recordAttempt(id: r.location.id, role: .freshCadence)
        let threshold = book.displayStaleAfter(id: r.location.id, currentRole: .freshCadence,
                                               refreshMinutes: refreshMinutes)
        XCTAssertEqual(threshold, 30 * 60, accuracy: 0)
        XCTAssertEqual(r.freshnessAge(at: now), 45 * 60, accuracy: 0)
        XCTAssertGreaterThan(r.freshnessAge(at: now), threshold)
    }

    /// T4: fresh-cadence with no attempt, or with a background attempt, uses the background threshold.
    /// A fresh-cadence attempt uses max(30, n+15). Background role is always the background threshold.
    func testT4FreshAttemptBookThresholds() {
        XCTAssertEqual(backgroundThreshold, WeatherService.TTL.background + 15 * 60, accuracy: 0)
        let id = "city"
        var book = FreshAttemptBook()

        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: refreshMinutes),
                       backgroundThreshold)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .background, refreshMinutes: refreshMinutes),
                       backgroundThreshold)

        book.recordAttempt(id: id, role: .background)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: refreshMinutes),
                       backgroundThreshold)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .background, refreshMinutes: refreshMinutes),
                       backgroundThreshold)

        book.recordAttempt(id: id, role: .freshCadence)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: 15), 30 * 60, accuracy: 0)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: 60), 75 * 60, accuracy: 0)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .background, refreshMinutes: 60),
                       DataAge.staleAfter(refreshMinutes: 60, role: .background), accuracy: 0)
    }

    /// T5: error-worded banners, byte for byte. Daily-limit copy is the quota sentence; the others are
    /// the existing offline / back-off / couldn't-update sentences.
    func testT5BannerLineSnapshots() {
        let tz = TimeZone(secondsFromGMT: -5 * 3600)!
        let locale = Locale(identifier: "en_US")
        let limitNow = Date(timeIntervalSince1970: 1_793_484_000) // 2026-10-31 17:00 GMT-5
        let dataTime = Date(timeIntervalSince1970: 1_793_481_000) // 16:10
        let until = Date(timeIntervalSince1970: 1_793_495_100) // 20:05
        let cached = OpenMeteoQuota.cachedMessage(dataTime: dataTime, until: until, now: limitNow,
                                                  timeZone: tz, locale: locale)
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: false, error: cached, dataTime: "unused"),
                       "Open-Meteo's free daily limit is used up · showing data from 4:10 PM · updates resume after 8:05 PM")
        let nws = OpenMeteoQuota.nwsOnlyMessage(until: until, now: limitNow, timeZone: tz, locale: locale)
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: false, error: nws, dataTime: "unused"),
                       "Open-Meteo's free daily limit is used up · showing the National Weather Service forecast · full forecast after 8:05 PM")

        let retryNow = Date(timeIntervalSince1970: 1_800_000_000)
        let retry = UserFacingError.message(
            HTTPError.backingOff(host: "api.open-meteo.com", until: retryNow.addingTimeInterval(180)),
            now: retryNow, timeZone: tz, locale: locale)
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: true, error: retry, dataTime: "2:10 PM"),
                       "Open-Meteo busy, retrying at 3:04 AM")

        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: true, error: RefreshBookkeeping.offlineSavedMessage,
                                                    dataTime: "3:05 PM"),
                       "Offline · showing data from 3:05 PM")
        XCTAssertEqual(RefreshBookkeeping.bannerLine(offline: false, error: RefreshBookkeeping.savedDataMessage,
                                                    dataTime: "3:05 PM"),
                       "Couldn’t update · showing data from 3:05 PM")
    }

    /// T6: another city's row age follows the shown forecast, not the oldest input.
    func testT6RowAgeUsesFreshnessAge() {
        var r = report(dataAsOf: now.addingTimeInterval(-50 * 60),
                       forecastAsOf: now.addingTimeInterval(-10 * 60), mode: .blend)
        XCTAssertNil(MenuSummary.rowAge(r, now: now, staleAfter: freshThreshold))
        r.forecastAsOf = now.addingTimeInterval(-45 * 60)
        XCTAssertEqual(MenuSummary.rowAge(r, now: now, staleAfter: freshThreshold), "45 min")
        r.forecastAsOf = now.addingTimeInterval(-150 * 60)
        r.dataAsOf = now.addingTimeInterval(-50 * 60)
        XCTAssertEqual(MenuSummary.rowAge(r, now: now, staleAfter: freshThreshold), "2 h")
    }

    /// T7: fresh-cadence threshold is max(30, n+15) minutes, for several refresh intervals.
    func testT7RefreshMinutesThreshold() {
        let samples = [0, 1, 14, 15, 16, 30, 45, 60, 120]
        for n in samples {
            XCTAssertEqual(DataAge.staleAfter(refreshMinutes: n), Double(max(30, n + 15)) * 60, accuracy: 0, "n=\(n)")
        }
    }

    /// T8: viewed-city transitions, deleting the selected city, and changing the menu-bar pin.
    /// Each step asserts the display threshold. A background refresh records `.background`, which is
    /// what puts the city back on the background threshold the next time it is viewed.
    func testT8FreshAttemptBookTransitions() {
        let n = refreshMinutes
        let background = backgroundThreshold
        let fresh = freshThreshold
        XCTAssertEqual(fresh, 30 * 60, accuracy: 0)
        var book = FreshAttemptBook()
        let id = "city"

        book.recordAttempt(id: id, role: .background)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .background, refreshMinutes: n), background, accuracy: 0)

        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: n), background, accuracy: 0,
                       "becomes viewed before a fresh attempt")

        book.recordAttempt(id: id, role: .freshCadence)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: n), fresh, accuracy: 0)

        book.recordAttempt(id: id, role: .background)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .background, refreshMinutes: n), background, accuracy: 0,
                       "returns to background")

        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: n), background, accuracy: 0,
                       "viewed again, until the next fresh attempt")
        book.recordAttempt(id: id, role: .freshCadence)
        XCTAssertEqual(book.displayStaleAfter(id: id, currentRole: .freshCadence, refreshMinutes: n), fresh, accuracy: 0)

        var deleted = FreshAttemptBook()
        deleted.recordAttempt(id: "selected", role: .freshCadence)
        XCTAssertEqual(deleted.displayStaleAfter(id: "next", currentRole: .freshCadence, refreshMinutes: n), background, accuracy: 0,
                       "the next city becomes viewed with no fresh attempt")

        var pin = FreshAttemptBook()
        pin.recordAttempt(id: "pinned", role: .background)
        XCTAssertEqual(pin.displayStaleAfter(id: "pinned", currentRole: .freshCadence, refreshMinutes: n), background, accuracy: 0,
                       "a newly pinned city keeps the background threshold")
    }
}
