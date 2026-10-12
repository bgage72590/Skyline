import XCTest
@testable import SkylineCore

/// Code-review checks for batch 4 (notifications, insight, QA merge rules).
final class ReviewBatch4Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let ny = TimeZone(identifier: "America/New_York")!
    let loc = WeatherLocation(name: "Home", region: "CT", country: "United States",
                              coordinate: Coordinate(latitude: 41.14, longitude: -73.26))
    lazy var label: (Date) -> String = { [ny] d in
        let f = DateFormatter(); f.timeZone = ny; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    func report(alerts: [WeatherAlert] = [], minutely: [MinutelyPrecipitation] = [], at t: Date) -> WeatherReport {
        let cur = CurrentConditions(time: t, temperature: 12, apparentTemperature: 12, humidity: 60, dewPoint: nil, weatherCode: 3,
                                    isDay: true, precipitation: 0, cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil,
                                    windGust: nil, visibility: nil, uvIndex: nil)
        return WeatherReport(location: loc, fetchedAt: t, timeZoneIdentifier: "America/New_York", current: cur,
                             hourly: [], daily: [], minutely: minutely, alerts: alerts)
    }

    var prefs: NotificationPrefs { var p = NotificationPrefs(); p.alerts = true; p.rain = true; p.quietHours = false; return p }

    /// One NWS alert feature as /alerts/active returns it.
    func feature(id: String, type: String, refs: [String], vtec: String, event: String = "Flood Warning",
                 severity: String = "Severe", ends: String = "2026-10-14T02:00:00-04:00") -> String {
        let r = refs.map { "{\"identifier\":\"\($0)\",\"@id\":\"x\",\"sender\":\"w-nws\",\"sent\":\"2026-10-11T09:25:00-04:00\"}" }
        return """
        {"type":"Feature","geometry":null,"properties":{"id":"\(id)","event":"\(event)","headline":"\(event) until Tuesday",
         "severity":"\(severity)","status":"Actual","messageType":"\(type)","references":[\(r.joined(separator: ","))],
         "effective":"2026-10-11T09:25:00-04:00","expires":"2026-10-12T09:30:00-04:00","ends":"\(ends)",
         "parameters":{"VTEC":["\(vtec)"]}}}
        """
    }
    func alerts(_ features: [String], now: Date) throws -> [WeatherAlert] {
        try NWSAlertParser.decode(Data("{\"features\":[\(features.joined(separator: ","))]}".utf8), now: now)
    }

    /// NWS re-issues a warning as an *Update* with a new id (river flood statements twice a day, severe
    /// thunderstorm statements every ~20 min). It's the same warning: notify once.
    func testWarningUpdateWithNewIDIsNotRenotified() throws {
        var state = NotificationState()
        let a = try alerts([feature(id: "urn:A", type: "Alert", refs: [], vtec: "/O.NEW.KOKX.FL.W.0006.261011T1325Z-261014T0600Z/")], now: t0)
        let n1 = NotificationPlanner.plan(report(alerts: a, at: t0), locationName: "Home", prefs: prefs, state: &state, now: t0,
                                          timeZone: ny, timeLabel: label)
        XCTAssertEqual(n1.count, 1)
        let t1 = t0.addingTimeInterval(12 * 3600)
        let b = try alerts([feature(id: "urn:B", type: "Update", refs: ["urn:A"],
                                    vtec: "/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/")], now: t1)
        let n2 = NotificationPlanner.plan(report(alerts: b, at: t1), locationName: "Home", prefs: prefs, state: &state, now: t1,
                                          timeZone: ny, timeLabel: label)
        XCTAssertTrue(n2.isEmpty, "update of an already-notified warning re-notified: \(n2.map(\.title))")
    }

    /// An upgrade (watch → warning) is news even though it references the watch.
    func testUpgradeToWarningStillNotifies() throws {
        var state = NotificationState()
        let w = try alerts([feature(id: "urn:W", type: "Alert", refs: [], vtec: "/O.NEW.KOKX.WS.A.0003.261012T0000Z-261013T0000Z/",
                                    event: "Winter Storm Watch")], now: t0)
        XCTAssertEqual(NotificationPlanner.plan(report(alerts: w, at: t0), locationName: "Home", prefs: prefs, state: &state,
                                                now: t0, timeZone: ny, timeLabel: label).count, 1)
        let t1 = t0.addingTimeInterval(6 * 3600)
        let up = try alerts([feature(id: "urn:X", type: "Update", refs: ["urn:W"], vtec: "/O.NEW.KOKX.WS.W.0005.261012T0000Z-261013T0000Z/",
                                     event: "Winter Storm Warning")], now: t1)
        XCTAssertEqual(NotificationPlanner.plan(report(alerts: up, at: t1), locationName: "Home", prefs: prefs, state: &state,
                                                now: t1, timeZone: ny, timeLabel: label).count, 1)
    }

    /// A cancellation statement keeps the warning's event name and stays "active" until it expires.
    /// It must never arrive as a fresh "Tornado Warning" notification.
    func testCancellationIsNotNotified() throws {
        var state = NotificationState()
        let c = try alerts([feature(id: "urn:C", type: "Update", refs: ["urn:T"], vtec: "/O.CAN.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/",
                                    event: "Tornado Warning", severity: "Extreme", ends: "2026-10-11T10:00:00-04:00")], now: t0)
        let n = NotificationPlanner.plan(report(alerts: c, at: t0), locationName: "Home", prefs: prefs, state: &state, now: t0,
                                         timeZone: ny, timeLabel: label)
        XCTAssertTrue(n.isEmpty, "cancellation notified as \(n.map(\.title))")
    }

    /// Scattered showers (30 min wet, 45 min dry, repeating) with a refresh every 15 minutes for 4 hours.
    func testShowersDoNotFlap() {
        var state = NotificationState()
        func truth(_ t: Date) -> Double { // mm per 15 min for the quarter ending at t
            let m = Int(t.timeIntervalSince(t0) / 60) % 75
            return (m > 30 && m <= 60) ? 0.4 : 0
        }
        var sent: [PlannedNotification] = []
        for k in 0..<16 {
            let now = t0.addingTimeInterval(Double(k) * 900 + 60)
            let start = (now.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
            let q = (0..<8).map { i -> MinutelyPrecipitation in
                let t = Date(timeIntervalSince1970: start + Double(i) * 900); return MinutelyPrecipitation(time: t, precipitation: truth(t))
            }
            sent += NotificationPlanner.plan(report(minutely: q, at: now), locationName: "Home", prefs: prefs, state: &state,
                                             now: now, timeZone: ny, timeLabel: label)
        }
        print("[review] showers, 4 h: \(sent.map(\.kind.rawValue))")
        XCTAssertLessThanOrEqual(sent.count, 3, "flapping: \(sent.map(\.kind.rawValue))")
    }

    /// A real rain event still gets both notices.
    func testSteadyRainStillStartsAndStops() {
        var state = NotificationState()
        func truth(_ t: Date) -> Double { let m = t.timeIntervalSince(t0) / 60; return (m > 30 && m <= 180) ? 0.5 : 0 }
        var sent: [PlannedNotification.Kind] = []
        for k in 0..<16 {
            let now = t0.addingTimeInterval(Double(k) * 900 + 60)
            let start = (now.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
            let q = (0..<8).map { i -> MinutelyPrecipitation in
                let t = Date(timeIntervalSince1970: start + Double(i) * 900); return MinutelyPrecipitation(time: t, precipitation: truth(t))
            }
            sent += NotificationPlanner.plan(report(minutely: q, at: now), locationName: "Home", prefs: prefs, state: &state,
                                             now: now, timeZone: ny, timeLabel: label).map(\.kind)
        }
        XCTAssertEqual(sent, [.rainStart, .rainStop])
    }

    /// Quiet hours across midnight, both DST changes, and a daytime window.
    func testQuietHoursAcrossMidnightAndDST() {
        var p = NotificationPrefs(); p.quietHours = true; p.quietStartMinutes = 22 * 60; p.quietEndMinutes = 7 * 60
        func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2026-11-01T05:30:00Z"), prefs: p, timeZone: ny))  // 1:30 EDT
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2026-11-01T06:30:00Z"), prefs: p, timeZone: ny))  // 1:30 EST (repeat)
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2026-11-01T11:59:00Z"), prefs: p, timeZone: ny))  // 6:59 EST
        XCTAssertFalse(NotificationPlanner.isQuiet(at("2026-11-01T12:00:00Z"), prefs: p, timeZone: ny)) // 7:00 EST
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2027-03-14T07:30:00Z"), prefs: p, timeZone: ny))  // 3:30 EDT (after spring-forward)
        XCTAssertFalse(NotificationPlanner.isQuiet(at("2027-03-14T11:00:00Z"), prefs: p, timeZone: ny)) // 7:00 EDT
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2026-10-12T02:00:00Z"), prefs: p, timeZone: ny))  // 22:00 EDT
        XCTAssertFalse(NotificationPlanner.isQuiet(at("2026-10-12T01:59:00Z"), prefs: p, timeZone: ny)) // 21:59
        var day = p; day.quietStartMinutes = 13 * 60; day.quietEndMinutes = 15 * 60
        XCTAssertTrue(NotificationPlanner.isQuiet(at("2026-10-12T18:00:00Z"), prefs: day, timeZone: ny)) // 14:00
        XCTAssertFalse(NotificationPlanner.isQuiet(at("2026-10-12T20:00:00Z"), prefs: day, timeZone: ny))
        // Quiet hours follow the Mac's zone, not the city's: 11 PM in New York is 8 PM in Los Angeles.
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertFalse(NotificationPlanner.isQuiet(at("2026-10-12T03:00:00Z"), prefs: p, timeZone: la))
    }

    /// Morning briefing: on the spring-forward day 7:00 AM is still 7:00 local; a Mac waking 2 h late gets it once.
    func testBriefingSpringForwardAndLateWake() {
        var p = NotificationPrefs(); p.morningBriefing = true
        let sat = ISO8601DateFormatter().date(from: "2027-03-13T17:00:00Z")! // Sat noon EST
        XCTAssertEqual(NotificationPlanner.nextBriefing(after: sat, prefs: p, timeZone: ny),
                       ISO8601DateFormatter().date(from: "2027-03-14T11:00:00Z")!) // 7:00 EDT
        var s = NotificationState()
        let wake = ISO8601DateFormatter().date(from: "2027-03-14T13:10:00Z")! // 9:10 EDT
        XCTAssertNotNil(NotificationPlanner.briefing(report(at: wake), locationName: "Home", summary: "x", prefs: p, state: &s,
                                                     now: wake, timeZone: ny))
        XCTAssertNil(NotificationPlanner.briefing(report(at: wake), locationName: "Home", summary: "x", prefs: p, state: &s,
                                                  now: wake.addingTimeInterval(600), timeZone: ny))
    }

    /// F1 triple-count re-run with the QA merge rule: the NOAA trio collapses to one vote at HRRR's weight;
    /// best_match (a copy) adds nothing; ICON with the same value is a different family and stays.
    func testFamilyDedupeTripleCount() {
        let input: [(model: ForecastModel, value: Double?, weight: Double)] = [
            (.bestMatch, 10, 2), (.hrrr, 10, 3), (.ecmwf, 12, 1.5), (.gfs, 10, 1), (.icon, 10, 1)]
        let out = ForecastBlender.dedupedFamily(input)
        XCTAssertEqual(ForecastBlender.weightedMean(out)!, (30.0 + 18 + 10) / 5.5, accuracy: 1e-9)
        // Beyond HRRR's range best_match == GFS: one vote at GFS's 1.0, not best_match's 2.0.
        let late: [(model: ForecastModel, value: Double?, weight: Double)] = [(.bestMatch, 20, 2), (.gfs, 20, 1), (.ecmwf, 10, 1.5)]
        XCTAssertEqual(ForecastBlender.weightedMean(ForecastBlender.dedupedFamily(late))!, (20 + 15.0) / 2.5, accuracy: 1e-9)
        // Outside the US: best_match independent, a coincidental equal GFS value keeps both votes.
        XCTAssertEqual(ForecastBlender.weightedMean(ForecastBlender.dedupedFamily(late, bestMatchIsCopy: false))!,
                       (40 + 20 + 15.0) / 4.5, accuracy: 1e-9)
        // NYC fixture: best_match is GFS for every hour, so it's detected as a copy.
        let om = try! OpenMeteoResponse.decode(try! Fixture.data("om_nyc"))
        let col = { (m: ForecastModel) in om.hourlyColumn("temperature_2m", model: m) ?? [] }
        XCTAssertTrue(ForecastBlender.bestMatchIsCopy(col(.bestMatch), of: [col(.gfs), col(.hrrr)]))
    }

    /// Outside the US in a dry spell, best_match and GFS both say 0 mm every hour. That's coincidence,
    /// not a copy: best_match must keep its own vote (QA item 3).
    func testNonUSDrySpellIsNotACopy() throws {
        let t = 1_790_000_000.0
        let n = 12
        let times = (0..<n).map { t + Double($0) * 3600 }
        func a(_ x: [Double]) -> String { "[" + x.map { String($0) }.joined(separator: ",") + "]" }
        func json(gfsRain: Double) -> String {
            """
            {"latitude":51.5,"longitude":-0.13,"timezone":"Europe/London","utc_offset_seconds":3600,
             "hourly":{"time":\(times),
               "temperature_2m_best_match":\(a((0..<n).map { 10 + Double($0) * 0.3 })),"temperature_2m_gfs_seamless":\(a((0..<n).map { 11 + Double($0) * 0.2 })),
               "temperature_2m_ecmwf_ifs025":\(a(Array(repeating: 10, count: n))),
               "precipitation_best_match":\(a(Array(repeating: 0, count: n))),"precipitation_gfs_seamless":\(a(Array(repeating: gfsRain, count: n))),
               "precipitation_ecmwf_ifs025":\(a(Array(repeating: 0.6, count: n)))}}
            """
        }
        let now = Date(timeIntervalSince1970: t - 48 * 3600)
        let shipped = ForecastBlender.blendHourly(openMeteo: try OpenMeteoResponse.decode(Data(json(gfsRain: 0).utf8)), nwsHourly: [], now: now)
        let independent = ForecastBlender.blendHourly(openMeteo: try OpenMeteoResponse.decode(Data(json(gfsRain: 0.0001).utf8)), nwsHourly: [], now: now)
        XCTAssertEqual(shipped[3].precipitation ?? -1, independent[3].precipitation ?? -2, accuracy: 0.001,
                       "dry-spell 0 mm treated as a copy: best_match lost its vote")
    }

    /// Forecaster's notes: a very long key message is bounded like the synopsis is.
    func testKeyMessageLengthBounded() {
        let long = String(repeating: "Heavy rain is likely across the area with totals of one to two inches. ", count: 20)
        let text = ".KEY MESSAGES...\n\n- \(long)\n- Short one.\n\n&&\n"
        let notes = AFDParser.notes(text: text, office: "OKX", issued: t0)
        XCTAssertEqual(notes.points.count, 2)
        XCTAssertLessThanOrEqual(notes.points[0].count, 401, "key message is \(notes.points[0].count) chars")
    }

    /// The Settings time pickers build "minutes after midnight" as startOfDay + N minutes: on the 25-hour
    /// day that shows 10 PM as 9 PM (mirrors `NotificationSettings.minutes`).
    func testMinutesAfterMidnightOnFallBackDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        let nov1 = ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z")!
        let shown = cal.date(byAdding: .minute, value: 22 * 60, to: cal.startOfDay(for: nov1))!
        XCTAssertEqual(cal.component(.hour, from: shown), 21, "documents the shipped behaviour (9 PM shown for 10 PM)")
        let fixed = cal.date(bySettingHour: 22, minute: 0, second: 0, of: nov1)!
        XCTAssertEqual(cal.component(.hour, from: fixed), 22)
    }
}
