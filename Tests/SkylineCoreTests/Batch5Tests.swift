import XCTest
@testable import SkylineCore

/// Batch 5: radar/forecast features (T12 future radar, T13 snow, L20 SPC outlook, L21 rainfall totals,
/// L18 model chart, L7 radar load race), QA 4 (non-US places), the shared rain start/stop rule, and the
/// Code Reviewer / QA batch 4 fixes.
final class Batch5Tests: XCTestCase {
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let ny = TimeZone(identifier: "America/New_York")!
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
    lazy var hourLabel: (Date) -> String = { [ny] d in
        let f = DateFormatter(); f.timeZone = ny; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h a"; return f.string(from: d)
    }
    lazy var timeLabel: (Date) -> String = { [ny] d in
        let f = DateFormatter(); f.timeZone = ny; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    func current(_ t: Date, temp: Double = 12, code: Int = 3) -> CurrentConditions {
        CurrentConditions(time: t, temperature: temp, apparentTemperature: temp, humidity: 60, dewPoint: nil, weatherCode: code,
                          isDay: true, precipitation: 0, cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil,
                          windGust: nil, visibility: nil, uvIndex: nil)
    }

    func report(minutely: [MinutelyPrecipitation] = [], daily: [DailyForecast] = [], hourly: [HourlyForecast] = [],
                alerts: [WeatherAlert] = [], at t: Date? = nil, currentTime: Date? = nil, code: Int = 3) -> WeatherReport {
        WeatherReport(location: nyc, fetchedAt: t ?? fixtureTime, timeZoneIdentifier: "America/New_York",
                      current: current(currentTime ?? t ?? fixtureTime, code: code), hourly: hourly, daily: daily,
                      minutely: minutely, alerts: alerts)
    }

    func quarters(_ mm: [Double], from t: Date) -> [MinutelyPrecipitation] {
        let start = (t.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
        return mm.enumerated().map { MinutelyPrecipitation(time: Date(timeIntervalSince1970: start + Double($0.offset) * 900), precipitation: $0.element) }
    }

    func hour(_ t: Date, code: Int = 3, pop: Double = 10, precip: Double = 0) -> HourlyForecast {
        HourlyForecast(time: t, temperature: 12, precipitationProbability: pop, precipitation: precip, weatherCode: code, isDay: true)
    }

    // MARK: QA 4: non-US places

    func testBorderOutlinesKeepCanadaAndMexicoOut() {
        let inside: [(String, Double, Double)] = [
            ("New York", 40.71, -74.01), ("Seattle", 47.61, -122.33), ("San Diego", 32.72, -117.16), ("El Paso", 31.76, -106.49),
            ("Detroit", 42.33, -83.05), ("Buffalo", 42.89, -78.85), ("Key West", 24.55, -81.78), ("Brownsville", 25.93, -97.48),
            ("Duluth", 46.79, -92.10), ("Burlington VT", 44.48, -73.21), ("Caribou ME", 46.86, -68.01), ("Fairfield CT", 41.14, -73.26),
            ("Denver", 39.74, -104.99), ("Massena", 44.93, -74.89), ("Bellingham", 48.75, -122.48), ("Nogales", 31.35, -110.94),
        ]
        let outside: [(String, Double, Double)] = [
            ("Toronto", 43.65, -79.38), ("Montreal", 45.50, -73.57), ("Ottawa", 45.42, -75.70), ("Vancouver", 49.28, -123.12),
            ("Victoria", 48.43, -123.37), ("Monterrey", 25.69, -100.32), ("Tijuana", 32.50, -117.00), ("Juárez", 31.69, -106.42),
            ("Thunder Bay", 48.38, -89.25), ("Hamilton", 43.26, -79.87), ("Kingston ON", 44.23, -76.49), ("Brockville", 44.59, -75.68),
            ("Sarnia", 42.97, -82.38), ("Fredericton", 45.96, -66.64), ("Nassau", 25.05, -77.35), ("London", 51.5, -0.13),
        ]
        for (name, lat, lon) in inside {
            XCTAssertTrue(Coordinate(latitude: lat, longitude: lon).isInCONUS, name)
            XCTAssertTrue(Coordinate(latitude: lat, longitude: lon).isLikelyInNWSCoverage, name)
        }
        for (name, lat, lon) in outside {
            XCTAssertFalse(Coordinate(latitude: lat, longitude: lon).isInCONUS, name)
            XCTAssertFalse(Coordinate(latitude: lat, longitude: lon).isLikelyInNWSCoverage, name)
        }
        // Alaska: Juneau and Anchorage are NWS; Whitehorse (Yukon) isn't, though it's inside the old box.
        XCTAssertTrue(Coordinate(latitude: 58.30, longitude: -134.42).isLikelyInNWSCoverage)
        XCTAssertTrue(Coordinate(latitude: 61.2, longitude: -149.9).isLikelyInNWSCoverage)
        XCTAssertFalse(Coordinate(latitude: 60.72, longitude: -135.06).isLikelyInNWSCoverage)
        XCTAssertTrue(Coordinate(latitude: 21.31, longitude: -157.86).isLikelyInNWSCoverage) // Honolulu
    }

    func testKnownCountryOverridesTheOutline() {
        // Windsor, Ontario sits south of Detroit, inside any simple outline: its saved country decides.
        let windsor = WeatherLocation(name: "Windsor", region: "Ontario", country: "Canada",
                                      coordinate: Coordinate(latitude: 42.30, longitude: -83.02))
        XCTAssertFalse(windsor.isInCONUS)
        XCTAssertFalse(windsor.isLikelyInNWSCoverage)
        XCTAssertEqual(RadarProvider.preferred(for: windsor), .rainViewer)
        XCTAssertTrue(nyc.isInCONUS)
        XCTAssertEqual(RadarProvider.preferred(for: nyc), .nexrad)
        var unknown = nyc; unknown.country = nil
        XCTAssertTrue(unknown.isInCONUS, "unknown country falls back to the outline")
        XCTAssertFalse(USCoverage.isKnownOutsideUS(country: "Puerto Rico"))
        XCTAssertFalse(USCoverage.isKnownOutsideUS(country: "United States of America"))
        XCTAssertTrue(USCoverage.isKnownOutsideUS(country: "Mexico"))
        XCTAssertEqual(ForecastModel.models(inCONUS: false), [.bestMatch, .ecmwf, .gfs, .icon])
    }

    func testTorontoMakesNoNWSOrHRRRRequests() async throws {
        let client = MockHTTPClient()
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil), now: { self.fixtureTime })
        let toronto = WeatherLocation(name: "Toronto", region: "Ontario", country: "Canada",
                                      coordinate: Coordinate(latitude: 43.65, longitude: -79.38))
        _ = try await service.report(for: toronto)
        XCTAssertFalse(client.requests.contains { $0.host == "api.weather.gov" }, "\(client.requests)")
        XCTAssertFalse(client.requests.contains { $0.absoluteString.contains("gfs_hrrr") })
        XCTAssertFalse(client.requests.contains { $0.host == "www.spc.noaa.gov" })
    }

