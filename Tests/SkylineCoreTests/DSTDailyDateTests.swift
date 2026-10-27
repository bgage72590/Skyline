import Foundation
import XCTest
@testable import SkylineCore

/// DST daily-date fix (plan-dst @8aa8ba818703). Static fixtures only; process default tz ≠ city tz.
final class DSTDailyDateTests: XCTestCase {

    // MARK: - Fixtures

    /// NYC fall-back Nov 1 2026: Open-Meteo fixed offset −14400. Days after the change arrive as
    /// 23:00 EST the previous evening (duplicate Nov 1 without the fix).
    private static let nycFallBackUnix: [TimeInterval] = [
        1_793_073_600, // 2026-10-27 04:00 UTC
        1_793_160_000,
        1_793_246_400,
        1_793_332_800,
        1_793_419_200,
        1_793_505_600, // 2026-11-01 04:00 UTC
        1_793_592_000, // intended Nov 2 — wire skew → Nov 1 23:00 EST
        1_793_678_400,
        1_793_764_800,
        1_793_851_200, // 2026-11-05 04:00 UTC
    ]

    private static let nycTZ = TimeZone(identifier: "America/New_York")!
    private static let nycOffsetEDT = -14_400

    private func nycFallBackResponse(maxes: [Double]? = nil, mins: [Double]? = nil,
                                     withHourly: Bool = false) -> OpenMeteoResponse {
        let times = Self.nycFallBackUnix
        let n = times.count
        let hi = maxes ?? (0..<n).map { 20.0 + Double($0) }
        let lo = mins ?? (0..<n).map { 10.0 + Double($0) }
        var daily: [String: [Double?]] = [
            "time": times.map { $0 },
            "temperature_2m_max_best_match": hi.map { $0 },
            "temperature_2m_min_best_match": lo.map { $0 },
            "weather_code_best_match": Array(repeating: 0, count: n),
            "precipitation_probability_max_best_match": Array(repeating: 0, count: n),
        ]
        var hourly: [String: [Double?]]? = nil
        if withHourly {
            // Hourly from Oct 27 00:00 EDT through Nov 6 00:00 EST (covers Nov 2's 24 h window).
            var ht: [Double?] = []
            var temps: [Double?] = []
            let start = Date(timeIntervalSince1970: 1_793_073_600) // Oct 27 00:00 EDT
            for h in 0..<(10 * 24 + 6) {
                let t = start.addingTimeInterval(TimeInterval(h) * 3600)
                ht.append(t.timeIntervalSince1970)
                temps.append(15)
            }
            hourly = [
                "time": ht,
                "temperature_2m_best_match": temps,
                "precipitation_probability_best_match": Array(repeating: 0, count: ht.count),
            ]
            // modelsWithData needs non-null hourly temperature.
            daily["temperature_2m_max_ecmwf_ifs025"] = hi.map { $0 }
            daily["temperature_2m_min_ecmwf_ifs025"] = lo.map { $0 }
            hourly?["temperature_2m_ecmwf_ifs025"] = temps
        }
        return OpenMeteoResponse(
            latitude: 40.71, longitude: -74.0, timezone: "America/New_York",
            utcOffsetSeconds: Self.nycOffsetEDT, hourly: hourly, daily: daily)
    }

