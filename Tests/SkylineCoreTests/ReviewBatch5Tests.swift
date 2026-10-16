import XCTest
@testable import SkylineCore

/// Code-review checks for batch 5. First block: batch 4 M1 (VTEC / references dedupe) and M2
/// (cancellations never notify), exercised through the real NWS parser and the planner.
final class ReviewBatch5Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_725_400) // 09:30 ET Oct 11 2026
    let ny = TimeZone(identifier: "America/New_York")!
    let loc = WeatherLocation(name: "Home", region: "CT", country: "United States",
                              coordinate: Coordinate(latitude: 41.14, longitude: -73.26))
    let label: @Sendable (Date) -> String = { d in
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "America/New_York"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"; return f.string(from: d)
    }

    func report(alerts: [WeatherAlert], at t: Date) -> WeatherReport {
        let cur = CurrentConditions(time: t, temperature: 12, apparentTemperature: 12, humidity: 60, dewPoint: nil, weatherCode: 3,
                                    isDay: true, precipitation: 0, cloudCover: nil, pressure: nil, windSpeed: 5, windDirection: nil,
                                    windGust: nil, visibility: nil, uvIndex: nil)
        return WeatherReport(location: loc, fetchedAt: t, timeZoneIdentifier: "America/New_York", current: cur,
                             hourly: [], daily: [], minutely: [], alerts: alerts)
    }
    var prefs: NotificationPrefs { var p = NotificationPrefs(); p.alerts = true; p.minimumSeverity = .minor; p.quietHours = false; return p }

    /// One /alerts/active feature. `vtec: nil` = no VTEC parameter at all (Special Weather Statement).
    func feature(_ id: String, _ type: String = "Alert", refs: [String] = [], vtec: [String]?, event: String = "Flood Warning",
                 severity: String = "Severe", ends: String = "2026-10-14T02:00:00-04:00") -> String {
        let r = refs.map { "{\"identifier\":\"\($0)\",\"@id\":\"x\",\"sender\":\"w-nws\",\"sent\":\"2026-10-11T09:25:00-04:00\"}" }
        let params = vtec.map { v in ",\"parameters\":{\"VTEC\":[\(v.map { "\"\($0)\"" }.joined(separator: ","))]}" } ?? ",\"parameters\":{}"
        return """
        {"type":"Feature","geometry":null,"properties":{"id":"\(id)","event":"\(event)","headline":"\(event) issued by NWS",
         "severity":"\(severity)","status":"Actual","messageType":"\(type)","references":[\(r.joined(separator: ","))],
         "effective":"2026-10-11T09:25:00-04:00","expires":"2026-10-12T09:30:00-04:00","ends":"\(ends)"\(params)}}
        """
    }
    func parse(_ features: [String], now: Date) throws -> [WeatherAlert] {
        try NWSAlertParser.decode(Data("{\"features\":[\(features.joined(separator: ","))]}".utf8), now: now)
    }
    @discardableResult
    func plan(_ features: [String], _ state: inout NotificationState, at t: Date, prefs p: NotificationPrefs? = nil) throws -> [PlannedNotification] {
        NotificationPlanner.plan(report(alerts: try parse(features, now: t), at: t), locationName: "Home", prefs: p ?? prefs,
                                 state: &state, now: t, timeZone: ny, timeLabel: label)
    }
    func h(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

    // MARK: M1

    /// NEW → CON → EXT → EXA → CON, each a new id referencing the previous one: one notification.
    func testFullUpdateChainNotifiesOnce() throws {
        var s = NotificationState()
        XCTAssertEqual(try plan([feature("A", vtec: ["/O.NEW.KOKX.FL.W.0006.261011T1325Z-261014T0600Z/"])], &s, at: t0).count, 1)
        XCTAssertTrue(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])], &s, at: h(3)).isEmpty)
        XCTAssertTrue(try plan([feature("C", "Update", refs: ["B"], vtec: ["/O.EXT.KOKX.FL.W.0006.000000T0000Z-261015T0600Z/"],
                                        ends: "2026-10-15T02:00:00-04:00")], &s, at: h(6)).isEmpty)
        XCTAssertTrue(try plan([feature("D", "Update", refs: ["C"], vtec: ["/O.EXA.KOKX.FL.W.0006.000000T0000Z-261015T0600Z/"],
                                        ends: "2026-10-15T02:00:00-04:00")], &s, at: h(9)).isEmpty)
        // Extension moved the dedupe expiry out with it: still silent after the original end time.
        XCTAssertTrue(try plan([feature("E", "Update", refs: ["D"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261015T0600Z/"],
                                        ends: "2026-10-15T02:00:00-04:00")], &s, at: h(66)).isEmpty, "re-notified after the EXT")
    }

    /// Old and new messages both still in /alerts/active in the same refresh: one notification.
    func testOriginalAndUpdateInSameFeed() throws {
        var s = NotificationState()
        let n = try plan([feature("A", vtec: ["/O.NEW.KOKX.SV.W.0101.261011T1325Z-261011T1500Z/"], event: "Severe Thunderstorm Warning",
                                  ends: "2026-10-11T11:00:00-04:00"),
                          feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.SV.W.0101.000000T0000Z-261011T1500Z/"],
                                  event: "Severe Thunderstorm Warning", ends: "2026-10-11T11:00:00-04:00")], &s, at: t0)
        XCTAssertEqual(n.count, 1, "\(n.map(\.id))")
    }

    /// Missed the original (e.g. Skyline not running): the first update seen still notifies once.
    func testFirstSeenUpdateNotifiesOnce() throws {
        var s = NotificationState()
        XCTAssertEqual(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])], &s, at: t0).count, 1)
        XCTAssertTrue(try plan([feature("C", "Update", refs: ["B"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])], &s, at: h(2)).isEmpty)
    }

    /// Two VTEC lines: one event ends (EXP), another continues (CON, already sent) → silent, not a cancellation.
    /// One ends (CAN) and a new one starts (NEW, new ETN) → notifies.
    func testMultipleVTECLines() throws {
        var s = NotificationState()
        try plan([feature("A", vtec: ["/O.NEW.KOKX.FL.W.0006.261011T1325Z-261014T0600Z/"])], &s, at: t0)
        let mixed = try parse([feature("B", "Update", refs: ["A"], vtec: ["/O.EXP.KOKX.FL.W.0005.000000T0000Z-261011T1400Z/",
                                                                         "/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])], now: h(1))
        XCTAssertEqual(mixed.first?.isCancellation, false)
        XCTAssertEqual(mixed.first?.trackingKeys, ["KOKX.FL.W.0006"])
        XCTAssertTrue(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.EXP.KOKX.FL.W.0005.000000T0000Z-261011T1400Z/",
                                                                         "/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])], &s, at: h(1)).isEmpty)
        let n = try plan([feature("C", "Update", refs: ["B"], vtec: ["/O.CAN.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/",
                                                                     "/O.NEW.KOKX.FL.W.0007.261011T1600Z-261015T0600Z/"])], &s, at: h(2))
        XCTAssertEqual(n.count, 1, "a new event in a mixed message must notify")
    }

    /// The real upgrade message: UPG line for the watch plus NEW line for the warning.
    func testWatchToWarningUpgradeMessage() throws {
        var s = NotificationState()
        XCTAssertEqual(try plan([feature("W", vtec: ["/O.NEW.KOKX.WS.A.0003.261012T0000Z-261013T0000Z/"], event: "Winter Storm Watch",
                                         severity: "Moderate")], &s, at: t0).count, 1)
        let up = try parse([feature("X", "Update", refs: ["W"], vtec: ["/O.UPG.KOKX.WS.A.0003.261012T0000Z-261013T0000Z/",
                                                                       "/O.NEW.KOKX.WS.W.0005.261012T0000Z-261013T0000Z/"],
                                    event: "Winter Storm Warning")], now: h(6))
        XCTAssertEqual(up.first?.isCancellation, false)
        XCTAssertEqual(up.first?.trackingKeys, ["KOKX.WS.W.0005"])
        XCTAssertEqual(try plan([feature("X", "Update", refs: ["W"], vtec: ["/O.UPG.KOKX.WS.A.0003.261012T0000Z-261013T0000Z/",
                                                                            "/O.NEW.KOKX.WS.W.0005.261012T0000Z-261013T0000Z/"],
                                         event: "Winter Storm Warning")], &s, at: h(6)).count, 1)
    }

    /// Same office, same phenomenon, different event number: a separate warning, notifies.
    func testNewETNSameOfficeNotifies() throws {
        var s = NotificationState()
        try plan([feature("A", vtec: ["/O.NEW.KOKX.SV.W.0101.261011T1325Z-261011T1500Z/"], event: "Severe Thunderstorm Warning")], &s, at: t0)
        XCTAssertEqual(try plan([feature("B", vtec: ["/O.NEW.KOKX.SV.W.0102.261011T1400Z-261011T1530Z/"],
                                         event: "Severe Thunderstorm Warning")], &s, at: h(0.5)).count, 1)
        // Same ETN from another office is a different event too.
        XCTAssertEqual(try plan([feature("C", vtec: ["/O.NEW.KALY.SV.W.0101.261011T1400Z-261011T1530Z/"],
                                         event: "Severe Thunderstorm Warning")], &s, at: h(0.6)).count, 1)
    }

    /// No VTEC (Special Weather Statement): falls back to id + references. Not suppressed.
    func testNoVTECFallsBackToIDAndReferences() throws {
        var s = NotificationState()
        let sps = try parse([feature("S1", vtec: nil, event: "Special Weather Statement", severity: "Moderate")], now: t0)
        XCTAssertEqual(sps.first?.trackingKeys, [])
        XCTAssertEqual(sps.first?.isCancellation, false)
        XCTAssertEqual(try plan([feature("S1", vtec: nil, event: "Special Weather Statement", severity: "Moderate")], &s, at: t0).count, 1)
        XCTAssertTrue(try plan([feature("S1", vtec: nil, event: "Special Weather Statement", severity: "Moderate")], &s, at: h(0.25)).isEmpty)
        XCTAssertTrue(try plan([feature("S2", "Update", refs: ["S1"], vtec: nil, event: "Special Weather Statement", severity: "Moderate")],
                               &s, at: h(0.5)).isEmpty, "update of a sent SPS re-notified")
        XCTAssertEqual(try plan([feature("S3", vtec: nil, event: "Special Weather Statement", severity: "Moderate")], &s, at: h(1)).count, 1,
                       "unrelated SPS suppressed")
        // An H-VTEC-only / malformed VTEC value is ignored, not treated as a key.
        let odd = try parse([feature("S4", vtec: ["/00000.N.ER.000000T0000Z.000000T0000Z.000000T0000Z.OO/", "garbage"])], now: t0)
        XCTAssertEqual(odd.first?.trackingKeys, [])
        XCTAssertEqual(odd.first?.isCancellation, false)
    }

    /// QA rule on top of M1: an update re-notifies only when its severity rises, and only once.
    func testSeverityRiseOnSameEvent() throws {
        var s = NotificationState()
        try plan([feature("A", vtec: ["/O.NEW.KOKX.FF.W.0009.261011T1325Z-261011T1800Z/"], event: "Flash Flood Warning")], &s, at: t0)
        XCTAssertEqual(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.FF.W.0009.000000T0000Z-261011T1800Z/"],
                                         event: "Flash Flood Warning", severity: "Extreme")], &s, at: h(0.5)).count, 1)
        XCTAssertTrue(try plan([feature("C", "Update", refs: ["B"], vtec: ["/O.CON.KOKX.FF.W.0009.000000T0000Z-261011T1800Z/"],
                                        event: "Flash Flood Warning", severity: "Extreme")], &s, at: h(1)).isEmpty)
        XCTAssertTrue(try plan([feature("D", "Update", refs: ["C"], vtec: ["/O.CON.KOKX.FF.W.0009.000000T0000Z-261011T1800Z/"],
                                        event: "Flash Flood Warning", severity: "Severe")], &s, at: h(1.5)).isEmpty, "downgrade notified")
    }

    // MARK: M2

    func testCancellationsNeverNotify() throws {
        let cases: [(String, String, [String]?)] = [
            ("messageType Cancel, no VTEC", "Cancel", nil),
            ("messageType Cancel + CAN", "Cancel", ["/O.CAN.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/"]),
            ("Update + CAN only", "Update", ["/O.CAN.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/"]),
            ("Update + EXP only", "Update", ["/O.EXP.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/"]),
            ("Update + CAN and EXP lines", "Update", ["/O.CAN.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/",
                                                     "/O.EXP.KRAH.TO.W.0011.000000T0000Z-261011T1400Z/"]),
        ]
        for (name, type, vtec) in cases {
            // Original never notified (state empty), Extreme severity (which even passes quiet hours), quiet hours on.
            var s = NotificationState()
            var p = prefs; p.quietHours = true; p.quietStartMinutes = 0; p.quietEndMinutes = 23 * 60 + 59
            let a = try parse([feature("C", type, refs: ["T"], vtec: vtec, event: "Tornado Warning", severity: "Extreme",
                                       ends: "2026-10-11T12:00:00-04:00")], now: t0)
            XCTAssertTrue(a.isEmpty || a.allSatisfy(\.isCancellation), name) // batch 6 drops them at parse
            XCTAssertTrue(try plan([feature("C", type, refs: ["T"], vtec: vtec, event: "Tornado Warning", severity: "Extreme",
                                            ends: "2026-10-11T12:00:00-04:00")], &s, at: t0, prefs: p).isEmpty, name)
            XCTAssertTrue(try plan([feature("C", type, refs: ["T"], vtec: vtec, event: "Tornado Warning", severity: "Extreme",
                                            ends: "2026-10-11T12:00:00-04:00")], &s, at: t0).isEmpty, name + " (no quiet hours)")
        }
        // After a sent warning, its cancellation is silent too, and a *new* warning afterwards still notifies.
        var s = NotificationState()
        try plan([feature("T", vtec: ["/O.NEW.KRAH.TO.W.0010.261011T1325Z-261011T1400Z/"], event: "Tornado Warning", severity: "Extreme",
                          ends: "2026-10-11T10:00:00-04:00")], &s, at: t0)
        XCTAssertTrue(try plan([feature("C", "Cancel", refs: ["T"], vtec: ["/O.CAN.KRAH.TO.W.0010.000000T0000Z-261011T1400Z/"],
                                        event: "Tornado Warning", severity: "Extreme", ends: "2026-10-11T10:00:00-04:00")], &s, at: h(0.1)).isEmpty)
        XCTAssertEqual(try plan([feature("N", vtec: ["/O.NEW.KRAH.TO.W.0011.261011T1340Z-261011T1430Z/"], event: "Tornado Warning",
                                         severity: "Extreme", ends: "2026-10-11T10:30:00-04:00")], &s, at: h(0.15)).count, 1)
    }

    // MARK: Dedupe store

    func testDedupeStoreSurvivesRelaunchAndUpgrade() throws {
        var s = NotificationState()
        try plan([feature("A", vtec: ["/O.NEW.KOKX.FL.W.0006.261011T1325Z-261014T0600Z/"])], &s, at: t0)
        var restored = try JSONDecoder().decode(NotificationState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(restored, s)
        XCTAssertTrue(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])],
                               &restored, at: h(1)).isEmpty, "re-notified after relaunch")
        // State saved by the batch 4 build (no alertSeverity): decodes, and an update stays silent.
        let iso = ISO8601DateFormatter()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .deferredToDate
        let old = "{\"alerts\":{\"A\":\(h(64).timeIntervalSinceReferenceDate),\"KOKX.FL.W.0006\":\(h(64).timeIntervalSinceReferenceDate)},\"rain\":{},\"briefingDay\":{}}"
        _ = iso; _ = enc
        var migrated = try JSONDecoder().decode(NotificationState.self, from: Data(old.utf8))
        XCTAssertEqual(migrated.alerts.count, 2)
        XCTAssertTrue(try plan([feature("B", "Update", refs: ["A"], vtec: ["/O.CON.KOKX.FL.W.0006.000000T0000Z-261014T0600Z/"])],
                               &migrated, at: h(1)).isEmpty)
        // Garbage decodes to an empty state rather than throwing.
        XCTAssertEqual(try JSONDecoder().decode(NotificationState.self, from: Data("{\"alerts\":5}".utf8)).alerts.count, 0)
    }

    func testDedupeStoreIsBounded() throws {
        var s = NotificationState()
        for i in 0..<500 {
            let t = t0.addingTimeInterval(Double(i) * 600)
            let end = ISO8601DateFormatter().string(from: t.addingTimeInterval(3600))
            try plan([feature("id\(i)", vtec: [String(format: "/O.NEW.KOKX.SV.W.%04d.261011T1325Z-261011T1500Z/", i)],
                              event: "Severe Thunderstorm Warning", ends: end)], &s, at: t)
            XCTAssertLessThanOrEqual(s.alerts.count, 2 * 80, "store growing at \(i): \(s.alerts.count)")
            XCTAssertLessThanOrEqual(s.alertSeverity.count, s.alerts.count)
        }
        try plan([], &s, at: t0.addingTimeInterval(600 * 500 + 14 * 3600))
        XCTAssertEqual(s.alerts.count, 0)
        XCTAssertEqual(s.alertSeverity.count, 0)
        // An alert without an end time is kept 24 h, not forever.
        var s2 = NotificationState()
        let noEnd = feature("Z", vtec: nil, event: "Special Weather Statement", severity: "Moderate").replacingOccurrences(of: "\"ends\":\"2026-10-14T02:00:00-04:00\"", with: "\"ends\":null")
        XCTAssertEqual(try plan([noEnd], &s2, at: t0).count, 1)
        try plan([], &s2, at: h(37))
        XCTAssertEqual(s2.alerts.count, 0)
    }

    // MARK: L2 regression (batch 5): a remembered /points 404 also drops the warnings

    func testPoints404DoesNotHideWarnings() async throws {
        final class Points404: HTTPClient, @unchecked Sendable {
            let inner = MockHTTPClient()
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                if url.absoluteString.contains("api.weather.gov/points") { throw HTTPError.status(404, url) }
                return try await inner.get(url, headers: headers)
            }
        }
        let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400)
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: Points404(), cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let coastal = WeatherLocation(name: "Coast", region: "NY", country: "United States",
                                      coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
        let r1 = try await service.report(for: coastal)
        XCTAssertFalse(r1.alerts.isEmpty, "first refresh")
        clock.now = fixtureTime.addingTimeInterval(20 * 60)
        let r2 = try await service.report(for: coastal, forceRefresh: true)
        XCTAssertFalse(r2.alerts.isEmpty, "warnings vanished for a week after one /points 404")
    }

    // MARK: Coverage border cases beyond Batch5Tests

    func testMoreBorderCases() {
        func c(_ a: Double, _ b: Double) -> Coordinate { Coordinate(latitude: a, longitude: b) }
        var report: [String] = []
        let cases: [(String, Coordinate, Bool, Bool)] = [ // name, point, expected CONUS, expected NWS
            ("Sault Ste. Marie MI", c(46.495, -84.345), true, true), ("Sault Ste. Marie ON", c(46.53, -84.33), false, false),
            ("Niagara Falls NY", c(43.095, -79.04), true, true), ("Niagara Falls ON", c(43.09, -79.08), false, false),
            ("Point Roberts WA", c(48.985, -123.06), true, true), ("Friday Harbor WA", c(48.53, -123.02), true, true),
            ("Nantucket", c(41.28, -70.10), true, true), ("Hatteras", c(35.22, -75.69), true, true), ("Avalon (Catalina)", c(33.34, -118.33), true, true),
            ("Bimini (Bahamas)", c(25.73, -79.27), false, false), ("Ketchikan", c(55.34, -131.64), false, true), ("Sitka", c(57.05, -135.33), false, true),
            ("Prince Rupert BC", c(54.31, -130.32), false, false), ("San Juan PR", c(18.47, -66.11), false, true), ("St Croix", c(17.73, -64.75), false, true),
            ("Guam", c(13.44, 144.79), false, true), ("Hilo", c(19.72, -155.08), false, true),
            ("Adak AK (Aleutians)", c(51.88, -176.66), false, true), ("Pago Pago (Am. Samoa)", c(-14.28, -170.70), false, true),
            ("Northwest Angle MN", c(49.35, -95.07), true, true), ("Calais ME", c(45.18, -67.27), true, true),
        ]
        for (name, p, conus, nws) in cases {
            if p.isInCONUS != conus || p.isLikelyInNWSCoverage != nws {
                report.append("\(name): CONUS \(p.isInCONUS) (want \(conus)), NWS \(p.isLikelyInNWSCoverage) (want \(nws))")
            }
        }
        print("[review] border mismatches:\n  " + report.joined(separator: "\n  "))
        // Only the ones that matter for real users are asserted; the rest are reported.
        for name in ["Sault Ste. Marie MI", "Niagara Falls NY", "Nantucket", "Hatteras", "Ketchikan", "San Juan PR", "Guam", "Hilo", "Bimini (Bahamas)",
                     "Prince Rupert BC"] {
            XCTAssertFalse(report.contains { $0.hasPrefix(name + ":") }, name)
        }
    }

    // MARK: T13 / misc

    func testSnowConversionsAndType() {
        var u = DisplayUnits(temperature: .fahrenheit, speed: .mph, precipitation: .inches, pressure: .inHg, distance: .miles)
        XCTAssertEqual(u.snowString(2.54), "1 in")
        XCTAssertEqual(u.snowString(1.0), "0.4 in")
        u.precipitation = .millimetres
        XCTAssertEqual(u.snowString(12.4), "12 cm")
        // 7 cm snow ≈ 10 mm water: all snow → snow icon; rain-only at +5 °C → rain; mixed 40 % → unchanged.
        XCTAssertEqual(ForecastBlender.precipitationType(63, snowfall: 7, precipitation: 10, temperature: -1), 73)
        XCTAssertEqual(ForecastBlender.precipitationType(73, snowfall: 0, precipitation: 10, temperature: 5), 63)
        XCTAssertEqual(ForecastBlender.precipitationType(61, snowfall: 2.8, precipitation: 10, temperature: 0.5), 61)
        XCTAssertEqual(ForecastBlender.precipitationType(95, snowfall: 7, precipitation: 10, temperature: -1), 95, "thunder left alone")
        XCTAssertEqual(ForecastBlender.precipitationType(66, snowfall: 0, precipitation: 10, temperature: 1), 66, "freezing rain left alone")
    }

    func testHRRRFramesTimeAlignmentAndBounds() {
        let iso = ISO8601DateFormatter()
        let initT = iso.date(from: "2026-10-12T01:00:00Z")!
        let latest = iso.date(from: "2026-10-12T02:55:00Z")!
        let f = IEMHRRR.frames(initTime: initT, after: latest)
        XCTAssertEqual(f.count, 6)
        XCTAssertTrue(f.allSatisfy { $0.isForecast && $0.time > latest })
        XCTAssertEqual(f.first?.urlTemplate, "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::REFP-F0120-202610120100/{z}/{x}/{y}.png")
        XCTAssertEqual(f.first?.time, iso.date(from: "2026-10-12T03:00:00Z"))
        // A run 17 h old: frames past F1080 are dropped, not requested (IEM answers 503 for them).
        let old = IEMHRRR.frames(initTime: iso.date(from: "2026-10-11T10:00:00Z")!, after: latest)
        XCTAssertTrue(old.allSatisfy { $0.urlTemplate.contains("F10") || $0.urlTemplate.contains("F09") })
        XCTAssertLessThan(old.count, 6)
    }
}