    /// A point inside the outline that NWS doesn't serve: asked once, then remembered for a week.
    func testNWS404IsRememberedForAWeek() async throws {
        final class Points404: HTTPClient, @unchecked Sendable {
            let inner = MockHTTPClient()
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                if url.absoluteString.contains("api.weather.gov/points") { _ = try? await inner.get(url, headers: headers); throw HTTPError.status(404, url) }
                return try await inner.get(url, headers: headers)
            }
        }
        let client = Points404()
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let border = WeatherLocation(name: "Edge", coordinate: Coordinate(latitude: 42.30, longitude: -83.02))
        _ = try await service.report(for: border)
        clock.now = fixtureTime.addingTimeInterval(20 * 60)
        _ = try await service.report(for: border, forceRefresh: true)
        let points = client.inner.requests.filter { $0.absoluteString.contains("/points/") }
        XCTAssertEqual(points.count, 1, "not re-asked on the next refresh")
        XCTAssertEqual(client.inner.requests.filter { $0.absoluteString.contains("alerts/active") }.count, 1,
                       "alerts aren't asked for a known non-NWS point either")
        clock.now = fixtureTime.addingTimeInterval(8 * 86400)
        _ = try await service.report(for: border, forceRefresh: true)
        XCTAssertEqual(client.inner.requests.filter { $0.absoluteString.contains("/points/") }.count, 2, "asked again after a week")
    }

    // MARK: Briefing and rain notification agree

    func testNowcastLineAndRainNotificationGiveTheSameTimes() {
        var p = NotificationPrefs(); p.rain = true
        for offset in stride(from: 0.0, to: 900, by: 120) {
            let now = fixtureTime.addingTimeInterval(offset)
            let r = report(minutely: quarters([0, 0, 0.3, 0.6, 0.5], from: fixtureTime), at: now,
                           currentTime: fixtureTime.addingTimeInterval(-15 * 60)) // Open-Meteo's quarter, behind the clock
            var state = NotificationState()
            let note = NotificationPlanner.plan(r, locationName: "NYC", prefs: p, state: &state, now: now, timeZone: ny, timeLabel: timeLabel)
            let line = r.nowcastSummary(at: now)
            guard let body = note.first?.body else { XCTFail("no notification at +\(offset)s"); continue }
            let n = body.split(separator: " ").compactMap { Int($0) }.first
            XCTAssertEqual(line, "Rain starting in about \(n!) min", "at +\(Int(offset))s: \(body)")
            // The briefing text uses the same clock.
            let briefing = Briefing.headline(r, now: now, hourLabel: hourLabel, delta: { Int($0.rounded()) })
            XCTAssertTrue(briefing.hasPrefix("Rain starting in about \(n!) min."), briefing)
        }
    }

    func testRainStopUsesTheSameRule() {
        var p = NotificationPrefs(); p.rain = true
        // Wet, one dry quarter, wet again, then dry: the stop is the *sustained* dry spell for both.
        let r = report(minutely: quarters([0.4, 0.3, 0, 0.3, 0, 0, 0], from: fixtureTime))
        var state = NotificationState()
        let n = NotificationPlanner.plan(r, locationName: "NYC", prefs: p, state: &state, now: fixtureTime, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(n.first?.body, "Rain ending around 10:30 AM.")
        XCTAssertEqual(r.nowcastSummary(at: fixtureTime), "Rain stopping in about 60 min")
        XCTAssertEqual(Nowcast.rainEnd(r.minutely, now: fixtureTime), fixtureTime.addingTimeInterval(3600))
    }

    func testBlipAndImminentRain() {
        // A single light blip: no line and no notification.
        XCTAssertNil(Nowcast.summary(quarters([0, 0, 0.12, 0, 0], from: fixtureTime), now: fixtureTime, temperature: 10))
        // Rain in the quarter starting in 2 minutes reads "about 5 min", not "about 15".
        let now = fixtureTime.addingTimeInterval(13 * 60) // 9:43; next quarter starts 9:45
        let q = quarters([0, 0.4, 0.4], from: fixtureTime) // first quarter ends 9:45 (dry), next 9:45–10:00 wet
        XCTAssertEqual(Nowcast.summary(q, now: now, temperature: 10), "Rain starting in about 5 min")
        XCTAssertEqual(Nowcast.minutes(until: now.addingTimeInterval(60), now: now), 5)
    }

    // MARK: Briefing content (QA: coverage was 15 %)

    func testBriefingLabelsHoursByTheirStart() {
        let h = (1...12).map { k -> HourlyForecast in
            let t = Date(timeIntervalSince1970: (fixtureTime.timeIntervalSince1970 / 3600).rounded(.down) * 3600 + Double(k) * 3600)
            return k >= 7 ? hour(t, code: 63, pop: 80, precip: 2) : hour(t)
        }
        // Hour ending 4 PM (k = 7 from 9 AM) is the 3–4 PM hour: "from 3 PM".
        let r = report(hourly: h)
        XCTAssertEqual(Briefing.nextChange(r, now: fixtureTime, hourLabel: hourLabel), "Rain likely from 3 PM (80%).")
        // The hour under way already wet: "likely now".
        let wetNow = report(hourly: h.map { hour($0.time, code: 63, pop: 80, precip: 2) })
        XCTAssertEqual(Briefing.nextChange(wetNow, now: fixtureTime, hourLabel: hourLabel), "Rain likely now (80%).")
        // Raining now: ending at the start of the first dry hour.
        let ending = report(hourly: h.enumerated().map { $0.offset < 3 ? hour($0.element.time, code: 63, pop: 80, precip: 2) : hour($0.element.time) },
                            code: 63)
        XCTAssertEqual(Briefing.nextChange(ending, now: fixtureTime, hourLabel: hourLabel), "Rain ending around 12 PM.")
        // Nothing changes.
        XCTAssertEqual(Briefing.nextChange(report(hourly: h.prefix(6).map { $0 }), now: fixtureTime, hourLabel: hourLabel),
                       "Cloudy for the next 12 hours.")
        // A past hour is never "now" (QA: Toronto said "Heavy Drizzle now" for the hour that had ended).
        let pastWet = hour(fixtureTime.addingTimeInterval(-600), code: 55, pop: 90, precip: 1)
        XCTAssertEqual(Briefing.nextChange(report(hourly: [pastWet] + h.prefix(3)), now: fixtureTime, hourLabel: hourLabel),
                       "Cloudy for the next 12 hours.")
        XCTAssertEqual(Briefing.nextChange(report(hourly: []), now: fixtureTime, hourLabel: hourLabel), "Cloudy.")
    }

    func testBriefingHeadlineAddsTomorrowAndSevereRisk() {
        let day0 = DailyForecast(date: fixtureTime, weatherCode: 3, high: 15, low: 8)
        let day1 = DailyForecast(date: fixtureTime.addingTimeInterval(86400), weatherCode: 3, high: 20, low: 9)
        var r = report(daily: [day0, day1])
        r.severeOutlooks = [SevereOutlook(day: 1, risk: .slight, validFrom: fixtureTime, validUntil: fixtureTime.addingTimeInterval(20 * 3600))]
        let text = Briefing.headline(r, now: fixtureTime, hourLabel: hourLabel, delta: { Int(($0 * 9 / 5).rounded()) })
        XCTAssertEqual(text, "Cloudy. Tomorrow is 9° warmer. Slight risk of severe storms today (level 2 of 5).")
        r.severeOutlooks = [SevereOutlook(day: 1, risk: .slight, validFrom: fixtureTime, validUntil: fixtureTime.addingTimeInterval(-60))]
        XCTAssertFalse(Briefing.headline(r, now: fixtureTime, hourLabel: hourLabel, delta: { Int($0) }).contains("severe"), "expired")
        XCTAssertTrue(Briefing.rainDueSoon(report(minutely: quarters([0, 0.3], from: fixtureTime)), now: fixtureTime))
        XCTAssertFalse(Briefing.rainDueSoon(report(minutely: quarters([0, 0], from: fixtureTime)), now: fixtureTime))
        let peak = Briefing.peak([(fixtureTime, 3), (fixtureTime.addingTimeInterval(3600), 7), (fixtureTime.addingTimeInterval(30 * 3600), 9)], from: fixtureTime)
        XCTAssertEqual(peak?.value, 7)
    }

    // MARK: QA / CR batch 4 notification fixes

    func alert(_ id: String, _ severity: AlertSeverity, vtec: [String] = [], refs: [String] = [], headline: String = "Headline.") -> WeatherAlert {
        var a = WeatherAlert(id: id, event: "Flood Warning", headline: headline, severity: severity, urgency: nil, areaDescription: nil,
                             description: nil, instruction: nil, effective: nil, expires: nil,
                             ends: fixtureTime.addingTimeInterval(6 * 3600), senderName: nil)
        a.trackingKeys = vtec; a.references = refs
        return a
    }

    func testWarningUpdateNotifiesOnlyWhenMoreSevere() {
        var p = NotificationPrefs(); p.alerts = true; p.minimumSeverity = .moderate
        var state = NotificationState()
        let first = NotificationPlanner.plan(report(alerts: [alert("a1", .moderate, vtec: ["KOKX.FL.W.0006"])]), locationName: "NYC",
                                             prefs: p, state: &state, now: fixtureTime, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(first.count, 1)
        let later = fixtureTime.addingTimeInterval(3 * 3600)
        // Same event, new id (extension): silent.
        XCTAssertTrue(NotificationPlanner.plan(report(alerts: [alert("a2", .moderate, vtec: ["KOKX.FL.W.0006"], refs: ["a1"])], at: later),
                                               locationName: "NYC", prefs: p, state: &state, now: later, timeZone: ny, timeLabel: timeLabel).isEmpty)
        // No VTEC, but it references the one sent: silent too.
        XCTAssertTrue(NotificationPlanner.plan(report(alerts: [alert("a3", .moderate, refs: ["a2"])], at: later),
                                               locationName: "NYC", prefs: p, state: &state, now: later, timeZone: ny, timeLabel: timeLabel).isEmpty)
        // The same event upgraded to Severe: notified once more.
        let up = NotificationPlanner.plan(report(alerts: [alert("a4", .severe, vtec: ["KOKX.FL.W.0006"])], at: later),
                                          locationName: "NYC", prefs: p, state: &state, now: later, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(up.count, 1)
        XCTAssertTrue(NotificationPlanner.plan(report(alerts: [alert("a5", .severe, vtec: ["KOKX.FL.W.0006"])], at: later),
                                               locationName: "NYC", prefs: p, state: &state, now: later, timeZone: ny, timeLabel: timeLabel).isEmpty)
    }

    func testAlertBodySaysUntilOnceAndUnknownCountsAsMinor() {
        var p = NotificationPrefs(); p.alerts = true; p.minimumSeverity = .minor
        var state = NotificationState()
        let a = alert("u1", .unknown, headline: "Coastal Flood Statement issued October 11 until October 12 at 1:00PM EDT by NWS Upton NY")
        let b = alert("u2", .moderate, headline: "Wind Advisory")
        let n = NotificationPlanner.plan(report(alerts: [a, b]), locationName: "NYC", prefs: p, state: &state, now: fixtureTime,
                                         timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(n.map(\.alertID), ["u2", "u1"])
        XCTAssertEqual(n.first { $0.alertID == "u1" }?.body, a.headline)
        XCTAssertEqual(n.first { $0.alertID == "u2" }?.body, "Wind Advisory. Until 3:30 PM.")
    }

    func testLateBriefingWindowWrapsPastMidnight() {
        var p = NotificationPrefs(); p.morningBriefing = true; p.briefingMinutes = 22 * 60 + 30 // 10:30 PM
        var state = NotificationState()
        let r = report()
        let afterMidnight = Date(timeIntervalSince1970: 1_791_780_000) // Oct 12 00:40 ET
        let b = NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &state, now: afterMidnight, timeZone: ny)
        XCTAssertEqual(b?.id, "briefing-\(nyc.id)-2026-10-11", "belongs to the evening it was due")
        XCTAssertNil(NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &state,
                                                  now: afterMidnight.addingTimeInterval(600), timeZone: ny))
        var s2 = NotificationState()
        XCTAssertNil(NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &s2,
                                                  now: afterMidnight.addingTimeInterval(2 * 3600), timeZone: ny), "2:40 AM: window over")
    }

    func testSavedSettingsSurviveSchemaChanges() throws {
        let json = #"{"alerts":true,"rain":true,"briefingMinutes":480,"someFutureField":1}"#
        let p = try JSONDecoder().decode(NotificationPrefs.self, from: Data(json.utf8))
        XCTAssertTrue(p.alerts); XCTAssertTrue(p.rain); XCTAssertEqual(p.briefingMinutes, 480)
        XCTAssertEqual(p.minimumSeverity, .severe, "missing field keeps its default")
        let s = try JSONDecoder().decode(NotificationState.self, from: Data(#"{"briefingDay":{"x":"2026-10-11"}}"#.utf8))
        XCTAssertEqual(s.briefingDay["x"], "2026-10-11")
        XCTAssertTrue(s.alertSeverity.isEmpty)
        let round = try JSONDecoder().decode(NotificationState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }

    func testConfidenceIgnoresOneOutlierAndNeverClaimsHighFromOneForecast() {
        var day = DailyForecast(date: fixtureTime, weatherCode: 3, high: 15, low: 8, highSpread: 6)
        day.sources = [SourceReading(name: "A", high: 15, low: 8, weight: 2), SourceReading(name: "B", high: 15.5, low: 8, weight: 1.5),
                       SourceReading(name: "C", high: 14.8, low: 8, weight: 1), SourceReading(name: "D", high: 21, low: 8, weight: 0.5)]
        let c = ForecastInsight.confidence(day: day, hourly: [], timeZone: ny, now: fixtureTime, hourLabel: hourLabel,
                                           delta: { Int(($0 * 9 / 5).rounded()) })
        XCTAssertEqual(c.level, .high, c.sentence)
        var single = DailyForecast(date: fixtureTime, weatherCode: 3, high: 15, low: 8)
        single.sources = [SourceReading(name: "ECMWF", high: 15, low: 8, weight: 1)]
        let s = ForecastInsight.confidence(day: single, hourly: [], timeZone: ny, now: fixtureTime, hourLabel: hourLabel, delta: { Int($0) })
        XCTAssertEqual(s.sentence, "Medium confidence: only one forecast available for this day.")
        XCTAssertEqual(ForecastInsight.trimmedSpread([1, 2, 3]), 2)
        XCTAssertEqual(ForecastInsight.trimmedSpread([1, 2, 3, 10]), 2)
    }

    // MARK: T13 snow

    func testRainOrSnowFromBlendedAmounts() {
        // 10 mm of water, 7 cm of snow = all snow, cold: rain icon → snow icon.
        XCTAssertEqual(ForecastBlender.precipitationType(63, snowfall: 7, precipitation: 10, temperature: -1), 73)
        XCTAssertEqual(ForecastBlender.precipitationType(80, snowfall: 2, precipitation: 2.5, temperature: 0), 85)
        // Mostly rain: stays rain; snow icon with no snow and above freezing → rain.
        XCTAssertEqual(ForecastBlender.precipitationType(61, snowfall: 0.5, precipitation: 5, temperature: 1), 61)
        XCTAssertEqual(ForecastBlender.precipitationType(73, snowfall: 0, precipitation: 4, temperature: 1.5), 63)
        // Too warm for snow even if a model says so; thunder untouched; dry untouched.
        XCTAssertEqual(ForecastBlender.precipitationType(61, snowfall: 7, precipitation: 10, temperature: 5), 61)
        XCTAssertEqual(ForecastBlender.precipitationType(95, snowfall: 7, precipitation: 10, temperature: -2), 95)
        XCTAssertEqual(ForecastBlender.precipitationType(3, snowfall: nil, precipitation: nil, temperature: -2), 3)
    }

    func testSnowIsRequestedBlendedAndShown() throws {
        let url = Endpoints.openMeteoForecast(nyc.coordinate, models: [.bestMatch]).absoluteString
        XCTAssertTrue(url.contains("snowfall") && url.contains("snowfall_sum"))
        let days = (0..<2).map { Double($0) * 86400 + 1_790_000_000 }
        let hours = (0..<3).map { 1_790_000_000 + Double($0) * 3600 }
        let json = """
        {"latitude":44,"longitude":-73,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":\(days),"weather_code_ecmwf_ifs025":[61,3],"weather_code_icon_seamless":[61,3],
                  "temperature_2m_max_ecmwf_ifs025":[0,5],"temperature_2m_min_ecmwf_ifs025":[-4,0],
                  "temperature_2m_max_icon_seamless":[0,5],"temperature_2m_min_icon_seamless":[-4,0],
                  "precipitation_probability_max_ecmwf_ifs025":[90,0],"precipitation_probability_max_icon_seamless":[90,0],
                  "precipitation_sum_ecmwf_ifs025":[12,0],"precipitation_sum_icon_seamless":[8,0],
                  "snowfall_sum_ecmwf_ifs025":[8.4,0],"snowfall_sum_icon_seamless":[5.6,0]},
         "hourly":{"time":\(hours),"temperature_2m_ecmwf_ifs025":[-2,-2,-2],"temperature_2m_icon_seamless":[-2,-2,-2],
                   "weather_code_ecmwf_ifs025":[63,63,63],"weather_code_icon_seamless":[63,63,63],
                   "precipitation_probability_ecmwf_ifs025":[90,90,90],"precipitation_probability_icon_seamless":[90,90,90],
                   "precipitation_ecmwf_ifs025":[2,2,2],"precipitation_icon_seamless":[2,2,2],
                   "snowfall_ecmwf_ifs025":[1.4,1.4,1.4],"snowfall_icon_seamless":[1.4,1.4,1.4]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let h = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: Date(timeIntervalSince1970: hours[0] - 3600))
        XCTAssertEqual(h.first?.snowfall ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(h.first?.condition.category, .snow)
        let d = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(d[0].snowfallSum ?? 0, wmean([(8.4, 1.5), (5.6, 1.0)]), accuracy: 1e-6)
        XCTAssertTrue(d[0].hasSnow)
        XCTAssertEqual(d[0].condition.category, .snow)
        XCTAssertFalse(d[1].hasSnow)
        let imperial = DisplayUnits.imperial, metric = DisplayUnits.metric
        XCTAssertEqual(imperial.snowString(1), "0.4 in")
        XCTAssertEqual(imperial.snowString(7.6), "3 in")
        XCTAssertEqual(metric.snowString(1.5), "1.5 cm")
        XCTAssertEqual(metric.snowString(12.4), "12 cm")
    }

    // MARK: L20 SPC outlook

    func testSPCOutlookPicksTheHighestCategoryAtThePoint() throws {
        let data = try Fixture.data("spc_day1_test")
        XCTAssertEqual(try SPCOutlookParser.outlook(data, day: 1, point: Coordinate(latitude: 35, longitude: -90))?.risk, .slight)
        // Inside the hole of the slight-risk polygon: marginal.
        XCTAssertEqual(try SPCOutlookParser.outlook(data, day: 1, point: Coordinate(latitude: 36.5, longitude: -90))?.risk, .marginal)
        XCTAssertEqual(try SPCOutlookParser.outlook(data, day: 1, point: Coordinate(latitude: 31, longitude: -99))?.risk, .thunder)
        XCTAssertNil(try SPCOutlookParser.outlook(data, day: 1, point: Coordinate(latitude: 47, longitude: -120)))
        let o = try XCTUnwrap(SPCOutlookParser.outlook(data, day: 1, point: Coordinate(latitude: 35, longitude: -90)))
        XCTAssertEqual(o.validUntil, ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z"))
        XCTAssertEqual(o.sentence(now: fixtureTime, timeZone: ny), "Slight risk of severe storms today (level 2 of 5)")
        XCTAssertEqual(o.sentence(now: fixtureTime.addingTimeInterval(9 * 3600), timeZone: ny), "Slight risk of severe storms tonight (level 2 of 5)")
        XCTAssertFalse(SevereOutlook(day: 1, risk: .thunder, validFrom: fixtureTime, validUntil: fixtureTime).isSevere)
        // The real SPC file (Oct 12 01Z) decodes.
        XCTAssertNoThrow(try SPCOutlookParser.outlook(try Fixture.data("spc_day1_live"), day: 1, point: nyc.coordinate))
    }

    // MARK: T12 future radar, L21 rainfall totals, L7

    func testHRRRFutureFramesAfterTheLatestScan() {
        let iso = ISO8601DateFormatter()
        let initTime = iso.date(from: "2026-10-11T23:00:00Z")!
        let latest = iso.date(from: "2026-10-12T01:25:00Z")!
        let frames = IEMHRRR.frames(initTime: initTime, after: latest)
        XCTAssertEqual(frames.map { iso.string(from: $0.time) },
                       ["2026-10-12T01:30:00Z", "2026-10-12T01:45:00Z", "2026-10-12T02:00:00Z", "2026-10-12T02:15:00Z",
                        "2026-10-12T02:45:00Z", "2026-10-12T03:15:00Z"])
        XCTAssertTrue(frames.allSatisfy(\.isForecast))
        XCTAssertEqual(frames.first?.urlTemplate, "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::REFD-F0150-202610112300/{z}/{x}/{y}.png")
        // A run too old to reach (past 18 h) gives nothing rather than wrong frames.
        XCTAssertTrue(IEMHRRR.frames(initTime: initTime.addingTimeInterval(-24 * 3600), after: latest).isEmpty)
        XCTAssertEqual(try IEMHRRR.initTime(Data(#"{"model_init_utc": "2026-10-11T23:00:00Z", "forecast_minute": 0.0}"#.utf8)), initTime)
    }

    func testServiceAppendsFutureFramesOnlyWhenAsked() async throws {
        final class IEM: HTTPClient, @unchecked Sendable {
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                if url.absoluteString.contains("hrrr/refd_0000.json") { return Data(#"{"model_init_utc": "2026-10-11T23:00:00Z"}"#.utf8) }
                return Data(#"{"meta": {"valid": "2026-10-12T01:25:00Z"}}"#.utf8)
            }
        }
        let service = WeatherService(client: IEM(), cache: ResponseCache(directory: nil))
        let past = try await service.radarFrames(.nexrad, range: .oneHour)
        let all = try await service.radarFrames(.nexrad, range: .oneHour, future: true)
        XCTAssertEqual(past.count, 11)
        XCTAssertEqual(all.count, 17)
        XCTAssertEqual(Array(all.prefix(11)), past)
        XCTAssertFalse(past.contains(where: \.isForecast))
    }

    func testRainfallTotalFramesAndNowcastFlag() throws {
        let f = try XCTUnwrap(IEMMRMS.frame(.rain24h, now: Date(timeIntervalSince1970: 1_791_725_999)))
        XCTAssertEqual(f.urlTemplate, "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/q2-p24h/{z}/{x}/{y}.png?v=1791725400")
        XCTAssertEqual(IEMMRMS.frame(.rain1h, now: fixtureTime)?.urlTemplate.contains("q2-n1p"), true)
        XCTAssertNil(IEMMRMS.frame(.reflectivity, now: fixtureTime))
        XCTAssertTrue(RadarLayer.rain1h.isRainfallTotal)
        let rv = #"{"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":100,"path":"/a"}],"nowcast":[{"time":700,"path":"/b"}]}}"#
        let frames = try RainViewerParser.decode(Data(rv.utf8))
        XCTAssertEqual(frames.map(\.isForecast), [false, true])
    }

    func testOlderRadarIndexAnswerIsDropped() {
        var g = RequestGeneration()
        let first = g.next(), second = g.next()
        XCTAssertFalse(g.isCurrent(first), "the slower, older answer is ignored")
        XCTAssertTrue(g.isCurrent(second))
    }

    // MARK: L18 model comparison

    func testModelSeriesFoldsACopiedBestMatch() throws {
        let t = 1_790_000_000.0
        let times = (0..<4).map { t + Double($0) * 3600 }
        let json = """
        {"latitude":40,"longitude":-74,"timezone":"UTC","utc_offset_seconds":0,
         "hourly":{"time":\(times),"temperature_2m_best_match":[10.0,11,12,13],"temperature_2m_gfs_seamless":[10.0,11,12,13],
                   "temperature_2m_ecmwf_ifs025":[9.0,9,9,9]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let now = Date(timeIntervalSince1970: t)
        let blended = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now)
        let s = ForecastBlender.modelSeries(openMeteo: om, nwsHourly: [], blended: blended, now: now)
        XCTAssertEqual(s.map(\.name), ["ECMWF IFS", "NOAA GFS = Best Match", "Skyline blend"])
        XCTAssertEqual(s.last?.isBlend, true)
        XCTAssertEqual(ModelSeries.spread(s).first?.spread ?? 0, 1, accuracy: 1e-9)
    }
}
