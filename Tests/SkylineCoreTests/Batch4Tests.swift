import XCTest
@testable import SkylineCore

/// Batch 4: notifications (T8), confidence and "why it changed" (T11), forecaster's notes (T17),
/// morning briefing (L19), warnings without the /points lookup (L2).
final class Batch4Tests: XCTestCase {
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let ny = TimeZone(identifier: "America/New_York")!
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
    let toF: (Double) -> Int = { Int(($0 * 9 / 5).rounded()) }
    lazy var hourLabel: (Date) -> String = { [ny] d in
        let f = DateFormatter(); f.timeZone = ny; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h a"; return f.string(from: d)
    }
    lazy var timeLabel: (Date) -> String = { [ny] d in
        let f = DateFormatter(); f.timeZone = ny; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    func current(_ t: Date, temp: Double = 12) -> CurrentConditions {
        CurrentConditions(time: t, temperature: temp, apparentTemperature: temp, humidity: 60, dewPoint: nil, weatherCode: 3,
                          isDay: true, precipitation: 0, cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil,
                          windGust: nil, visibility: nil, uvIndex: nil)
    }

    func report(alerts: [WeatherAlert] = [], minutely: [MinutelyPrecipitation] = [], daily: [DailyForecast] = [],
                hourly: [HourlyForecast] = [], at t: Date? = nil) -> WeatherReport {
        WeatherReport(location: nyc, fetchedAt: t ?? fixtureTime, timeZoneIdentifier: "America/New_York",
                      current: current(t ?? fixtureTime), hourly: hourly, daily: daily, minutely: minutely, alerts: alerts)
    }

    func alert(_ id: String, _ severity: AlertSeverity, polygon: [Coordinate] = [], zone: Bool = false,
               ends: Date? = nil) -> WeatherAlert {
        var a = WeatherAlert(id: id, event: "\(severity.rawValue) Thing", headline: "Headline \(id).", severity: severity,
                             urgency: nil, areaDescription: nil, description: nil, instruction: nil, effective: nil,
                             expires: nil, ends: ends ?? fixtureTime.addingTimeInterval(3 * 3600), senderName: nil)
        a.polygons = polygon.isEmpty ? [] : [polygon]
        a.outlineIsZone = zone
        return a
    }

    func box(_ c: Coordinate, _ d: Double) -> [Coordinate] {
        [Coordinate(latitude: c.latitude - d, longitude: c.longitude - d), Coordinate(latitude: c.latitude - d, longitude: c.longitude + d),
         Coordinate(latitude: c.latitude + d, longitude: c.longitude + d), Coordinate(latitude: c.latitude + d, longitude: c.longitude - d)]
    }

    // MARK: L2

    /// /points fails (first launch during an NWS hiccup, nothing cached): warnings still arrive.
    func testAlertsDoNotNeedThePointsLookup() async throws {
        final class NoPoints: HTTPClient, @unchecked Sendable {
            let inner = MockHTTPClient()
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                if url.absoluteString.contains("/points/") { throw HTTPError.status(500, url) }
                return try await inner.get(url, headers: headers)
            }
        }
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: NoPoints(), cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let r = try await service.report(for: nyc)
        XCTAssertEqual(r.alerts.map(\.event), ["Tornado Warning", "Flood Warning"])
        XCTAssertFalse(r.sources.contains { $0.hasPrefix("NWS") }, "no NWS forecast without /points")
        XCTAssertNil(r.nwsGridID)
    }

    func testReportCarriesOfficeAndPopSpread() async throws {
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let r = try await service.report(for: nyc)
        XCTAssertEqual(r.nwsGridID, "OKX")
        XCTAssertTrue(r.hourly.contains { $0.precipitationProbabilitySpread != nil })
        XCTAssertNil(r.earlierOutlook, "no history kept without a ForecastHistory")
    }

    // MARK: T17 forecaster's notes

