import XCTest
@testable import SkylineCore

/// Batch 3 (daily-use basics) regression tests.
final class Batch3Tests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    // MARK: T20 mixed units and 24-hour time

    func testPresetsMatchTheOldSingleSwitch() {
        XCTAssertEqual(DisplayUnits(preset: .imperial), .imperial)
        XCTAssertEqual(DisplayUnits(preset: .metric), .metric)
        XCTAssertEqual(DisplayUnits(preset: .system, locale: us), .imperial)
        XCTAssertEqual(DisplayUnits(preset: .system, locale: Locale(identifier: "de_DE")), .metric)
        // The preset shorthand still formats exactly as before.
        XCTAssertEqual(UnitPreference.imperial.temperatureString(0), "32°")
        XCTAssertEqual(DisplayUnits.imperial.temperatureString(0, withUnit: true), "32°F")
        XCTAssertEqual(DisplayUnits.metric.temperatureString(0, withUnit: true), "0°C")
        XCTAssertEqual(DisplayUnits.imperial.temperatureString(nil, withUnit: true), "--")
        // A per-dimension override wins: °C on an otherwise imperial preset.
        XCTAssertEqual(DisplayUnits(preset: .imperial, temperature: .celsius).temperatureString(0, withUnit: true), "0°C")
        XCTAssertEqual(UnitPreference.imperial.pressureString(1013.25), "29.92 inHg")
        XCTAssertEqual(UnitPreference.metric.pressureString(1013.25), "1013 hPa")
    }

    func testMixedUnitsFahrenheitWithHectopascals() {
        let u = DisplayUnits(preset: .imperial, pressure: .hPa)
        XCTAssertEqual(u.temperatureString(20), "68°")
        XCTAssertEqual(u.pressureString(1013.25), "1013 hPa")
        XCTAssertEqual(u.pressureNumber(1013.25), "1013")
        XCTAssertEqual(u.speedString(16.09344), "10 mph")
        XCTAssertEqual(u.precipitationString(25.4), "1.00\"")
        XCTAssertEqual(u.pressureStep, 6)

        let m = DisplayUnits(preset: .metric, temperature: .fahrenheit, speed: .knots, distance: .miles)
        XCTAssertEqual(m.temperatureString(0), "32°")
        XCTAssertEqual(m.speedString(18.52), "10 kn")
        XCTAssertEqual(m.precipitationString(2.54), "2.5 mm")
        XCTAssertEqual(m.visibilityString(16093.44), "10 mi")
        XCTAssertEqual(m.pressureString(1013.25), "1013 hPa")
        XCTAssertEqual(DisplayUnits(preset: .metric, speed: .metresPerSecond).speedString(36), "10 m/s")
        XCTAssertEqual(DisplayUnits(preset: .metric, temperature: .fahrenheit).temperatureDelta(5), 9, accuracy: 1e-9)
    }

    func testClockStyleRewritesHourSymbol() {
        XCTAssertEqual(ClockStyle.system.template("jmm"), "jmm")
        XCTAssertEqual(ClockStyle.twelveHour.template("EEEjmm"), "EEEhmm")
        XCTAssertEqual(ClockStyle.twentyFourHour.template("jmm"), "Hmm")
        XCTAssertEqual(ClockStyle.twentyFourHour.template("j"), "H")

        // And the formatter really produces 24-hour / 12-hour text with the rewritten template.
        let date = Date(timeIntervalSince1970: 1_760_212_920) // 2025-10-11 20:02 UTC
        func format(_ style: ClockStyle) -> String {
            let f = DateFormatter()
            f.locale = us
            f.timeZone = TimeZone(identifier: "UTC")
            f.setLocalizedDateFormatFromTemplate(style.template("jmm"))
            return f.string(from: date)
        }
        XCTAssertEqual(format(.twentyFourHour), "20:02")
        XCTAssertTrue(format(.twelveHour).hasPrefix("8:02"), format(.twelveHour))
    }

    // MARK: T9 plain-English scorecard

    private func score(_ s: VerificationSource, mae: Double, n: Double = 200, hits: Double = 0, misses: Double = 0,
                       fa: Double = 0, cn: Double = 0) -> SourceScore {
        var x = SourceScore(source: s)
        x.tempN = n; x.tempAbs = mae * n
        x.hits = hits; x.misses = misses; x.falseAlarms = fa; x.correctNegatives = cn
        return x
    }

    private func report(status: AccuracyReport.Status, days: Double, pairs: Int,
                        _ scores: [SourceScore]) -> AccuracyReport {
        AccuracyReport(status: status, daysCollected: days, verifiedPairs: pairs, pendingForecasts: 0,
                       stationID: "KBDR", stationName: "Bridgeport", overall: Dictionary(uniqueKeysWithValues: scores.map { ($0.source, $0) }),
                       byBucket: [:], recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
    }

    private let f: (Double) -> String = { String(format: "%.1f°F", $0 * 9 / 5) }

    func testScorecardHeadlineReady() {
        let r = report(status: .ready, days: 14.2, pairs: 2000, [
            score(.blend, mae: 1.0, hits: 41, misses: 7, fa: 9, cn: 263),
            score(.hrrr, mae: 1.2), score(.gfs, mae: 1.9),
        ])
        let text = AccuracySummary.headline(r, delta: f)
        XCTAssertEqual(text, "Over 14 days of checks, Skyline’s temperatures were off by 1.8°F on average, as good as or better than any single model (best: HRRR, 2.2°F). Rain calls were right 95% of the time (41 of 48 rainy hours caught).")
        XCTAssertFalse(text.contains("MAE") || text.contains("Brier"))
    }

    func testScorecardSaysWhenAModelBeatsTheBlend() {
        let r = report(status: .ready, days: 5, pairs: 500, [score(.blend, mae: 1.5), score(.nws, mae: 1.0)])
        let text = AccuracySummary.headline(r, delta: f)
        XCTAssertTrue(text.contains("NWS alone did slightly better here (1.8°F)"), text)
        XCTAssertTrue(text.contains("off by 2.7°F"), text)
    }

    func testScorecardWhileCollecting() {
        let none = report(status: .collecting, days: 0.2, pairs: 0, [])
        XCTAssertTrue(AccuracySummary.headline(none, delta: f).hasPrefix("Skyline is checking its forecasts"))
        let early = report(status: .collecting, days: 0.5, pairs: 12, [score(.blend, mae: 1.0, n: 12)])
        XCTAssertEqual(AccuracySummary.headline(early, delta: f),
                       "Early numbers (the first day): Skyline’s temperatures have been off by about 1.8°F on average.")
    }

    // MARK: UI/UX #8, #18 repeated and clipped text

    func testSentenceSplitKeepsDecimalsAndTimes() {
        XCTAssertEqual(TextTidy.sentences("Rain. Cloudy, with a high near 61. Chance of precipitation is 90%."),
                       ["Rain.", "Cloudy, with a high near 61.", "Chance of precipitation is 90%."])
        XCTAssertEqual(TextTidy.sentences("Up to 0.5 in of rain possible. Windy."),
                       ["Up to 0.5 in of rain possible.", "Windy."])
        XCTAssertEqual(TextTidy.sentences("Showers likely before 11 a.m. then cloudy. Breezy."),
                       ["Showers likely before 11 a.m. then cloudy.", "Breezy."])
        XCTAssertEqual(TextTidy.sentences("Rain until 11 a.m. Then sunny"), ["Rain until 11 a.m.", "Then sunny"])
    }

    func testHourlyHeadlineIsWholeSentencesOrNothing() {
        // The old split(".") produced "Rain. Cloudy." style fragments and broke "0.5".
        XCTAssertEqual(TextTidy.hourlyHeadline(summary: "Up to 0.5 in of rain, mainly before 2pm. Cloudy. Low 50.", nowcast: nil),
                       "Up to 0.5 in of rain, mainly before 2pm. Cloudy.")
        XCTAssertNil(TextTidy.hourlyHeadline(summary: "Rain.", nowcast: nil), "too short to say anything")
        XCTAssertEqual(TextTidy.hourlyHeadline(summary: "Rain.", nowcast: "Rain continuing for the next 2 hours"),
                       "Rain continuing for the next 2 hours.")
    }

    func testAlertSubtitleSkipsHeadlineThatRestatesTheEvent() {
        let desc = "* WHAT...Up to one half foot of inundation above ground level in low-lying areas near shorelines.\n\n* WHERE...Southern Fairfield County."
        XCTAssertEqual(TextTidy.alertSubtitle(event: "Coastal Flood Statement",
                                              headline: "Coastal Flood Statement issued October 11 at 4:46PM EDT until October 12 at 1:00PM EDT by NWS Upton NY",
                                              description: desc),
                       "Up to one half foot of inundation above ground level in low-lying areas near shorelines.")
        XCTAssertEqual(TextTidy.alertSubtitle(event: "Flood Advisory", headline: "Minor flooding of roads expected", description: desc),
                       "Minor flooding of roads expected")
        XCTAssertNil(TextTidy.alertSubtitle(event: "X", headline: "X issued", description: nil))
    }

    func testNowcastRepeatDetection() {
        let briefing = "Rain continuing for the next 2 hours. Tomorrow is 9° warmer."
        XCTAssertTrue(TextTidy.isRepeated("Rain continuing for the next 2 hours", in: briefing))
        XCTAssertFalse(TextTidy.isRepeated("Rain starting in 20 min", in: briefing))
        XCTAssertFalse(TextTidy.isRepeated(nil, in: briefing))
    }

    // MARK: T10 menu-bar city, T19 reorder / undo

    private func loc(_ name: String) -> WeatherLocation {
        WeatherLocation(name: name, coordinate: Coordinate(latitude: Double(name.count), longitude: -70))
    }

    func testMenuBarLocationNoLongerFollowsSelection() {
        let a = loc("Boston"), b = loc("Fairfield")
        let me = WeatherLocation(id: WeatherLocation.currentLocationID, name: "My Location",
                                 coordinate: Coordinate(latitude: 41, longitude: -73), isCurrentLocation: true)
        XCTAssertEqual(LocationList.menuBarLocation(current: nil, saved: [a, b], pinnedID: nil)?.id, a.id)
        XCTAssertEqual(LocationList.menuBarLocation(current: me, saved: [a, b], pinnedID: nil)?.id, me.id)
        XCTAssertEqual(LocationList.menuBarLocation(current: me, saved: [a, b], pinnedID: b.id)?.id, b.id)
        // A pinned city that was removed falls back.
        XCTAssertEqual(LocationList.menuBarLocation(current: me, saved: [a], pinnedID: b.id)?.id, me.id)
        // Pinned to My Location while location is off: first saved city.
        XCTAssertEqual(LocationList.menuBarLocation(current: nil, saved: [a, b], pinnedID: WeatherLocation.currentLocationID)?.id, a.id)
    }

    func testDragReorderMatchesOnMoveSemantics() {
        let list = ["A", "B", "C", "D"]
        XCTAssertEqual(LocationList.moving(list, fromOffsets: [0], toOffset: 3), ["B", "C", "A", "D"])
        XCTAssertEqual(LocationList.moving(list, fromOffsets: [3], toOffset: 0), ["D", "A", "B", "C"])
        XCTAssertEqual(LocationList.moving(list, fromOffsets: [1], toOffset: 4), ["A", "C", "D", "B"])
        XCTAssertEqual(LocationList.moving(list, fromOffsets: [0, 2], toOffset: 4), ["B", "D", "A", "C"])
        XCTAssertEqual(LocationList.moving(list, fromOffsets: [2], toOffset: 2), list)
    }

    func testUndoDeleteRestoresPosition() {
        let a = loc("A"), b = loc("Bb"), c = loc("Ccc")
        XCTAssertEqual(LocationList.restoring(b, at: 1, into: [a, c]).map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(LocationList.restoring(b, at: 9, into: [a, c]).map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(LocationList.restoring(a, at: 0, into: [a, c]).map(\.id), [a.id, c.id], "no duplicates")
    }

    // MARK: T6 pale text

    func testWhiteTextReadableOnEverySky() {
        for category in SkyCategory.allCases {
            for isDay in [true, false] {
                let s = SkyColors.stops(category, isDay: isDay)
                let name = "\(category) day=\(isDay)"
                // Dropdown: whole gradient under a black wash.
                for stop in s {
                    XCTAssertGreaterThanOrEqual(SkyColors.whiteContrast(on: SkyColors.darkened(stop, by: SkyColors.dropdownScrim)), 4.5, name)
                }
                // Sidebar card (selected or not): card wash everywhere, plus the bottom scrim toward the bottom.
                let top = SkyColors.darkened(s[0], by: SkyColors.cardScrim)
                let mid = SkyColors.darkened(SkyColors.mix(s[0], s[1], 0.5), by: SkyColors.cardScrim)
                let bottom = SkyColors.darkened(SkyColors.darkened(s[1], by: SkyColors.cardScrim), by: SkyColors.cardBottomScrim)
                for bg in [top, mid, bottom] {
                    XCTAssertGreaterThanOrEqual(SkyColors.whiteContrast(on: bg), 4.5, name)
                }
            }
        }
        // The old snow-day dropdown bottom was ~1.5:1.
        XCTAssertLessThan(SkyColors.whiteContrast(on: (0.78, 0.83, 0.90)), 2)
    }

    // MARK: Code Reviewer M1 (batch 1/2): learn weights from full records

    /// best_match is exactly as good as HRRR (identical on 80 % of hours; both miss by 3 °C on the rest).
    /// Records are stored whole and weights learned from them, so equal skill gets equal weight; only the
    /// Accuracy screen shows the de-duplicated "one model, one row" view. (Reviewer's case: the shipped
    /// code gave HRRR 1.26× and best_match 0.86×.)
    func testEqualSkillFamilyMemberIsNotPenalized() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var raw: [VerifiedRecord] = []
        for day in 0..<8 {
            for h in 0..<20 {
                let valid = t0.addingTimeInterval(Double(day) * 86400 + Double(h) * 3600)
                let hard = h % 5 == 0
                let f: [String: SourceValues] = [
                    VerificationSource.hrrr.rawValue: SourceValues(t: hard ? 13 : 11, pop: 40),
                    VerificationSource.bestMatch.rawValue: SourceValues(t: hard ? 7 : 11),
                    VerificationSource.ecmwf.rawValue: SourceValues(t: hard ? 13 : 11.5),
                ]
                // What ForecastSampler stores now: every member kept, only HRRR's borrowed probability removed.
                let stored = ForecastRecord(loc: "x", issued: valid.addingTimeInterval(-3 * 3600), valid: valid, f: f)
                    .dedupingNOAAFamily(dropDuplicates: false)
                XCTAssertNotNil(stored.values(.bestMatch)?.t)
                XCTAssertNil(stored.values(.hrrr)?.pop)
                raw.append(VerifiedRecord(stored, ObservedHour(t: 10)))
            }
        }
        let now = t0.addingTimeInterval(9 * 86400)
        let w = AdaptiveWeighting.weights(from: AccuracyScorer.score(raw, now: now, dedupe: false))
        let hrrr = w.multiplier(.temperature, .hrrr, leadHours: 3)
        let bm = w.multiplier(.temperature, .bestMatch, leadHours: 3)
        XCTAssertFalse(w.isNeutral)
        XCTAssertEqual(bm, hrrr, accuracy: 0.05, "equal skill must give equal weight (hrrr \(hrrr), best_match \(bm))")
        // The display view still counts the duplicate hours once (best_match only where it differs).
        let display = AccuracyScorer.score(raw, now: now)
        XCTAssertLessThan(display.overall[.bestMatch]?.tempN ?? 0, display.overall[.hrrr]?.tempN ?? 0)
    }

    /// The verifier learns from full records end to end (weights(_:) uses the non-de-duplicated scores).
    func testVerifierLearnsFromFullRecords() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-m1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        var records: [ForecastRecord] = []
        for day in 0..<8 {
            for h in 0..<20 {
                let valid = t0.addingTimeInterval(Double(day) * 86400 + Double(h) * 3600)
                let hard = h % 5 == 0
                records.append(ForecastRecord(loc: "x", issued: valid.addingTimeInterval(-3 * 3600), valid: valid, f: [
                    VerificationSource.hrrr.rawValue: SourceValues(t: hard ? 13 : 11),
                    VerificationSource.bestMatch.rawValue: SourceValues(t: hard ? 7 : 11),
                    VerificationSource.ecmwf.rawValue: SourceValues(t: hard ? 13 : 11.5),
                ]))
            }
        }
        await v.record(records, key: "x")
        clock.now = t0.addingTimeInterval(9 * 86400)
        let obs = records.map { StationObservation(time: $0.valid, temperatureC: 10, windKmh: nil, precipLastHourMM: nil, precipitating: false) }
        await v.ingest(observations: obs, key: "x")
        let w = await v.weights("x")
        XCTAssertFalse(w.isNeutral, "enough verified days to learn")
        XCTAssertEqual(w.multiplier(.temperature, .bestMatch, leadHours: 3),
                       w.multiplier(.temperature, .hrrr, leadHours: 3), accuracy: 0.05)
    }

    // MARK: Code Reviewer nice-to-have: F1 window on the fall-back day

    /// Rain chance 90 % only in the hour labelled 06:00 local (5–6 AM, before the 6 AM–midnight window).
    /// Nov 1 2026 has 25 hours; `day + 6 h` used to be 5 AM there and leaked that hour in.
    func testDaytimePoPWindowOnFallBackDay() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let d0 = 1_793_419_200.0, d1 = 1_793_505_600.0, d2 = 1_793_595_600.0, d3 = 1_793_682_000.0
        var times: [Double] = [], pop: [Double] = [], temp: [Double] = []
        var t = d0
        while t <= d3 + 3600 { times.append(t); temp.append(10); pop.append(t == d0 + 6 * 3600 || t == d1 + 7 * 3600 ? 90 : 0); t += 3600 }
        func js(_ a: [Double]) -> String { "[" + a.map { String(Int($0)) }.joined(separator: ",") + "]" }
        let json = """
        {"latitude":41,"longitude":-73,"timezone":"America/New_York","utc_offset_seconds":-14400,
         "daily":{"time":[\(Int(d0)),\(Int(d1)),\(Int(d2))],
                  "temperature_2m_max_best_match":[15,15,15],"temperature_2m_min_best_match":[5,5,5],
                  "precipitation_probability_max_best_match":[90,90,0],"weather_code_best_match":[3,3,3]},
         "hourly":{"time":\(js(times)),"temperature_2m_best_match":\(js(temp)),"precipitation_probability_best_match":\(js(pop))}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: ny)
        XCTAssertEqual(daily[0].precipitationProbability ?? -1, 0, accuracy: 1e-9, "Oct 31: 5–6 AM excluded")
        XCTAssertEqual(daily[1].precipitationProbability ?? -1, 0, accuracy: 1e-9, "Nov 1 (25 h day): 5–6 AM EST excluded too")
    }
}
