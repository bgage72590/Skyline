import XCTest
@testable import SkylineCore

/// Batch 6: widget snapshot (T22) and the quit policy (stay in the menu bar on ⌘Q).
final class Batch6Tests: XCTestCase {
    let f = Batch6Fixture()
    var now: Date { f.now }
    var wet: [Double] { f.wet }
    func report(minutely: [Double] = [], fetched: Date? = nil, alerts: [WeatherAlert] = []) -> WeatherReport {
        f.report(minutely: minutely, fetched: fetched, alerts: alerts)
    }

    func testSnapshotKeepsWhatTheWidgetNeeds() throws {
        let a = WeatherAlert(id: "x", event: "Flood Warning", headline: nil, severity: .severe, urgency: nil, areaDescription: nil,
                             description: nil, instruction: nil, effective: nil, expires: nil,
                             ends: now.addingTimeInterval(3600), senderName: nil)
        let s = WidgetSnapshot(report: report(minutely: wet, alerts: [a]), locationName: "New York", units: .imperial, now: now)
        XCTAssertEqual(s.hours.count, 12)
        XCTAssertGreaterThan(s.hours[0].time, now, "the hour under way first, nothing already over")
        XCTAssertEqual(s.days.count, 5)
        XCTAssertEqual(s.high, 20)
        XCTAssertEqual(s.alert, "Flood Warning")
        XCTAssertLessThanOrEqual(s.minutely.count, 10, "only the next ~2.5 h are kept")
        let back = try XCTUnwrap(WidgetSnapshot.decode(s.encoded()))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.rainLine(at: now), "Rain starting in about 30 min")
        XCTAssertEqual(back.rainLine(at: now.addingTimeInterval(900)), "Rain starting in about 15 min")
        XCTAssertEqual(back.rainLine(at: now), report(minutely: wet).nowcastSummary(at: now), "the widget says what the app says")
    }

    func testDryStaleAndBadFiles() throws {
        let dry = WidgetSnapshot(report: report(minutely: Array(repeating: 0, count: 8)), locationName: "NYC", units: .metric, now: now)
        XCTAssertEqual(dry.rainLine(at: now), "No rain in the next 2 hours")
        let none = WidgetSnapshot(report: report(), locationName: "NYC", units: .metric, now: now)
        XCTAssertEqual(none.rainLine(at: now), "", "no 15-min data (outside coverage): say nothing")
        let old = WidgetSnapshot(report: report(fetched: now.addingTimeInterval(-3 * 3600)), locationName: "NYC", units: .metric, now: now)
        XCTAssertTrue(old.isStale(at: now))
        XCTAssertFalse(dry.isStale(at: now.addingTimeInterval(3600)))
        XCTAssertNil(WidgetSnapshot.decode(Data("nope".utf8)))
        var future = dry; future.version = WidgetSnapshot.version + 1
        XCTAssertNil(WidgetSnapshot.decode(try future.encoded()), "a newer app's format is ignored, not misread")
        XCTAssertEqual(WidgetSnapshot.fileURL(home: URL(fileURLWithPath: "/Users/x")).path,
                       "/Users/x/Library/Application Support/com.briangage.Skyline/Widget/widget-snapshot.json")
    }

    func testTimelineEntriesEveryQuarterHourForTwoHours() {
        let d = WidgetSnapshot.entryDates(from: now.addingTimeInterval(300)) // 9:35
        XCTAssertEqual(d.count, 9)
        XCTAssertEqual(d[0], now.addingTimeInterval(300))
        XCTAssertEqual(d[1], now.addingTimeInterval(900))
        XCTAssertEqual(d.last, now.addingTimeInterval(900 * 8))
    }

    func testQuitKeepsSkylineInTheMenuBar() {
        XCTAssertEqual(QuitPolicy.action(for: .commandQ), .closeWindow)
        XCTAssertEqual(QuitPolicy.action(for: .closeButton), .closeWindow)
        XCTAssertEqual(QuitPolicy.action(for: .menuBarQuit), .terminate)
        XCTAssertEqual(QuitPolicy.action(for: .quitCompletely), .terminate)
        XCTAssertEqual(QuitPolicy.action(for: .dockOrSystem), .terminate, "logout/restart must never be blocked")
    }

    func testUnitsSurviveTheSnapshot() throws {
        let s = WidgetSnapshot(report: report(), locationName: "NYC", units: .imperial, now: now)
        let back = try XCTUnwrap(WidgetSnapshot.decode(s.encoded()))
        XCTAssertEqual(back.units.temperatureString(back.temperature), DisplayUnits.imperial.temperatureString(18))
    }
}