    func testKeyMessagesNumbered() throws {
        let n = try AFDParser.notes(Fixture.data("nws_afd_okx"), office: "OKX")
        XCTAssertTrue(n.areKeyMessages)
        XCTAssertEqual(n.points.count, 4)
        XCTAssertTrue(n.points[0].hasPrefix("Low pressure developing along the front"), n.points[0])
        XCTAssertFalse(n.points[0].contains("\n") || n.points[0].contains("  "))
        XCTAssertTrue(n.points[3].hasSuffix("Friday into Saturday."), n.points[3])
        XCTAssertEqual(n.whatChanged, "A Coastal Flood Statement has been issued for some locations for the Monday morning high tide cycle.")
        XCTAssertEqual(n.issued, ISO8601DateFormatter().date(from: "2026-10-11T23:55:00Z"))
        XCTAssertEqual(n.fullTextURL.absoluteString,
                       "https://forecast.weather.gov/product.php?site=OKX&issuedby=OKX&product=AFD&format=txt")
    }

    func testKeyMessagesDashed() throws {
        let bou = try AFDParser.notes(Fixture.data("nws_afd_bou"), office: "BOU")
        XCTAssertEqual(bou.points.count, 4)
        XCTAssertTrue(bou.points[0].hasPrefix("Unseasonably warm"))
        XCTAssertNil(bou.whatChanged)
        let lot = try AFDParser.notes(Fixture.data("nws_afd_lot"), office: "LOT")
        XCTAssertEqual(lot.points, ["Record warmth is likely on Monday, along with breezy/gusty southwesterly winds.",
                                    "Showers likely and some embedded thunderstorms Tuesday night into Wednesday morning, and again on Thursday.",
                                    "Turning much cooler into next weekend."])
    }

    func testNoKeyMessagesFallsBackToSynopsis() {
        let text = """
        000
        FXUS62 KXYZ 120300
        AFDXYZ

        .SYNOPSIS...
        HIGH PRESSURE WILL BUILD IN FROM THE WEST TONIGHT AND REMAIN IN CONTROL
        THROUGH MIDWEEK.

        A SECOND PARAGRAPH.

        &&

        .NEAR TERM /THROUGH TONIGHT/...
        Details.
        &&
        """
        let n = AFDParser.notes(text: text, office: "XYZ", issued: fixtureTime)
        XCTAssertFalse(n.areKeyMessages)
        XCTAssertEqual(n.points, ["High pressure will build in from the west tonight and remain in control through midweek."])
    }

