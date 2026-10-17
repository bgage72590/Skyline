import XCTest
@testable import SkylineCore

/// Dropdown review fixes (Oct 17; PM, UI/UX, code review and QA reports). The fixture is QA's
/// screenshot-shaped report: Fairfield, 7:58 PM EDT, "Rain" in the header, a wet quarter that ended at
/// 7:45, dry nowcast after, hourly 8 PM 80 %, 9 PM 36 %, 10 PM 53 %, 11 PM 46 %, then dry.
final class DropdownFixTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!
    let now = Date(timeIntervalSince1970: 1_792_195_080)   // 19:58 EDT
    let top = Date(timeIntervalSince1970: 1_792_195_200)   // 20:00 EDT
    let imperial = DisplayUnits.imperial

    func label(_ d: Date) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h a"
        return f.string(from: d)
    }

    func hour(_ offset: Int, code: Int, pop: Double, precip: Double = 0, tempF: Double = 65) -> HourlyForecast {
        HourlyForecast(time: top.addingTimeInterval(Double(offset) * 3600), temperature: fToC(tempF),
                       precipitationProbability: pop, precipitation: precip, weatherCode: code, isDay: false)
    }

    func screenshot(code: Int = 63, minutely mm: [Double]? = nil) -> WeatherReport {
        let loc = WeatherLocation(name: "Fairfield", coordinate: Coordinate(latitude: 41.1468, longitude: -73.2492),
                                  timeZoneIdentifier: "America/New_York", isCurrentLocation: true)
        let current = CurrentConditions(time: now.addingTimeInterval(-13 * 60), temperature: fToC(67), apparentTemperature: fToC(68),
                                        humidity: 91, dewPoint: fToC(62), weatherCode: code, isDay: false, precipitation: 0.3,
                                        cloudCover: 100, pressure: 1005.8, windSpeed: 11, windDirection: 250, windGust: nil,
                                        visibility: nil, uvIndex: 0)
        let hourly = [hour(-1, code: 63, pop: 90, precip: 2), hour(0, code: 63, pop: 80, precip: 3),
                      hour(1, code: 3, pop: 36), hour(2, code: 3, pop: 53, precip: 0.1), hour(3, code: 3, pop: 46, precip: 0.1),
                      hour(4, code: 2, pop: 12), hour(5, code: 3, pop: 15, precip: 0.1), hour(6, code: 3, pop: 10)]
        let day0 = DailyForecast(date: top.addingTimeInterval(-20 * 3600), weatherCode: 61, high: fToC(70), low: fToC(53))
        let day1 = DailyForecast(date: top.addingTimeInterval(4 * 3600), weatherCode: 3, high: fToC(57), low: fToC(43))
        let q0 = Date(timeIntervalSince1970: 1_792_194_300) // quarter ending 19:45
        let values = mm ?? (0...10).map { $0 == 0 ? 0.6 : 0 }
        let minutely = values.enumerated().map { MinutelyPrecipitation(time: q0.addingTimeInterval(Double($0.offset) * 900), precipitation: $0.element) }
        return WeatherReport(location: loc, fetchedAt: now.addingTimeInterval(-20 * 60), timeZoneIdentifier: "America/New_York",
                             current: current, hourly: hourly, daily: [day0, day1], minutely: minutely,
                             dataAsOf: now.addingTimeInterval(-20 * 60))
    }

    func headline(_ r: WeatherReport, at t: Date? = nil, includeRain: Bool = true) -> String {
        Briefing.headline(r, now: t ?? now, hourLabel: label, delta: { Int(($0 * 9 / 5).rounded()) }, includeRain: includeRain)
    }

    // MARK: One rain-timing rule

    func testHeadlineAndCardNeverDisagree() {
        let base = screenshot()
        for code in [63, 3] {
            var r = base; r.current.weatherCode = code
            for minutes in Swift.stride(from: -120, through: 180, by: 7) {
                let t = now.addingTimeInterval(Double(minutes) * 60)
                guard let card = MenuSummary.rainTiming(r, now: t, hourLabel: label) else { continue }
                let h = headline(r, at: t)
                if RainTiming.next(r, now: t)?.isRain == true {
                    XCTAssertTrue(h.hasPrefix(card + "."), "\(minutes) min: \(h) vs \(card)")
                }
                XCTAssertEqual(MenuSummary.radarForecastLine(r, now: t, hourLabel: label), card)
            }
        }
    }

    func testScreenshotNowSaysOneThing() {
        // Header still says Rain (as on the screenshot): the nowcast has two dry hours ahead → "ending soon",
        // never the hourly "8 PM" vs "12 AM" pair.
        let r = screenshot()
        XCTAssertEqual(MenuSummary.rainTiming(r, now: now, hourLabel: label), "Rain ending soon")
        XCTAssertTrue(headline(r).hasPrefix("Rain ending soon."), headline(r))
        // With the header reconciled to the nowcast (cloudy now), hours inside the nowcast's 2 hours are
        // the nowcast's call; the first likely hour after that is the 11 PM column.
        let code = Nowcast.reconcileCurrent(code: 63, minutely: r.minutely, now: now, temperature: r.current.temperature)
        XCTAssertEqual(code, 3)
        let dry = screenshot(code: code)
        XCTAssertEqual(MenuSummary.rainTiming(dry, now: now, hourLabel: label), "Rain likely around 11 PM (46%)")
    }

    func testRainEndsOnlyAfterTwoDryHoursAndIsNamedByTheLastWetColumn() {
        // No nowcast: the hourly rule alone. 9 PM (36 %) is a lull before 53 %, not the end; 12 AM and 1 AM
        // are dry, so the last wet column is 11 PM.
        let r = screenshot(minutely: [])
        XCTAssertEqual(MenuSummary.rainTiming(r, now: now, hourLabel: label), "Rain ending around 11 PM")
        XCTAssertTrue(headline(r).hasPrefix("Rain ending around 11 PM."))
        // A lone dry hour followed by rain again: still continuing.
        var lull = r
        lull.hourly[5] = hour(4, code: 2, pop: 12)
        lull.hourly[6] = hour(5, code: 61, pop: 60, precip: 1)
        lull.hourly[7] = hour(6, code: 61, pop: 60, precip: 1)
        XCTAssertEqual(MenuSummary.rainTiming(lull, now: now, hourLabel: label), "Rain continuing for the next 12 hours")
    }

    func testDropdownHeadlineLeavesTheRainLineToTheCard() {
        let r = screenshot(minutely: [])
        let h = headline(r, includeRain: false)
        XCTAssertFalse(h.contains("Rain"), h)
        XCTAssertTrue(h.contains("Tomorrow is 13° cooler."), h)
        // No rain at all: the sky sentence stays.
        var dry = r
        dry.current.weatherCode = 3
        for i in dry.hourly.indices { dry.hourly[i].precipitationProbability = 0; dry.hourly[i].weatherCode = 3 }
        XCTAssertTrue(headline(dry, includeRain: false).hasPrefix("Overcast for the next 12 hours.") ||
                      headline(dry, includeRain: false).hasPrefix(WeatherCondition(wmoCode: 3).description))
    }

    // MARK: Chart only when the slots ahead are wet

    func testChartNeedsWetQuartersAhead() {
        XCTAssertFalse(Briefing.rainDueSoon(screenshot(), now: now), "the wet quarter ended 13 min ago")
        // The quarter under way is wet.
        XCTAssertTrue(Briefing.rainDueSoon(screenshot(minutely: [0, 0.4, 0.3, 0, 0, 0, 0, 0, 0, 0, 0]), now: now))
        // A single light blip ahead: no line, no chart.
        XCTAssertFalse(Briefing.rainDueSoon(screenshot(minutely: [0, 0, 0, 0.12, 0, 0, 0, 0, 0, 0, 0]), now: now))
        // Sustained rain starting in about 45 min.
        XCTAssertTrue(Briefing.rainDueSoon(screenshot(minutely: [0, 0, 0, 0.3, 0.4, 0, 0, 0, 0, 0, 0]), now: now))
        // Rain starting after 2 h: not on a 2-hour chart.
        XCTAssertFalse(Briefing.rainDueSoon(screenshot(minutely: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5]), now: now))
    }

    // MARK: % whenever there's a rain icon, one cutoff

    func testPercentAlwaysShownWithARainIcon() {
        XCTAssertEqual(ForecastBlender.reconcile(code: 61, precipitationProbability: 15, precipitation: 0.1, temperature: 10), 3,
                       "QA 1 AM: rain icon at 15 % → cloudy")
        XCTAssertEqual(HourlyDisplay.popText(hour(0, code: 3, pop: 36)), "36%")
        XCTAssertNil(HourlyDisplay.popText(hour(0, code: 2, pop: 12)))
        XCTAssertEqual(HourlyDisplay.popText(hour(0, code: 61, pop: 12)), "12%", "a rain icon always gets its number")
        // Exhaustive: after reconcile, a precipitation icon always comes with a printed %.
        for code in [51, 61, 63, 65, 71, 80, 95, 3, 2] {
            for pop in Swift.stride(from: 0.0, through: 100, by: 2.5) {
                for amount in [0.0, 0.04, 0.1, 0.5, 3] {
                    let c = ForecastBlender.reconcile(code: code, precipitationProbability: pop, precipitation: amount, temperature: 10)
                    if WeatherCondition(wmoCode: c).isPrecipitation {
                        XCTAssertGreaterThanOrEqual(Int(pop.rounded()), HourlyDisplay.popCutoff, "code \(code) pop \(pop) mm \(amount)")
                    }
                }
            }
        }
        // Daily rows use the same rule.
        var day = DailyForecast(date: now, weatherCode: 3, high: 20, low: 10)
        day.precipitationProbability = 45
        XCTAssertEqual(HourlyDisplay.popText(day), "45%")
        day.precipitationProbability = 10
        XCTAssertNil(HourlyDisplay.popText(day))
        day.precipitationProbability = nil
        XCTAssertNil(HourlyDisplay.popText(day))
    }

    // MARK: Severe risk row

    func testSevereRowAtLevelTwoAndAbove() {
        var r = screenshot()
        let from = now.addingTimeInterval(-6 * 3600), until = now.addingTimeInterval(10 * 3600)
        r.severeOutlooks = [SevereOutlook(day: 1, risk: .slight, validFrom: from, validUntil: until)]
        XCTAssertEqual(MenuSummary.severeRow(r, now: now), "Severe storms possible tonight · level 2 of 5")
        XCTAssertFalse(Briefing.headline(r, now: now, hourLabel: label, delta: { Int($0) }, includeSevere: false).contains("severe"))
        r.severeOutlooks = [SevereOutlook(day: 1, risk: .marginal, validFrom: from, validUntil: until)]
        XCTAssertNil(MenuSummary.severeRow(r, now: now), "level 1 stays in the sentence only")
        r.severeOutlooks = [SevereOutlook(day: 1, risk: .enhanced, validFrom: from, validUntil: now.addingTimeInterval(-1))]
        XCTAssertNil(MenuSummary.severeRow(r, now: now), "expired")
        r.severeOutlooks = [SevereOutlook(day: 2, risk: .moderate, validFrom: until, validUntil: until.addingTimeInterval(86400))]
        XCTAssertNil(MenuSummary.severeRow(r, now: now), "day 2 isn't in force")
        // The sentence wording is unchanged.
        let o = SevereOutlook(day: 1, risk: .slight, validFrom: from, validUntil: until)
        XCTAssertEqual(o.sentence(now: now, timeZone: tz), "Slight risk of severe storms tonight (level 2 of 5)")
    }

    // MARK: Header condition vs the nowcast

    func testHeaderConditionFollowsTheNowcast() {
        let wet = (0...4).map { MinutelyPrecipitation(time: top.addingTimeInterval(Double($0) * 900), precipitation: 0.4) }
        let dry = wet.map { MinutelyPrecipitation(time: $0.time, precipitation: 0) }
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 63, minutely: dry, now: now, temperature: 18), 3)
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 3, minutely: wet, now: now, temperature: 18), 61)
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 3, minutely: wet, now: now, temperature: -2), 71)
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 63, minutely: wet, now: now, temperature: 18), 63)
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 45, minutely: wet, now: now, temperature: 18), 45, "fog left alone")
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 63, minutely: [], now: now, temperature: 18), 63, "no nowcast: unchanged")
        // One dry quarter then rain again: still raining.
        var mixed = dry; mixed[1].precipitation = 0.4
        XCTAssertEqual(Nowcast.reconcileCurrent(code: 63, minutely: mixed, now: now, temperature: 18), 63)
    }

    // MARK: Refresh on open, ages, gust, feels like

    func testRefreshOnOpenWhileRaining() {
        var r = screenshot(minutely: [0, 0.4, 0.4, 0, 0, 0, 0, 0, 0, 0, 0])
        r.dataAsOf = now.addingTimeInterval(-6 * 60)
        XCTAssertTrue(MenuSummary.refreshOnOpen(r, now: now))
        r.dataAsOf = now.addingTimeInterval(-3 * 60)
        XCTAssertFalse(MenuSummary.refreshOnOpen(r, now: now), "fresh enough")
        var dry = screenshot(code: 3, minutely: Array(repeating: 0, count: 11))
        dry.dataAsOf = now.addingTimeInterval(-25 * 60)
        XCTAssertFalse(MenuSummary.refreshOnOpen(dry, now: now), "not raining: the normal guard applies")
    }

    func testOtherCityAge() {
        var r = screenshot()
        r.dataAsOf = now.addingTimeInterval(-10 * 60)
        XCTAssertNil(MenuSummary.rowAge(r, now: now, staleAfter: 30 * 60))
        r.dataAsOf = now.addingTimeInterval(-45 * 60)
        XCTAssertEqual(MenuSummary.rowAge(r, now: now, staleAfter: 30 * 60), "45 min")
        r.dataAsOf = now.addingTimeInterval(-150 * 60)
        XCTAssertEqual(MenuSummary.rowAge(r, now: now, staleAfter: 30 * 60), "2 h")
    }

    func testGustIsLabelledAsThePeak() {
        XCTAssertEqual(MenuSummary.gustCaption("29 mph"), "24-h peak gust 29 mph")
    }

    func testFeelsLikeOnlyWhenThreeDegreesOff() {
        XCTAssertNil(MenuSummary.feelsLikeText(temperature: fToC(67.4), apparent: fToC(67.6), units: imperial), "67° vs 68° was noise")
        XCTAssertNil(MenuSummary.feelsLikeText(temperature: fToC(67), apparent: fToC(69.9), units: imperial))
        XCTAssertEqual(MenuSummary.feelsLikeText(temperature: fToC(67), apparent: fToC(72), units: imperial), "Feels like 72°")
        XCTAssertEqual(MenuSummary.feelsLikeText(temperature: fToC(40), apparent: fToC(33), units: imperial), "Feels like 33°")
        let metric = DisplayUnits.metric
        XCTAssertNil(MenuSummary.feelsLikeText(temperature: 20, apparent: 22.9, units: metric))
        XCTAssertEqual(MenuSummary.feelsLikeText(temperature: 20, apparent: 23, units: metric), "Feels like 23°")
    }
}