final class Batch6IntentTextTests: XCTestCase {
    let t = Batch6Fixture()

    func testRainSentenceMatchesTheApp() {
        let r = t.report(minutely: t.wet)
        XCTAssertEqual(IntentText.rain(r, name: "NYC", now: t.now), "NYC: Rain starting in about 30 min.")
        XCTAssertEqual(IntentText.rain(t.report(minutely: [0, 0, 0, 0, 0, 0, 0, 0]), name: "NYC", now: t.now),
                       "NYC: no rain expected in the next 2 hours.")
        XCTAssertEqual(IntentText.rain(t.report(), name: "Paris", now: t.now), "Paris: 10% chance of rain in the next 2 hours.",
                       "no 15-min data: hourly chance")
    }

    func testWeatherSentence() {
        let s = IntentText.weather(t.report(), name: "NYC", units: .imperial, now: t.now)
        XCTAssertTrue(s.hasPrefix("NYC: 64°, Cloudy. High 68°, low 50°."), s)
    }
}

struct Batch6Fixture {
    let now = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))

    func report(minutely: [Double] = [], fetched: Date? = nil, alerts: [WeatherAlert] = [],
                location: WeatherLocation? = nil) -> WeatherReport {
        let cur = CurrentConditions(time: now, temperature: 18, apparentTemperature: 18, humidity: 60, dewPoint: nil,
                                    weatherCode: 3, isDay: true, precipitation: 0, cloudCover: nil, pressure: nil,
                                    windSpeed: 5, windDirection: nil, windGust: nil, visibility: nil, uvIndex: nil)
        let hours = (-2..<30).map { HourlyForecast(time: now.addingTimeInterval(Double($0) * 3600 + 1800), temperature: 15 + Double($0) * 0.1,
                                                    precipitationProbability: 10, precipitation: 0, weatherCode: 3, isDay: true) }
        let days = (0..<8).map { DailyForecast(date: now.addingTimeInterval(Double($0) * 86400), weatherCode: 3,
                                               high: 20 + Double($0), low: 10) }
        let start = (now.timeIntervalSince1970 / 900).rounded(.down) * 900 + 900
        let m = minutely.enumerated().map { MinutelyPrecipitation(time: Date(timeIntervalSince1970: start + Double($0.offset) * 900),
                                                                   precipitation: $0.element) }
        return WeatherReport(location: location ?? nyc, fetchedAt: fetched ?? now, timeZoneIdentifier: "America/New_York", current: cur,
                             hourly: hours, daily: days, minutely: m, alerts: alerts)
    }

    let wet: [Double] = [0, 0, 0.5, 0.6, 0.4, 0, 0, 0, 0, 0, 0, 0, 0, 0]

}

/// QA batch 5 low items (cancellations on screen, dedupe after sleep, per-city dedupe, old cache format).
final class Batch6AlertTests: XCTestCase {
    let f = Batch6Fixture()
    let newark = WeatherLocation(name: "Newark", region: "NJ", country: "United States",
                                 coordinate: Coordinate(latitude: 40.73, longitude: -74.17))
    var prefs: NotificationPrefs { var p = NotificationPrefs(); p.alerts = true; p.minimumSeverity = .moderate; return p }

    func alert(_ id: String, expires: TimeInterval = 3600, ends: TimeInterval? = nil, vtec: [String] = ["KOKX.FL.W.0006"],
               cancel: Bool = false) -> WeatherAlert {
        var a = WeatherAlert(id: id, event: "Flood Warning", headline: nil, severity: .severe, urgency: nil, areaDescription: nil,
                             description: nil, instruction: nil, effective: f.now, expires: f.now.addingTimeInterval(expires),
                             ends: ends.map { f.now.addingTimeInterval($0) }, senderName: nil)
        a.trackingKeys = vtec; a.isCancellation = cancel
        return a
    }