    private func assertConsecutiveLocalDays(_ dates: [Date], count: Int, from start: DateComponents,
                                            timeZone: TimeZone, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dates.count, count, file: file, line: line)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var expected = try! XCTUnwrap(cal.date(from: start), file: file, line: line)
        expected = cal.startOfDay(for: expected)
        for (i, d) in dates.enumerated() {
            XCTAssertEqual(d, expected, "day[\(i)]", file: file, line: line)
            XCTAssertEqual(cal.startOfDay(for: d), d, "not startOfDay[\(i)]", file: file, line: line)
            let next = try! XCTUnwrap(cal.date(byAdding: .day, value: 1, to: expected), file: file, line: line)
            // Re-apply startOfDay so midnight-transition zones (01:00 → next midnight) stay correct.
            expected = cal.startOfDay(for: next)
        }
    }

    private func omDaily(timezone: String, offset: Int, unixTimes: [TimeInterval]) -> OpenMeteoResponse {
        OpenMeteoResponse(
            latitude: 0, longitude: 0, timezone: timezone, utcOffsetSeconds: offset,
            daily: ["time": unixTimes.map { $0 }])
    }

    // MARK: 1. NYC fall-back

    func testNYCFallBackDistinctConsecutiveLocalDates() {
        let om = nycFallBackResponse()
        let dates = om.dailyTimes
        assertConsecutiveLocalDays(dates, count: 10,
                                   from: DateComponents(year: 2026, month: 10, day: 27),
                                   timeZone: Self.nycTZ)
        XCTAssertEqual(Set(dates.map { $0.timeIntervalSince1970 }).count, 10)
    }

    // MARK: 2. NYC spring-forward

    func testNYCSpringForwardNoGapOrDuplicate() {
        // Fixed EST offset −18000; after Mar 8 2026 spring-forward entries land at 01:00 EDT.
        let unix: [TimeInterval] = [
            1_772_773_200, // 2026-03-06 05:00 UTC
            1_772_859_600,
            1_772_946_000, // Mar 8
            1_773_032_400, // Mar 9 → 01:00 EDT
            1_773_118_800,
        ]
        let om = omDaily(timezone: "America/New_York", offset: -18_000, unixTimes: unix)
        assertConsecutiveLocalDays(om.dailyTimes, count: 5,
                                   from: DateComponents(year: 2026, month: 3, day: 6),
                                   timeZone: Self.nycTZ)
    }

    // MARK: 3. Sydney April fall-back

    func testSydneyAprilFallBackCorrectedConsecutive() {
        // Fixed AEDT +11; after Apr 5 2026 fall-back, later days skew to 23:00 AEST prior evening.
        let unix: [TimeInterval] = [
            1_775_048_400, // 2026-04-02 00:00 AEDT
            1_775_134_800,
            1_775_221_200,
            1_775_307_600, // Apr 5
            1_775_394_000, // intended Apr 6 — skewed
            1_775_480_400,
        ]
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let om = omDaily(timezone: "Australia/Sydney", offset: 39_600, unixTimes: unix)
        assertConsecutiveLocalDays(om.dailyTimes, count: 6,
                                   from: DateComponents(year: 2026, month: 4, day: 2),
                                   timeZone: tz)
    }

    // MARK: 4. Tokyo no DST

    func testTokyoNoDSTUnchangedConsecutive() {
        let unix: [TimeInterval] = [
            1_793_458_800, 1_793_545_200, 1_793_631_600, 1_793_718_000, 1_793_804_400,
        ]
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let om = omDaily(timezone: "Asia/Tokyo", offset: 32_400, unixTimes: unix)
        let dates = om.dailyTimes
        assertConsecutiveLocalDays(dates, count: 5,
                                   from: DateComponents(year: 2026, month: 11, day: 1),
                                   timeZone: tz)
        // Already-correct input: identical to raw startOfDay of the unixtime in Tokyo.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        for (t, d) in zip(unix, dates) {
            XCTAssertEqual(d, cal.startOfDay(for: Date(timeIntervalSince1970: t)))
        }
    }

    // MARK: 5. Half-hour zones

    func testHalfHourZonesKolkataAndAdelaide() {
        let kolkataUnix: [TimeInterval] = [
            1_793_471_400, 1_793_557_800, 1_793_644_200, 1_793_730_600, 1_793_817_000,
        ]
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let omK = omDaily(timezone: "Asia/Kolkata", offset: 19_800, unixTimes: kolkataUnix)
        assertConsecutiveLocalDays(omK.dailyTimes, count: 5,
                                   from: DateComponents(year: 2026, month: 11, day: 1),
                                   timeZone: kolkata)
        var calK = Calendar(identifier: .gregorian)
        calK.timeZone = kolkata
        for (t, d) in zip(kolkataUnix, omK.dailyTimes) {
            XCTAssertEqual(d, calK.startOfDay(for: Date(timeIntervalSince1970: t)))
        }

        // Adelaide fall-back Apr 5 2026; fixed ACDT +10:30.
        let adelaideUnix: [TimeInterval] = [
            1_775_050_200, 1_775_136_600, 1_775_223_000, 1_775_309_400, 1_775_395_800, 1_775_482_200,
        ]
        let adelaide = TimeZone(identifier: "Australia/Adelaide")!
        let omA = omDaily(timezone: "Australia/Adelaide", offset: 37_800, unixTimes: adelaideUnix)
        assertConsecutiveLocalDays(omA.dailyTimes, count: 6,
                                   from: DateComponents(year: 2026, month: 4, day: 2),
                                   timeZone: adelaide)
    }

    // MARK: 6. Midnight-transition zone

    func testMidnightTransitionZoneOneEntryPerDay() {
        // America/Santiago spring-forward 2026-09-06: startOfDay is 01:00 on the transition day.
        let santiago = TimeZone(identifier: "America/Santiago")!
        // Fixed −04 (−14400) pre-spring; local midnights under that offset.
        let unix: [TimeInterval] = [
            1_788_494_400, // 2026-09-04 04:00 UTC
            1_788_580_800, // Sep 5
            1_788_667_200, // Sep 6 (startOfDay → 01:00 local)
            1_788_753_600, // Sep 7
            1_788_840_000, // Sep 8
        ]
        let om = omDaily(timezone: "America/Santiago", offset: -14_400, unixTimes: unix)
        let dates = om.dailyTimes
        XCTAssertEqual(dates.count, 5)
        XCTAssertEqual(Set(dates.map(\.timeIntervalSince1970)).count, 5)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = santiago
        let sep6 = dates[2]
        XCTAssertEqual(cal.component(.day, from: sep6), 6)
        XCTAssertEqual(cal.component(.month, from: sep6), 9)
        // Transition day: startOfDay is 01:00 local (no midnight).
        XCTAssertEqual(cal.component(.hour, from: sep6), 1)
        for d in dates {
            XCTAssertEqual(d, cal.startOfDay(for: d))
        }
        assertConsecutiveLocalDays(dates, count: 5,
                                   from: DateComponents(year: 2026, month: 9, day: 4),
                                   timeZone: santiago)
    }

    // MARK: 7. City tz ≠ Mac / process tz

    func testCityTimeZoneInjectedNotProcessCurrent() {
        // Force a non–New York process default so this is deterministic on an MBP set to NYC.
        // Never read TimeZone.current (plan forbids it in fix and tests).
        let previousDefault = NSTimeZone.default
        let foreign = TimeZone(identifier: "Asia/Tokyo")!
        NSTimeZone.default = foreign
        defer { NSTimeZone.default = previousDefault }

        XCTAssertEqual(NSTimeZone.default.identifier, "Asia/Tokyo")
        XCTAssertNotEqual(NSTimeZone.default.identifier, "America/New_York",
                          "process default tz must differ from the city tz")

        let tz = TimeZone(identifier: "America/New_York")!
        XCTAssertNotNil(tz)
        let om = nycFallBackResponse()
        XCTAssertEqual(om.timezone, "America/New_York")
        let dates = om.dailyTimes
        assertConsecutiveLocalDays(dates, count: 10,
                                   from: DateComponents(year: 2026, month: 10, day: 27),
                                   timeZone: tz)
        // City-tz result is unaffected by the foreign process default (injected IANA zone wins).
        XCTAssertNotEqual(dates[6], dates[5])
    }

    // MARK: 8. Blend alignment

    func testBlendAlignmentNov2NWSAndOMIndex() throws {
        // Distinct OM max/min per index; NWS Nov 2 daytime high is unmistakable.
        let maxes = (0..<10).map { 100.0 + Double($0) } // index 6 (Nov 2) → 106
        let mins = (0..<10).map { 50.0 + Double($0) }
        let om = nycFallBackResponse(maxes: maxes, mins: mins, withHourly: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.nycTZ
        let nov2 = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let nov2Start = cal.startOfDay(for: nov2)
        let nwsDay = NWSPeriod(
            name: "Monday", startTime: nov2Start.addingTimeInterval(6 * 3600),
            endTime: nov2Start.addingTimeInterval(18 * 3600), isDaytime: true,
            temperatureC: 33.0, probabilityOfPrecipitation: 10, relativeHumidity: nil,
            windSpeedKmh: nil, windDirection: nil, shortForecast: "Sunny", detailedForecast: "High near 91.")
        let nwsNight = NWSPeriod(
            name: "Sunday Night", startTime: nov2Start.addingTimeInterval(-6 * 3600),
            endTime: nov2Start.addingTimeInterval(6 * 3600), isDaytime: false,
            temperatureC: 12.0, probabilityOfPrecipitation: 0, relativeHumidity: nil,
            windSpeedKmh: nil, windDirection: nil, shortForecast: "Clear", detailedForecast: "")
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [nwsNight, nwsDay],
                                               timeZone: Self.nycTZ)
        let day = try XCTUnwrap(daily.first { abs($0.date.timeIntervalSince(nov2Start)) < 1 })
        XCTAssertEqual(day.date, nov2Start)
        let nws = try XCTUnwrap(day.sources.first { $0.name.hasPrefix("National Weather Service") })
        XCTAssertEqual(nws.high, 33.0)
        XCTAssertEqual(nws.low, 12.0)
        // OM Best Match column for Nov 2 is index 6 (106 / 56), not Nov 1's 105 / 55.
        let bm = try XCTUnwrap(day.sources.first { $0.name.contains("Best Match") })
        XCTAssertEqual(bm.high, 106.0)
        XCTAssertEqual(bm.low, 56.0)
        let nov1 = try XCTUnwrap(daily.first {
            abs($0.date.timeIntervalSince(cal.startOfDay(for: nov2Start.addingTimeInterval(-86400)))) < 1
        })
        XCTAssertNotEqual(nov1.sources.first { $0.name.hasPrefix("National Weather Service") }?.high, 33.0)
    }

    // MARK: 9. Day bucketing

    func testDayBucketingNov2HourlyWindow() throws {
        let om = nycFallBackResponse(withHourly: true)
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: Self.nycTZ)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.nycTZ
        let nov2 = cal.startOfDay(for: try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 2))))
        let day = try XCTUnwrap(daily.first { abs($0.date.timeIntervalSince(nov2)) < 1 })
        let now = nov2
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now.addingTimeInterval(-3600))
        let window = day.hours(from: hourly, timeZone: Self.nycTZ)
        XCTAssertEqual(window.count, 24)
        XCTAssertEqual(window.first?.time, nov2)
        let end = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: nov2))
        XCTAssertEqual(window.last?.time, end.addingTimeInterval(-3600))
        for h in window {
            XCTAssertTrue(cal.isDate(h.time, inSameDayAs: nov2))
        }
    }

    // MARK: 10. dailyIssues Best Match index

    func testDailyIssuesBestMatchIndexMatchesCorrectedDay() throws {
        let maxes = (0..<10).map { 200.0 + Double($0) }
        let mins = (0..<10).map { 100.0 + Double($0) }
        let om = nycFallBackResponse(maxes: maxes, mins: mins, withHourly: true)
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: Self.nycTZ)
        let issued = Date(timeIntervalSince1970: 1_793_073_600)
        let issues = ForecastSampler.dailyIssues(location: "nyc", issued: issued, daily: daily,
                                                 openMeteo: om, timeZone: Self.nycTZ)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.nycTZ
        let nov2 = cal.startOfDay(for: try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 2))))
        let issue = try XCTUnwrap(issues.first { abs($0.localDay.timeIntervalSince(nov2)) < 1 })
        XCTAssertEqual(issue.highs[BenchmarkForecastKind.bestMatch.rawValue], 206.0)
        XCTAssertEqual(issue.lows[BenchmarkForecastKind.bestMatch.rawValue], 106.0)
    }

    // MARK: 11. Compat scrub

    func testDSTCompatScrubKeepsAndDropsAsSpecified() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.nycTZ
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.startOfDay(for: cal.date(from: DateComponents(year: y, month: m, day: d))!)
        }
        let tzID = "America/New_York"
        func issue(loc: String, issued: Date, localDay: Date, tag: Double) -> DailyForecastIssue {
            DailyForecastIssue(loc: loc, issued: issued, localDay: localDay, timeZoneIdentifier: tzID,
                               highs: ["skyline": tag], lows: ["skyline": tag],
                               rawHourlyMaxC: tag, rawHourlyMinC: tag)
        }
        func train(loc: String, localDay: Date, tag: Double) -> TrainingRow {
            TrainingRow(loc: loc, localDay: localDay, target: .dailyHigh, sumE: tag, n: 1)
        }

        XCTAssertEqual(ForecastSampler.dstCompatLookbackDays, 10)
        XCTAssertEqual(ForecastSampler.dstFixShipDate, Date(timeIntervalSince1970: 1_793_145_600))

        // Pre-ship group with duplicated Nov 1 (and days after): drop from Nov 1 on; keep Oct 27–31.
        let preIssued = day(2026, 10, 27)
        var dupGroup: [DailyForecastIssue] = []
        for d in 27...31 {
            dupGroup.append(issue(loc: "nyc", issued: preIssued, localDay: day(2026, 10, d), tag: Double(d)))
        }
        dupGroup.append(issue(loc: "nyc", issued: preIssued, localDay: day(2026, 11, 1), tag: 1))
        dupGroup.append(issue(loc: "nyc", issued: preIssued, localDay: day(2026, 11, 1), tag: 1.5)) // dup
        dupGroup.append(issue(loc: "nyc", issued: preIssued, localDay: day(2026, 11, 2), tag: 2))
        var trains = dupGroup.map { train(loc: $0.loc, localDay: $0.localDay, tag: $0.highs["skyline"]!) }
        // Hourly training for a dropped day must be kept (only daily rows are scrubbed).
        trains.append(TrainingRow(loc: "nyc", localDay: day(2026, 11, 1), target: .h6to24, sumE: 9, n: 3, distinct: 3))

        let scrubbed = ForecastSampler.scrubDSTSkewedDailyIssues(dupGroup)
        let keptDays = Set(scrubbed.kept.map { $0.localDay.timeIntervalSince1970 })
        for d in 27...31 {
            XCTAssertTrue(keptDays.contains(day(2026, 10, d).timeIntervalSince1970), "keep Oct \(d)")
        }
        XCTAssertFalse(keptDays.contains(day(2026, 11, 1).timeIntervalSince1970))
        XCTAssertFalse(keptDays.contains(day(2026, 11, 2).timeIntervalSince1970))
        let scrubbedTrain = ForecastSampler.scrubDSTSkewedTraining(trains, dropped: scrubbed.dropped)
        XCTAssertTrue(scrubbedTrain.contains { $0.target == .h6to24 && abs($0.localDay.timeIntervalSince(day(2026, 11, 1))) < 1 })
        XCTAssertFalse(scrubbedTrain.contains { $0.target == .dailyHigh && abs($0.localDay.timeIntervalSince(day(2026, 11, 1))) < 1 })
        XCTAssertTrue(scrubbedTrain.contains { $0.target == .dailyHigh && abs($0.localDay.timeIntervalSince(day(2026, 10, 27))) < 1 })

        // Post-ship group with a duplicate day: KEPT intact.
        let postIssued = ForecastSampler.dstFixShipDate
        let postDup = [
            issue(loc: "nyc", issued: postIssued, localDay: day(2026, 11, 1), tag: 10),
            issue(loc: "nyc", issued: postIssued, localDay: day(2026, 11, 1), tag: 11),
            issue(loc: "nyc", issued: postIssued, localDay: day(2026, 11, 2), tag: 12),
        ]
        XCTAssertEqual(ForecastSampler.scrubDSTSkewedDailyIssues(postDup).kept.count, 3)

        // Pre-ship spring-forward group (Mar 2026): KEPT (window is fall-back only).
        let springIssued = day(2026, 3, 1)
        let springGroup = (6...12).map { issue(loc: "nyc", issued: springIssued, localDay: day(2026, 3, $0), tag: Double($0)) }
        XCTAssertEqual(ForecastSampler.scrubDSTSkewedDailyIssues(springGroup).kept.count, springGroup.count)

        // Pre-ship outside the 10-day window (issued Oct 15, transition Nov 1): KEPT.
        let outsideIssued = day(2026, 10, 15)
        let outside = (20...28).map { issue(loc: "nyc", issued: outsideIssued, localDay: day(2026, 10, $0), tag: Double($0)) }
        XCTAssertEqual(ForecastSampler.scrubDSTSkewedDailyIssues(outside).kept.count, outside.count)

        // Clean pre-ship group well before any transition: KEPT.
        let cleanIssued = day(2026, 6, 1)
        let clean = (1...5).map { issue(loc: "nyc", issued: cleanIssued, localDay: day(2026, 6, $0), tag: Double($0)) }
        XCTAssertEqual(ForecastSampler.scrubDSTSkewedDailyIssues(clean).kept.count, 5)

        // Window rule alone (no duplicate): drop localDay ≥ Nov 1, keep Oct 27–31.
        let windowOnly: [DailyForecastIssue] = (27...31).map {
            issue(loc: "nyc2", issued: preIssued, localDay: day(2026, 10, $0), tag: Double($0))
        } + (1...5).map {
            issue(loc: "nyc2", issued: preIssued, localDay: day(2026, 11, $0), tag: Double($0))
        }
        let win = ForecastSampler.scrubDSTSkewedDailyIssues(windowOnly)
        XCTAssertEqual(win.kept.count, 5)
        XCTAssertTrue(win.kept.allSatisfy { cal.component(.month, from: $0.localDay) == 10 })

        // BenchmarkStore load/prune applies the scrub.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dst-compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        var issueData = Data()
        for row in dupGroup {
            issueData.append(try enc.encode(row)); issueData.append(UInt8(ascii: "\n"))
        }
        try issueData.write(to: dir.appendingPathComponent("daily-issues.jsonl"))
        var trainData = Data()
        for row in trains {
            trainData.append(try enc.encode(row)); trainData.append(UInt8(ascii: "\n"))
        }
        try trainData.write(to: dir.appendingPathComponent("training.jsonl"))
        let store = BenchmarkStore(directory: dir, now: { Date(timeIntervalSince1970: 1_794_000_000) })
        let loaded = await store.dailyIssues(for: "nyc")
        XCTAssertTrue(loaded.allSatisfy { $0.localDay < day(2026, 11, 1) })
        let loadedTrain = await store.trainingRows(for: "nyc", target: .dailyHigh)
        XCTAssertFalse(loadedTrain.contains { $0.localDay >= day(2026, 11, 1) })
        let hourlyTrain = await store.trainingRows(for: "nyc", target: .h6to24)
        XCTAssertEqual(hourlyTrain.count, 1)
    }

    // MARK: 12. pairConsistent / mergePair / raw daily time

    func testPairConsistentMergePairRawDailyTimeUnchanged() throws {
        // Include hourly so A/B halves share matching `hourly.time` (pairConsistent requires it).
        let om = nycFallBackResponse(withHourly: true)
        let rawBefore = om.daily!["time"]!
        let halves = om.splitPairHalves()
        let t = Date(timeIntervalSince1970: 1_793_073_600)
        XCTAssertTrue(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t, halves.b, storedAtB: t))
        XCTAssertEqual(halves.a.daily!["time"]!, rawBefore)
        XCTAssertEqual(halves.b.daily!["time"]!, rawBefore)
        let merged = OpenMeteoResponse.mergePair(a: halves.a, b: halves.b)
        XCTAssertEqual(merged.daily!["time"]!, rawBefore)
        // Accessor corrects; wire array untouched.
        XCTAssertNotEqual(merged.dailyTimes.map(\.timeIntervalSince1970), rawBefore.map { $0! })
        XCTAssertEqual(Set(merged.dailyTimes.map(\.timeIntervalSince1970)).count, 10)
        // Byte-identical round-trip of the raw time column through encode/decode.
        let data = try OpenMeteoResponse.encode(om)
        let decoded = try OpenMeteoResponse.decode(data)
        XCTAssertEqual(decoded.daily!["time"]!, rawBefore)
        XCTAssertEqual(om.daily!["time"]!, rawBefore)
    }
}