    func testLatestAFDAndService() async throws {
        XCTAssertEqual(try AFDParser.latestID(Fixture.data("nws_afd_list")), "4abbf29b-df94-4246-a1e4-0791aa48d67e")
        let client = MockHTTPClient()
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil))
        let n = await service.forecasterNotes(office: "OKX")
        XCTAssertEqual(n?.points.count, 4)
        XCTAssertTrue(client.requests.contains { $0.absoluteString.hasSuffix("/products/4abbf29b-df94-4246-a1e4-0791aa48d67e") })
        XCTAssertNil(Endpoints.nwsAFDList(office: "../x"), "office ids are validated")
        let again = await service.forecasterNotes(office: "OKX")
        XCTAssertEqual(again, n)
        XCTAssertEqual(client.requests.count, 2, "second look is served from cache")
    }

    // MARK: T11 confidence and changes

    func day(_ offset: Int, high: Double, low: Double = 5, pop: Double? = nil, spread: Double? = nil) -> DailyForecast {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: fixtureTime))!
        return DailyForecast(date: d, weatherCode: 3, high: high, low: low, precipitationProbability: pop, highSpread: spread)
    }

    func testConfidenceFromHighSpread() {
        let c1 = ForecastInsight.confidence(day: day(1, high: 20, spread: 1.0), hourly: [], timeZone: ny, now: fixtureTime,
                                            hourLabel: hourLabel, delta: toF)
        XCTAssertEqual(c1.level, .high)
        XCTAssertEqual(c1.sentence, "High confidence: models agree on the high within 2°.")
        let c2 = ForecastInsight.confidence(day: day(1, high: 20, spread: 3.0), hourly: [], timeZone: ny, now: fixtureTime,
                                            hourLabel: hourLabel, delta: toF)
        XCTAssertEqual(c2.level, .medium)
        XCTAssertEqual(c2.reason, "Models differ by 5° on the high")
        let c3 = ForecastInsight.confidence(day: day(1, high: 20, spread: 5.0), hourly: [], timeZone: ny, now: fixtureTime,
                                            hourLabel: hourLabel, delta: toF)
        XCTAssertEqual(c3.level, .low)
    }

    func testConfidenceRainTimingDisagreement() {
        let tomorrow = day(1, high: 20, spread: 1.0)
        // Sources split on rain from 3 PM to 6 PM tomorrow (values at T cover the hour ending at T).
        let hours: [HourlyForecast] = (0..<24).map { h in
            var x = HourlyForecast(time: tomorrow.date.addingTimeInterval(Double(h) * 3600), temperature: 15, weatherCode: 3, isDay: true)
            x.precipitationProbabilitySpread = (15...18).contains(h) ? 65 : 10
            return x
        }
        let c = ForecastInsight.confidence(day: tomorrow, hourly: hours, timeZone: ny, now: fixtureTime, hourLabel: hourLabel, delta: toF)
        XCTAssertEqual(c.level, .medium)
        XCTAssertEqual(c.sentence, "Medium confidence: models disagree on rain chances after 2 PM.")
    }

    func testSincePhrases() {
        // fixtureTime is 9:30 AM ET.
        func p(_ hoursAgo: Double) -> String {
            ForecastInsight.sincePhrase(fixtureTime.addingTimeInterval(-hoursAgo * 3600), now: fixtureTime, timeZone: ny)
        }
        XCTAssertEqual(p(2), "since this morning")
        XCTAssertEqual(p(6), "since last night")    // 3:30 AM
        XCTAssertEqual(p(12), "since last night")   // 9:30 PM yesterday
        XCTAssertEqual(p(20), "since yesterday afternoon")
        XCTAssertEqual(p(26), "since yesterday morning")
    }

    func testWhyTheForecastChanged() {
        var r = report(daily: [day(0, high: 18, pop: 20), day(1, high: 14, pop: 70), day(2, high: 15)])
        r.earlierOutlook = ForecastSnapshot(issued: fixtureTime.addingTimeInterval(-12 * 3600),
                                            days: [.init(date: day(0, high: 0).date, high: 17.5, low: 5, precipitationProbability: 25),
                                                   .init(date: day(1, high: 0).date, high: 17, low: 5, precipitationProbability: 30),
                                                   .init(date: day(2, high: 0).date, high: 5, low: 0, precipitationProbability: nil)])
        let notes = ForecastInsight.changes(r, now: fixtureTime, delta: toF)
        XCTAssertEqual(notes, ["Tomorrow’s high is down 5° since last night.",
                               "Rain chance tomorrow is up from 30% to 70% since last night."],
                       "today moved < 3°F and < 25 points; day 3 is out of scope")
        r.earlierOutlook = nil
        XCTAssertTrue(ForecastInsight.changes(r, now: fixtureTime, delta: toF).isEmpty)
    }

    // MARK: T11 history store

    func testHistoryKeepsOneSnapshotPer3HoursAndPicks12HoursAgo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = ForecastHistory(directory: dir)
        let daily = [day(0, high: 10), day(1, high: 11)]
        for i in 0..<20 { await h.record("x", daily: daily, now: fixtureTime.addingTimeInterval(Double(i) * 3600)) }
        // Hours 0, 3, 6 … 18 → 7 snapshots.
        let n = await h.count("x")
        XCTAssertEqual(n, 7)
        let now = fixtureTime.addingTimeInterval(20 * 3600)
        let e = await h.earlier("x", now: now)
        XCTAssertEqual(e?.issued, fixtureTime.addingTimeInterval(9 * 3600), "closest to 12 h old (11 h)")
        let early = await h.earlier("x", now: fixtureTime.addingTimeInterval(5 * 3600))
        XCTAssertNil(early, "nothing 9+ h old yet")
        // Persisted and reloaded; old snapshots pruned after 48 h.
        let h2 = ForecastHistory(directory: dir)
        let n2 = await h2.count("x")
        XCTAssertEqual(n2, 7)
        await h2.record("x", daily: daily, now: fixtureTime.addingTimeInterval(60 * 3600))
        let n3 = await h2.count("x")
        XCTAssertEqual(n3, 4, "snapshots from hours 12, 15, 18 and the new one at 60 remain within 48 h")
    }

    func testServiceAttachesEarlierOutlook() async throws {
        let clock = TestClock(fixtureTime)
        let history = ForecastHistory(directory: nil)
        let service = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: nil, now: { clock.now }),
                                     history: history, now: { clock.now })
        let first = try await service.report(for: nyc)
        XCTAssertNil(first.earlierOutlook)
        clock.now = fixtureTime.addingTimeInterval(12 * 3600)
        let later = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertEqual(later.earlierOutlook?.issued, fixtureTime)
        XCTAssertEqual(later.earlierOutlook?.days.first?.high, first.daily.first?.high)
    }

    // MARK: T8 notifications

    var prefsAll: NotificationPrefs { var p = NotificationPrefs(); p.alerts = true; p.rain = true; p.minimumSeverity = .moderate; return p }

    func testAlertNotificationsFilterAndDeduplicate() {
        let c = nyc.coordinate
        let r = report(alerts: [alert("a", .minor),                                                 // below threshold
                                alert("b", .severe, polygon: box(c, 0.1)),                          // storm polygon over the point
                                alert("c", .severe, polygon: box(Coordinate(latitude: c.latitude + 1, longitude: c.longitude), 0.1)), // elsewhere
                                alert("d", .moderate, polygon: box(Coordinate(latitude: c.latitude + 1, longitude: c.longitude), 0.1), zone: true), // zone outline
                                alert("e", .extreme, ends: fixtureTime.addingTimeInterval(-60))])   // already over
        var state = NotificationState()
        let first = NotificationPlanner.plan(r, locationName: "New York", prefs: prefsAll, state: &state, now: fixtureTime,
                                             timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(first.map(\.alertID), ["b", "d"])
        XCTAssertEqual(first[0].title, "Severe Thing · New York")
        XCTAssertEqual(first[0].body, "Headline b. Until 12:30 PM.")
        let again = NotificationPlanner.plan(r, locationName: "New York", prefs: prefsAll, state: &state,
                                             now: fixtureTime.addingTimeInterval(600), timeZone: ny, timeLabel: timeLabel)
        XCTAssertTrue(again.isEmpty, "never twice for the same alert")
        var off = prefsAll; off.alerts = false
        var fresh = NotificationState()
        XCTAssertTrue(NotificationPlanner.plan(r, locationName: "New York", prefs: off, state: &fresh, now: fixtureTime,
                                               timeZone: ny, timeLabel: timeLabel).filter { $0.kind == .alert }.isEmpty)
    }

    func testQuietHoursHoldBackAllButExtreme() {
        let night = fixtureTime.addingTimeInterval(14 * 3600) // 11:30 PM ET
        let r = report(alerts: [alert("s", .severe, ends: night.addingTimeInterval(9 * 3600)),
                                alert("x", .extreme, ends: night.addingTimeInterval(3600))], at: night)
        var state = NotificationState()
        let planned = NotificationPlanner.plan(r, locationName: "NYC", prefs: prefsAll, state: &state, now: night, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(planned.map(\.alertID), ["x"])
        XCTAssertTrue(planned[0].timeSensitive)
        let morning = night.addingTimeInterval(8 * 3600) // 7:30 AM
        let held = NotificationPlanner.plan(r, locationName: "NYC", prefs: prefsAll, state: &state, now: morning, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(held.map(\.alertID), ["s"], "held warning goes out after quiet hours if still active")
        var p = prefsAll; p.quietHours = false
        XCTAssertFalse(NotificationPlanner.isQuiet(night, prefs: p, timeZone: ny))
    }

    func quarters(_ mm: [Double], from t: Date) -> [MinutelyPrecipitation] {
        let start = (t.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
        return mm.enumerated().map { MinutelyPrecipitation(time: Date(timeIntervalSince1970: start + Double($0.offset) * 900), precipitation: $0.element) }
    }

    func testRainStartingSoonOnceThenEnding() {
        var p = NotificationPrefs(); p.rain = true
        var state = NotificationState()
        // Dry now; wet from the 3rd quarter (starts ~30 min after the first quarter boundary).
        let r1 = report(minutely: quarters([0, 0, 0.3, 0.6, 0.5, 0.2], from: fixtureTime))
        let n1 = NotificationPlanner.plan(r1, locationName: "NYC", prefs: p, state: &state, now: fixtureTime, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(n1.map(\.kind), [.rainStart])
        XCTAssertEqual(n1.first?.body, "Rain starting in about 30 minutes.")
        XCTAssertEqual(n1.first?.title, "Rain starting soon · NYC")
        let t2 = fixtureTime.addingTimeInterval(600)
        XCTAssertTrue(NotificationPlanner.plan(report(minutely: quarters([0, 0.3, 0.6, 0.5], from: t2), at: t2), locationName: "NYC",
                                               prefs: p, state: &state, now: t2, timeZone: ny, timeLabel: timeLabel).isEmpty,
                      "no repeat within 2 h")
        // Raining now, stopping in ~45 min with a dry half hour after.
        let t3 = fixtureTime.addingTimeInterval(3600)
        let n3 = NotificationPlanner.plan(report(minutely: quarters([0.4, 0.3, 0.2, 0, 0, 0, 0], from: t3), at: t3), locationName: "NYC",
                                          prefs: p, state: &state, now: t3, timeZone: ny, timeLabel: timeLabel)
        XCTAssertEqual(n3.map(\.kind), [.rainStop])
        XCTAssertEqual(n3.first?.body, "Rain ending around 11:15 AM.")
    }

    func testRainNoiseAndQuietHours() {
        var p = NotificationPrefs(); p.rain = true
        var state = NotificationState()
        // A single light wet quarter is not "rain starting".
        let blip = report(minutely: quarters([0, 0, 0.12, 0, 0, 0], from: fixtureTime))
        XCTAssertTrue(NotificationPlanner.plan(blip, locationName: "NYC", prefs: p, state: &state, now: fixtureTime, timeZone: ny, timeLabel: timeLabel).isEmpty)
        // Quiet hours: nothing about rain.
        let night = fixtureTime.addingTimeInterval(14 * 3600)
        let wet = report(minutely: quarters([0, 0, 0.5, 0.5, 0.5], from: night), at: night)
        XCTAssertTrue(NotificationPlanner.plan(wet, locationName: "NYC", prefs: p, state: &state, now: night, timeZone: ny, timeLabel: timeLabel).isEmpty)
        XCTAssertNil(state.rain[nyc.id])
    }

    // MARK: L19 morning briefing

    func testMorningBriefingOncePerDayInsideItsWindow() {
        var p = NotificationPrefs(); p.morningBriefing = true; p.briefingMinutes = 7 * 60
        var state = NotificationState()
        let r = report()
        let early = fixtureTime.addingTimeInterval(-3 * 3600) // 6:30 AM
        XCTAssertNil(NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &state, now: early, timeZone: ny))
        let b = NotificationPlanner.briefing(r, locationName: "NYC", summary: "High 64°, low 50°. Rain likely from 4 PM.",
                                             prefs: p, state: &state, now: fixtureTime, timeZone: ny)
        XCTAssertEqual(b?.title, "Today in NYC")
        XCTAssertEqual(b?.body, "High 64°, low 50°. Rain likely from 4 PM.")
        XCTAssertNil(NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &state,
                                                  now: fixtureTime.addingTimeInterval(1800), timeZone: ny), "once a day")
        var late = NotificationState()
        XCTAssertNil(NotificationPlanner.briefing(r, locationName: "NYC", summary: "s", prefs: p, state: &late,
                                                  now: fixtureTime.addingTimeInterval(2 * 3600), timeZone: ny), "11:30 AM is too late")
        XCTAssertEqual(NotificationPlanner.nextBriefing(after: fixtureTime, prefs: p, timeZone: ny),
                       fixtureTime.addingTimeInterval(21.5 * 3600))
        XCTAssertEqual(NotificationPlanner.nextBriefing(after: early, prefs: p, timeZone: ny), fixtureTime.addingTimeInterval(-2.5 * 3600))
        // Nov 1 (fall back): 7:00 AM is still 7:00 AM wall clock.
        let oct31noon = Date(timeIntervalSince1970: 1_793_462_400)
        let next = NotificationPlanner.nextBriefing(after: oct31noon, prefs: p, timeZone: ny)
        XCTAssertEqual(next, Date(timeIntervalSince1970: 1_793_534_400), "7:00 AM EST on Nov 1")
    }

    func testPointInPolygon() {
        let ring = box(Coordinate(latitude: 0, longitude: 0), 1)
        XCTAssertTrue(NotificationPlanner.contains(ring, Coordinate(latitude: 0.5, longitude: -0.5)))
        XCTAssertFalse(NotificationPlanner.contains(ring, Coordinate(latitude: 1.5, longitude: 0)))
        XCTAssertFalse(NotificationPlanner.contains([], Coordinate(latitude: 0, longitude: 0)))
    }

    // MARK: Code Reviewer batch 3 must-fixes

    /// HRRR and the blend tie on the hours HRRR covers (0–6 h); the blend's worse 3+ day hours, which HRRR
    /// doesn't forecast, must not make HRRR look better.
    func testScorecardComparesOnTheSameLeadTimes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var recs: [VerifiedRecord] = []
        for i in 0..<60 {
            let v = t0.addingTimeInterval(Double(i) * 3 * 3600)
            recs.append(VerifiedRecord(ForecastRecord(loc: "x", issued: v.addingTimeInterval(-3 * 3600), valid: v, f: [
                VerificationSource.blend.rawValue: SourceValues(t: 11), VerificationSource.hrrr.rawValue: SourceValues(t: 11),
                VerificationSource.ecmwf.rawValue: SourceValues(t: 11.5)]), ObservedHour(t: 10)))
            recs.append(VerifiedRecord(ForecastRecord(loc: "x", issued: v.addingTimeInterval(-80 * 3600), valid: v, f: [
                VerificationSource.blend.rawValue: SourceValues(t: 12.5), VerificationSource.ecmwf.rawValue: SourceValues(t: 13)]),
                ObservedHour(t: 10)))
        }
        let s = AccuracyScorer.score(recs, now: t0.addingTimeInterval(8 * 86400), halfLifeDays: 0)
        let r = AccuracyReport(status: .ready, daysCollected: 8, verifiedPairs: s.pairs, pendingForecasts: 0,
                               stationID: nil, stationName: nil, overall: s.overall, byBucket: s.byBucket,
                               recentWinner: nil, recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        let text = AccuracySummary.headline(r, delta: { String(format: "%.1f°C", $0) })
        XCTAssertFalse(text.contains("alone did slightly better"), text)
        XCTAssertTrue(text.contains("as good as or better than any single model (best: HRRR, 1.0°C vs Skyline’s 1.0°C on the same forecast hours)"), text)
    }

    /// A model with a handful of lucky hours is never named.
    func testScorecardNeedsTwentyHours() {
        var blend = SourceScore(source: .blend); blend.tempN = 300; blend.tempAbs = 1.5 * 300
        var icon = SourceScore(source: .icon); icon.tempN = 3; icon.tempAbs = 0.3 * 3
        let r = AccuracyReport(status: .ready, daysCollected: 10, verifiedPairs: 300, pendingForecasts: 0, stationID: nil,
                               stationName: nil, overall: [.blend: blend, .icon: icon], byBucket: [:], recentWinner: nil,
                               recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        XCTAssertFalse(AccuracySummary.headline(r, delta: { String(format: "%.1f°C", $0) }).contains("ICON"))
        icon.tempN = 25; icon.tempAbs = 0.3 * 25
        let r2 = AccuracyReport(status: .ready, daysCollected: 10, verifiedPairs: 300, pendingForecasts: 0, stationID: nil,
                                stationName: nil, overall: [.blend: blend, .icon: icon], byBucket: [:], recentWinner: nil,
                                recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        XCTAssertTrue(AccuracySummary.headline(r2, delta: { String(format: "%.1f°C", $0) }).contains("ICON"))
    }

    /// "N of M rainy hours" counts real hours even when old hours are down-weighted (nice-to-have).
    func testRainyHoursAreRealHours() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let recs: [VerifiedRecord] = (0..<40).map { i in
            let v = t0.addingTimeInterval(Double(i) * 86400 / 2)   // spread over 20 days: strong decay
            let wet = i % 2 == 0
            return VerifiedRecord(ForecastRecord(loc: "x", issued: v.addingTimeInterval(-3 * 3600), valid: v, f: [
                VerificationSource.blend.rawValue: SourceValues(t: 10, pop: wet ? 80 : 10)]), ObservedHour(t: 10, wet: wet))
        }
        let s = AccuracyScorer.score(recs, now: t0.addingTimeInterval(21 * 86400))
        XCTAssertEqual(s.overall[.blend]?.wetHours, 20)
        let r = AccuracyReport(status: .ready, daysCollected: 20, verifiedPairs: s.pairs, pendingForecasts: 0, stationID: nil,
                               stationName: nil, overall: s.overall, byBucket: s.byBucket, recentWinner: nil,
                               recentWinnerMAE: nil, weights: BlendWeights(), minDays: 3)
        let text = AccuracySummary.headline(r, delta: { String(format: "%.1f°C", $0) })
        XCTAssertTrue(text.contains("(20 of 20 rainy hours caught)"), text)
    }

    /// The launch sweep scans off the actor; a fresh write landing during the scan must survive it.
    func testFreshCacheWriteDuringSweepSurvives() async throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }
        var lost = 0
        for round in 0..<200 {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-sweep-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let clock = Clock()
            let old = ResponseCache(directory: dir, now: { clock.t })
            for k in 0..<40 { await old.store(Data("old\(k)".utf8), for: "k\(k)") }
            clock.t = clock.t.addingTimeInterval(30 * 86400)
            let cache = ResponseCache(directory: dir, now: { clock.t })
            let key = "k\(round % 40)"
            async let sweep: Void = cache.prune()
            await Task.yield()
            await cache.store(Data("fresh".utf8), for: key)
            await sweep
            let url = dir.appendingPathComponent(ResponseCache.hash(key) + ".plist")
            if !FileManager.default.fileExists(atPath: url.path) { lost += 1 }
            // Everything else (old) is gone.
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".plist") }
            XCTAssertLessThanOrEqual(left.count, 1)
        }
        XCTAssertEqual(lost, 0, "fresh entries deleted by the sweep in \(lost) of 200 rounds")
    }

    // MARK: QA recommendations folded into batch 4

    /// NWS /gridpoints answers 503 quickly; the alerts request (same host) succeeds later. The later success
    /// must not cancel the back-off the 503 started (QA batch 2: order-dependent, 6 of 12 runs).
    func testNWS503BackOffSurvivesSlowerSuccess() async throws {
        final class Client: HTTPClient, @unchecked Sendable {
            let base = MockHTTPClient()
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                let s = url.absoluteString
                if s.contains("api.weather.gov/gridpoints") { throw HTTPError.throttled(503, url, retryAfter: 120) }
                if s.contains("api.weather.gov/alerts") { try await Task.sleep(for: .milliseconds(400)) }
                return try await base.get(url, headers: headers)
            }
        }
        for _ in 0..<3 {
            let t = fixtureTime
            let service = WeatherService(client: Client(), cache: ResponseCache(directory: nil), now: { t })
            _ = try? await service.report(for: nyc)
            let until = await service.backoff(for: "api.weather.gov")
            XCTAssertNotNil(until, "back-off cleared by a request that started before the 503")
        }
    }

    /// In the US best_match *is* GFS: the merged vote gets GFS's weight (1.0), so ECMWF (1.5) is no longer
    /// outvoted on days 8–10 (QA batch 1: Denver lows followed GFS).
    func testMergedAmericanVoteUsesGFSWeight() throws {
        let days = (0..<5).map { Double($0) * 86400 + 1_790_000_000 }
        func col(_ v: Double) -> String { "[" + Array(repeating: "\(v)", count: 5).joined(separator: ",") + "]" }
        let json = """
        {"latitude":40,"longitude":-105,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":\(days),"temperature_2m_max_best_match":\(col(20)),"temperature_2m_min_best_match":\(col(10)),
                  "temperature_2m_max_gfs_seamless":\(col(20)),"temperature_2m_min_gfs_seamless":\(col(10)),
                  "temperature_2m_max_ecmwf_ifs025":\(col(10)),"temperature_2m_min_ecmwf_ifs025":\(col(0))},
         "hourly":{"time":[\(days[0])],"temperature_2m_best_match":[15],"temperature_2m_gfs_seamless":[15],"temperature_2m_ecmwf_ifs025":[15]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let d = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(d[4].high, (20 * 1.0 + 10 * 1.5) / 2.5, accuracy: 1e-9, "GFS 40 %, ECMWF 60 %")
        // The source list still shows one merged American row, weighted as GFS.
        let row = try XCTUnwrap(d[4].sources.first { $0.name.contains("GFS") })
        XCTAssertTrue(row.name.contains("Best Match"), row.name)
        XCTAssertEqual(row.weight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(d[4].sources.count, 2)
    }

    /// Outside the US best_match is its own model: a value that happens to equal GFS's keeps both votes
    /// (QA batch 1: London rain amounts matched on 213/240 hours, mostly 0 mm).
    func testNonUSBestMatchNotMergedOnCoincidence() throws {
        let t = 1_790_000_000.0
        let times = (0..<4).map { t + Double($0) * 3600 }
        let json = """
        {"latitude":51.5,"longitude":-0.13,"timezone":"Europe/London","utc_offset_seconds":3600,
         "hourly":{"time":\(times),"temperature_2m_best_match":[15.0,12.0,11.0,10.5],"temperature_2m_gfs_seamless":[15.0,13.0,12.0,11.0],
                   "temperature_2m_ecmwf_ifs025":[10.0,10,10,10],"temperature_2m_icon_seamless":[10.0,10,10,10]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let blendNow = Date(timeIntervalSince1970: t - 48 * 3600)
        let blended = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: blendNow)
        let h = try XCTUnwrap(blended.first)
        // best_match 15×2 + GFS 15×1 + ECMWF 10×1.5 + ICON 10×1
        let expected: Double = 70.0 / 5.5
        XCTAssertEqual(h.temperature, expected, accuracy: 1e-9, "GFS keeps its own vote")
    }

    func testBestMatchCopyDetection() {
        XCTAssertTrue(ForecastBlender.bestMatchIsCopy([1, 2, 3, nil], of: [[1, 2, 3, 4]]))
        XCTAssertTrue(ForecastBlender.bestMatchIsCopy([1, 2, 3, 9], of: [[1, 2, 3, nil], [nil, nil, nil, 9]]), "HRRR early, GFS later")
        XCTAssertFalse(ForecastBlender.bestMatchIsCopy([1, 2, 3, 5], of: [[1, 2, 3, 4]]), "one differing hour = independent")
        XCTAssertFalse(ForecastBlender.bestMatchIsCopy([1, 2], of: [[1, 2]]), "too few values to tell")
        XCTAssertFalse(ForecastBlender.bestMatchIsCopy([], of: [[1, 2, 3]]))
    }
}