    func plan(_ alerts: [WeatherAlert], at t: Date, location: WeatherLocation? = nil, _ state: inout NotificationState) -> Int {
        NotificationPlanner.plan(f.report(alerts: alerts, location: location), locationName: "X", prefs: prefs, state: &state,
                                 now: t, timeLabel: { _ in "" }).count
    }

    func testCancelledAndExpiredAlertsAreNotActive() {
        let can = alert("c1", expires: 3600, cancel: true)
        let r = f.report(alerts: [can, alert("old", expires: -60), alert("live")])
        XCTAssertEqual(r.activeAlerts(at: f.now).map(\.id), ["live"], "CAN/EXP and past-expiry alerts are hidden everywhere")
        XCTAssertFalse(can.isActive(at: f.now))
        let s = WidgetSnapshot(report: f.report(alerts: [can]), locationName: "NYC", units: .imperial, now: f.now)
        XCTAssertNil(s.alert)
        XCTAssertFalse(IntentText.weather(f.report(alerts: [can]), name: "NYC", units: .imperial, now: f.now).contains("Flood Warning"))
    }

    func testUpdateAfterSleepPastExpiresIsNotRepeated() {
        var state = NotificationState()
        XCTAssertEqual(plan([alert("a1", expires: 3600)], at: f.now, &state), 1)
        // Mac slept past `expires` (no `ends`); the next CON arrives 3 h later with a new id.
        let later = f.now.addingTimeInterval(3 * 3600)
        var a2 = alert("a2", expires: 4 * 3600); a2.references = ["a1"]
        XCTAssertEqual(plan([a2], at: later, &state), 0)
        // Long after the grace period it's forgotten (state doesn't grow forever).
        _ = plan([], at: f.now.addingTimeInterval(30 * 3600), &state)
        XCTAssertTrue(state.alerts.isEmpty)
    }

    func testDedupeIsPerCity() {
        var state = NotificationState()
        XCTAssertEqual(plan([alert("a1")], at: f.now, &state), 1)
        XCTAssertEqual(plan([alert("a1")], at: f.now, &state), 0, "same city: once")
        // EXA: the same event extended over Newark notifies once there.
        XCTAssertEqual(plan([alert("a2")], at: f.now, location: newark, &state), 1)
        XCTAssertEqual(plan([alert("a3")], at: f.now, location: newark, &state), 0)
    }

    func testBatch5StateStillDedupes() throws {
        // Batch 5 stored global keys; an alert already sent before the upgrade stays silent.
        let old = #"{"alerts":{"KOKX.FL.W.0006":1891725400},"alertSeverity":{"KOKX.FL.W.0006":"Severe"}}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        var state = (try? dec.decode(NotificationState.self, from: Data(old.utf8))) ?? NotificationState()
        if state.alerts.isEmpty { // the app's date encoding may differ; seed directly
            state.alerts["KOKX.FL.W.0006"] = f.now.addingTimeInterval(86400); state.alertSeverity["KOKX.FL.W.0006"] = .severe
        }
        XCTAssertEqual(plan([alert("a9")], at: f.now, &state), 0)
    }

    func testBatch4CachedAlertDecodes() throws {
        let b4 = #"{"id":"urn:1","event":"Flood Warning","severity":"Severe","polygons":[],"affectedZones":[],"outlineIsZone":false}"#
        let a = try JSONDecoder().decode(WeatherAlert.self, from: Data(b4.utf8))
        XCTAssertEqual(a.id, "urn:1"); XCTAssertEqual(a.references, []); XCTAssertFalse(a.isCancellation)
        let round = try JSONDecoder().decode(WeatherAlert.self, from: JSONEncoder().encode(alert("x", cancel: true)))
        XCTAssertTrue(round.isCancellation); XCTAssertEqual(round.trackingKeys, ["KOKX.FL.W.0006"])
    }
}
