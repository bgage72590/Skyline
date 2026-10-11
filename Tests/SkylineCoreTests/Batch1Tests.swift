import XCTest
@testable import SkylineCore

/// Regression tests for batch 1 (F1–F8). Fairfield fixtures are the live responses QA captured on
/// Sun Oct 11, 2026 at 4:57 PM ET (Open-Meteo multi-model + NWS OKX 55,65 forecast).
final class Batch1Tests: XCTestCase {
    let ny = TimeZone(identifier: "America/New_York")!
    /// 2026-10-11 09:30 ET: after the NYC fixtures were generated (09:13 ET), before the fixture
    /// Tornado Warning expires (10:00 ET).
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400)

    func period(_ name: String, _ start: Date, hours: Double, day: Bool, t: Double = 15, pop: Double? = nil,
                short: String = "") -> NWSPeriod {
        NWSPeriod(name: name, startTime: start, endTime: start.addingTimeInterval(hours * 3600), isDaytime: day,
                  temperatureC: t, probabilityOfPrecipitation: pop, relativeHumidity: nil, windSpeedKmh: nil,
                  windDirection: nil, shortForecast: short, detailedForecast: "")
    }

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: F1 previous evening's rain chance

    /// Live Fairfield, Mon Oct 12: NWS "Mostly Sunny" 9 % (96 % the night before). Was 73 % + Light Rain.
    func testFairfieldMondayRainChanceAndIcon() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_fairfield"))
        let nws = try NWSPeriod.decodeList(try Fixture.data("nws_fairfield_forecast"))
        let now = try XCTUnwrap(om.currentConditions()).time
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: now)
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: ny, hourly: hourly)
        let monday = try XCTUnwrap(daily.first { $0.date == day(2026, 10, 12) })
        let pop = try XCTUnwrap(monday.precipitationProbability)
        print("[batch1] Fairfield Mon Oct 12 pop=\(pop) code=\(monday.weatherCode) \(monday.condition.description)")
        XCTAssertLessThan(pop, 30, "Sunday night's 96 % must not leak into Monday")
        XCTAssertFalse(monday.condition.isPrecipitation, "Mostly Sunny day must not get a rain icon")
        XCTAssertEqual(monday.weatherCode, 1, "follows NWS 'Mostly Sunny'")

        // F6 on the same live data: no drizzle on NWS-sunny Tue/Wed, no snow on the 53/41 °F Saturday.
        for d in [day(2026, 10, 13), day(2026, 10, 14)] {
            let f = try XCTUnwrap(daily.first { $0.date == d })
            XCTAssertFalse(f.condition.isPrecipitation, "\(d): \(f.condition.description) at \(f.precipitationProbability ?? -1) %")
        }
        let saturday = try XCTUnwrap(daily.first { $0.date == day(2026, 10, 17) })
        print("[batch1] Fairfield Sat Oct 17 pop=\(saturday.precipitationProbability ?? -1) \(saturday.condition.description)")
        XCTAssertNotEqual(saturday.condition.category, .snow)
        let friday = try XCTUnwrap(daily.first { $0.date == day(2026, 10, 16) })
        XCTAssertEqual(friday.condition.category, .rain, "NWS 'Rain Showers Likely' 62 %")
    }

    /// Same case, synthetic: day pop 9, prior night 96, model 43 → (43·2 + 9·2.5) / 4.5, no rain icon.
    func testDailyPoPUsesDaytimePeriodOnly() throws {
        let mon = day(2026, 10, 12)
        let json = """
        {"latitude":41,"longitude":-73,"timezone":"America/New_York","utc_offset_seconds":-14400,
         "daily":{"time":[\(mon.timeIntervalSince1970)],"temperature_2m_max_best_match":[22],"temperature_2m_min_best_match":[12],
                  "weather_code_best_match":[1],"precipitation_probability_max_best_match":[43],"precipitation_sum_best_match":[0.3]},
         "hourly":{"time":[\(mon.timeIntervalSince1970)],"temperature_2m_best_match":[15]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let tonight = period("Tonight", mon.addingTimeInterval(-6 * 3600), hours: 12, day: false, pop: 96, short: "Rain")
        let monday = period("Monday", mon.addingTimeInterval(6 * 3600), hours: 12, day: true, pop: 9, short: "Mostly Sunny")
        let d = try XCTUnwrap(ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [tonight, monday], timeZone: ny).first)
        XCTAssertEqual(d.precipitationProbability!, (43 * 2.0 + 9 * 2.5) / 4.5, accuracy: 1e-9)
        XCTAssertEqual(d.weatherCode, 1)
    }

    /// Forecast issued in the evening: no daytime period left for today, so tonight's chance counts.
    func testEveningForecastUsesTonightForToday() throws {
        let sun = day(2026, 10, 11)
        let json = """
        {"latitude":41,"longitude":-73,"timezone":"America/New_York","utc_offset_seconds":-14400,
         "daily":{"time":[\(sun.timeIntervalSince1970)],"temperature_2m_max_best_match":[18],"temperature_2m_min_best_match":[12],
                  "precipitation_probability_max_best_match":[60]},
         "hourly":{"time":[\(sun.timeIntervalSince1970)],"temperature_2m_best_match":[15]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let tonight = period("Tonight", sun.addingTimeInterval(18 * 3600), hours: 12, day: false, pop: 90)
        let d = try XCTUnwrap(ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [tonight], timeZone: ny).first)
        XCTAssertEqual(d.precipitationProbability!, (60 * 2.0 + 90 * 2.5) / 4.5, accuracy: 1e-9)
    }

    // MARK: F2 duplicate NOAA columns

    func testFamilyDedupe() throws {
        let input: [(model: ForecastModel, value: Double?, weight: Double)] = [
            (.bestMatch, 10, 2), (.hrrr, 10, 3), (.ecmwf, 12, 1.5), (.gfs, 10, 1), (.icon, 10, 1)]
        let out = ForecastBlender.dedupedFamily(input)
        XCTAssertEqual(out.count, 3, "NOAA trio collapses to one sample; ICON (another family) is kept even with the same value")
        XCTAssertEqual(ForecastBlender.weightedMean(out)!, (30.0 + 18.0 + 10.0) / 5.5, accuracy: 1e-9)
        let distinct = ForecastBlender.dedupedFamily([(.bestMatch, 10, 2), (.hrrr, 11, 3), (.gfs, nil, 1)])
        XCTAssertEqual(distinct.count, 3, "different values are all kept; nil passes through")
    }

    /// Open-Meteo's HRRR "probability" is GFS's: it must carry no weight, hourly or daily.
    func testHRRRProbabilityIsIgnored() throws {
        let t = 1_800_000_000.0
        let json = """
        {"latitude":40,"longitude":-74,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":[\(t)],"temperature_2m_max_best_match":[20],"temperature_2m_min_best_match":[10],
                  "temperature_2m_max_gfs_hrrr":[21],"temperature_2m_min_gfs_hrrr":[11],
                  "precipitation_probability_max_best_match":[10],"precipitation_probability_max_gfs_hrrr":[90]},
         "hourly":{"time":[\(t)],"temperature_2m_best_match":[15],"temperature_2m_gfs_hrrr":[16],
                   "precipitation_probability_best_match":[10],"precipitation_probability_gfs_hrrr":[90]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let h = try XCTUnwrap(ForecastBlender.blendHourly(openMeteo: om, nwsHourly: [], now: Date(timeIntervalSince1970: t)).first)
        XCTAssertEqual(h.precipitationProbability!, 10, accuracy: 1e-9)
        let d = try XCTUnwrap(ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: [], timeZone: TimeZone(identifier: "UTC")!).first)
        XCTAssertEqual(d.precipitationProbability!, 10, accuracy: 1e-9)
    }

    /// The blend's day-0 high counts the identical NOAA trio once; the sources list shows it as one row.
    func testDailyBlendCountsNOAAOnce() throws {
        let om = try OpenMeteoResponse.decode(try Fixture.data("om_nyc"))
        let nws = try NWSPeriod.decodeList(try Fixture.data("nws_forecast"))
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: ny)
        XCTAssertEqual(daily[0].high, wmean([(18.4, 3), (16.1, 1.5), (14.9, 1), (fToC(66), 2.5)]), accuracy: 1e-6)
        let noaaRows = daily[0].sources.filter { $0.name.contains("NOAA") || $0.name.contains("Best Match") }
        XCTAssertEqual(noaaRows.count, 1, "\(daily[0].sources.map(\.name))")
    }

    /// Verification scores one NOAA source, not three, and never scores HRRR's borrowed probability.
    func testVerificationScoresDuplicatesOnce() {
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = issued.addingTimeInterval(3 * 3600)
        let same = SourceValues(t: 12, pop: 40, p: 0.2, w: 10)
        let rec = ForecastRecord(loc: "x", issued: issued, valid: valid, f: [
            VerificationSource.hrrr.rawValue: same, VerificationSource.bestMatch.rawValue: same,
            VerificationSource.gfs.rawValue: same, VerificationSource.ecmwf.rawValue: SourceValues(t: 12, pop: 40),
        ]).dedupingNOAAFamily()
        // At 3 h HRRR has the largest weight: it keeps t/p/w; its pop is dropped; best_match keeps the pop.
        XCTAssertEqual(rec.values(.hrrr), SourceValues(t: 12, pop: nil, p: 0.2, w: 10))
        XCTAssertEqual(rec.values(.bestMatch), SourceValues(pop: 40))
        XCTAssertNil(rec.values(.gfs), "an exact copy is not a separate source")
        XCTAssertEqual(rec.values(.ecmwf), SourceValues(t: 12, pop: 40), "other families are untouched")

        let scores = AccuracyScorer.score([VerifiedRecord(rec, ObservedHour(t: 13, wet: false))], now: valid)
        XCTAssertEqual(scores.overall[.hrrr]?.tempN, 1)
        XCTAssertNil(scores.overall[.gfs])
        XCTAssertEqual(scores.overall[.bestMatch]?.tempN ?? 0, 0)

        // Records saved before the rule are de-duplicated when scored.
        let old = ForecastRecord(loc: "x", issued: issued, valid: valid, f: [
            VerificationSource.bestMatch.rawValue: SourceValues(t: 12), VerificationSource.gfs.rawValue: SourceValues(t: 12)])
        let s2 = AccuracyScorer.score([VerifiedRecord(old, ObservedHour(t: 13))], now: valid)
        XCTAssertEqual(s2.overall[.bestMatch]?.tempN, 1)
        XCTAssertNil(s2.overall[.gfs])
    }

    // MARK: F3 overnight lows

    /// NWS issues an "Overnight" period (≈ 2–6 AM) when the forecast is issued after midnight. Its
    /// temperature is this morning's low (day D); "Tonight" (6 PM D → 6 AM D+1) is D+1's.
    func testOvernightPeriodMapsToCorrectDay() throws {
        let D = 86400.0 * 10
        let json = """
        {"latitude":40,"longitude":-74,"timezone":"UTC","utc_offset_seconds":0,
         "daily":{"time":[\(D),\(D + 86400)],
                  "temperature_2m_max_best_match":[20,22],"temperature_2m_min_best_match":[4,9]},
         "hourly":{"time":[\(D)],"temperature_2m_best_match":[10]}}
        """
        let om = try OpenMeteoResponse.decode(Data(json.utf8))
        let d = Date(timeIntervalSince1970: D)
        let nws = [
            period("Overnight", d.addingTimeInterval(2 * 3600), hours: 4, day: false, t: 3),
            period("Today", d.addingTimeInterval(6 * 3600), hours: 12, day: true, t: 21),
            period("Tonight", d.addingTimeInterval(18 * 3600), hours: 12, day: false, t: 10),
            period("Tomorrow", d.addingTimeInterval(30 * 3600), hours: 12, day: true, t: 23),
        ]
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily[0].low, wmean([(4, 2), (3, 2.5)]), accuracy: 1e-9, "day 0 low includes NWS Overnight (3 °C)")
        XCTAssertEqual(daily[1].low, wmean([(9, 2), (10, 2.5)]), accuracy: 1e-9, "day 1 low uses NWS Tonight (10 °C)")
    }

    // MARK: F4 stale data honesty

    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))

    func testOfflineReportCarriesRealDataAge() async throws {
        let client = MockHTTPClient()
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let fresh = try await service.report(for: nyc)
        XCTAssertEqual(fresh.dataAsOf, fixtureTime)
        XCTAssertFalse(fresh.isOfflineFallback)

        clock.now = fixtureTime.addingTimeInterval(3 * 3600)
        client.offline = true
        let stale = try await service.report(for: nyc)
        XCTAssertTrue(stale.isOfflineFallback, "network failed: the report must say it came from the cache")
        XCTAssertEqual(stale.dataAsOf, fixtureTime, "data age is the download time, not 'now'")
        XCTAssertEqual(stale.dataAge(at: clock.now), 3 * 3600, accuracy: 1)
        XCTAssertEqual(DataAge.updatedText(stale, now: clock.now), "Updated 3 h ago")
    }

    func testOfflineCacheIsCapped() async throws {
        let client = MockHTTPClient()
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        _ = try await service.report(for: nyc)
        clock.now = fixtureTime.addingTimeInterval(WeatherService.MaxStale.forecast + 60)
        client.offline = true
        do {
            _ = try await service.report(for: nyc)
            XCTFail("forecast older than the cap must not be shown as weather")
        } catch {}
    }

    func testDataAgeWording() {
        XCTAssertEqual(DataAge.relative(20), "just now")
        XCTAssertEqual(DataAge.relative(5 * 60 + 10), "5 min ago")
        XCTAssertEqual(DataAge.relative(2 * 3600 + 5), "2 h ago")
        XCTAssertEqual(DataAge.relative(3 * 86400), "3 d ago")
        XCTAssertEqual(DataAge.staleAfter(refreshMinutes: 15), 30 * 60)
        XCTAssertEqual(DataAge.staleAfter(refreshMinutes: 60), 75 * 60)
    }

    // MARK: F5 old NWS forecasts and expired alerts

    /// Fails requests whose URL contains any of `failing`; serves fixtures otherwise.
    final class FailingClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        private let lock = NSLock()
        private var _failing: [String] = []
        var failing: [String] {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            if failing.contains(where: { url.absoluteString.contains($0) }) { throw HTTPError.status(503, url) }
            return try await inner.get(url, headers: headers)
        }
    }

    func testOldNWSForecastIsIgnored() async throws {
        let client = FailingClient()
        let clock = TestClock(fixtureTime)
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let first = try await service.report(for: nyc)
        XCTAssertTrue(first.sources.contains("NWS OKX"))

        // 3 h later NWS is down: the 3-hour-old cached NWS forecast is still fine.
        clock.now = fixtureTime.addingTimeInterval(3 * 3600)
        client.failing = ["api.weather.gov/gridpoints"]
        let recent = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertTrue(recent.sources.contains("NWS OKX"))
        XCTAssertEqual(recent.dataAsOf, fixtureTime, "the cached NWS copy's age counts")

        // 7 h later: older than 6 h, so NWS is left out instead of blended at full weight.
        clock.now = fixtureTime.addingTimeInterval(7 * 3600)
        let old = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertFalse(old.sources.contains("NWS OKX"))
        XCTAssertFalse(old.daily.contains { $0.sources.contains { $0.name == "National Weather Service" } })
    }

    func testNWSRecencyRules() {
        let now = fixtureTime
        let fresh = NWSPeriod.Issuance(generatedAt: now.addingTimeInterval(-600), updateTime: now.addingTimeInterval(-4 * 3600))
        XCTAssertTrue(NWSPeriod.isRecent(fresh, downloadedAt: now, now: now))
        XCTAssertFalse(NWSPeriod.isRecent(fresh, downloadedAt: now.addingTimeInterval(-7 * 3600), now: now), "old download")
        let stuck = NWSPeriod.Issuance(generatedAt: now, updateTime: now.addingTimeInterval(-3 * 86400))
        XCTAssertFalse(NWSPeriod.isRecent(stuck, downloadedAt: now, now: now), "NWS 'stuck grid'")
        let meta = NWSPeriod.issuance(try! Fixture.data("nws_forecast"))
        XCTAssertNotNil(meta.generatedAt)
        XCTAssertNotNil(meta.updateTime)
    }

    func testExpiredAlertsDropped() throws {
        let data = try Fixture.data("nws_alerts")
        // Fixture: Tornado Warning ends 10:00 AM ET Oct 11; Flood Warning ends 2:00 AM ET Oct 14.
        XCTAssertEqual(try NWSAlertParser.decode(data, now: fixtureTime).map(\.event), ["Tornado Warning", "Flood Warning"])
        let later = fixtureTime.addingTimeInterval(2 * 3600)
        let alerts = try NWSAlertParser.decode(data, now: later)
        XCTAssertEqual(alerts.map(\.event), ["Flood Warning"], "the expired tornado warning is gone")

        // Display time: a report built earlier stops showing the warning once it ends.
        let all = try NWSAlertParser.decode(data, now: fixtureTime)
        let report = WeatherReport(location: nyc, fetchedAt: fixtureTime, timeZoneIdentifier: "America/New_York",
                                   current: CurrentConditions(time: fixtureTime, temperature: 10, apparentTemperature: 10,
                                                              humidity: 50, dewPoint: nil, weatherCode: 0, isDay: true,
                                                              precipitation: 0, cloudCover: nil, pressure: nil, windSpeed: 0,
                                                              windDirection: nil, windGust: nil, visibility: nil, uvIndex: nil),
                                   hourly: [], daily: [], alerts: all)
        XCTAssertEqual(report.activeAlerts(at: fixtureTime).count, 2)
        XCTAssertEqual(report.activeAlerts(at: later).map(\.event), ["Flood Warning"])
    }

    // MARK: F6 icons

    func testNWSWordingToIcon() {
        func codes(_ s: String) -> (Int?, Int?) { let c = WeatherCondition.nwsCodes(s); return (c?.precipitation, c?.sky) }
        XCTAssertTrue(codes("Mostly Sunny") == (nil, 1))
        XCTAssertTrue(codes("Sunny") == (nil, 0))
        XCTAssertTrue(codes("Partly Sunny") == (nil, 2))
        XCTAssertTrue(codes("Mostly Cloudy") == (nil, 3))
        XCTAssertTrue(codes("Chance Light Rain then Mostly Sunny") == (61, 1))
        XCTAssertTrue(codes("Rain Showers Likely") == (80, nil))
        XCTAssertTrue(codes("Slight Chance Showers And Thunderstorms then Partly Cloudy") == (95, 2))
        XCTAssertTrue(codes("Snow Showers") == (85, nil))
        XCTAssertTrue(codes("Rain And Snow") == (66, nil))
        XCTAssertTrue(codes("Patchy Fog then Mostly Sunny") == (nil, 1))
        XCTAssertNil(WeatherCondition.nwsCodes(""))
    }

    func testDailyIconGates() {
        // Rain icon needs ≥ 30 % blended chance: drizzle at 14 % → the dry fallback.
        XCTAssertEqual(ForecastBlender.dailyIcon(code: 51, dryFallback: nil, precipitationProbability: 14,
                                                 precipitation: 0.1, temperature: 15), 2)
        XCTAssertEqual(ForecastBlender.dailyIcon(code: 61, dryFallback: 1, precipitationProbability: 20,
                                                 precipitation: 0.5, temperature: 15), 1)
        XCTAssertEqual(ForecastBlender.dailyIcon(code: 61, dryFallback: 1, precipitationProbability: 45,
                                                 precipitation: 0.5, temperature: 15), 61)
        // Snow above ~37 °F becomes rain (the 53/41 °F "Snow Showers" day).
        XCTAssertEqual(ForecastBlender.dailyIcon(code: 85, dryFallback: nil, precipitationProbability: 40,
                                                 precipitation: 1, temperature: (fToC(53) + fToC(41)) / 2), 80)
        XCTAssertEqual(ForecastBlender.dailyIcon(code: 73, dryFallback: nil, precipitationProbability: 80,
                                                 precipitation: 3, temperature: -2), 73)
        XCTAssertEqual(ForecastBlender.rainIfWarm(71, temperature: 3), 61)
        XCTAssertEqual(ForecastBlender.rainIfWarm(71, temperature: 2), 71)
        // Hourly reconcile applies the snow→rain rule too.
        XCTAssertEqual(ForecastBlender.reconcile(code: 85, precipitationProbability: 70, precipitation: 1, temperature: 8), 80)
    }

    func testDominantCodeFromBlendedHours() {
        let d = day(2026, 10, 12)
        func hours(_ codes: [Int]) -> [HourlyForecast] {
            codes.enumerated().map { i, c in
                HourlyForecast(time: d.addingTimeInterval(Double(7 + i) * 3600), temperature: 15, apparentTemperature: nil,
                               precipitationProbability: nil, precipitation: nil, weatherCode: c, isDay: true, uvIndex: nil,
                               windSpeed: nil, windDirection: nil, humidity: nil)
            }
        }
        XCTAssertEqual(ForecastBlender.dominantCode(hours([1, 1, 2, 3, 1, 61, 1, 1, 2, 1, 1, 1, 1]), timeZone: ny), 1,
                       "one wet hour doesn't make a rainy day")
        XCTAssertEqual(ForecastBlender.dominantCode(hours([3, 61, 61, 63, 61, 3, 3, 3, 3, 3, 3, 3, 3]), timeZone: ny), 61)
        XCTAssertNil(ForecastBlender.dominantCode([], timeZone: ny))
    }

    // MARK: F8 radar clock hand-over

    /// Port of the radar play clock: task A awaits a slow reload, is replaced by B meanwhile, then resumes.
    /// A must stop and must not clear the slot (which would orphan B). Then pausing stops everything.
    @MainActor
    func testTaskSlotResumedTaskCannotOrphanSuccessor() async throws {
        let slot = TaskSlot()
        var steps: [String: Int] = [:]
        var aResumed = false
        func loop(_ name: String, slowFirst: Bool) -> @MainActor (Int) async -> Void {
            { token in
                var first = slowFirst
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(first ? 150 : 20))
                    if first { first = false; if name == "A" { aResumed = true } }
                    if Task.isCancelled || !slot.owns(token) { return }
                    steps[name, default: 0] += 1
                    if name == "A" { slot.clear(token: token); return } // the old bug path: "not ready → clock = nil"
                }
            }
        }
        slot.start(loop("A", slowFirst: true))
        try await Task.sleep(for: .milliseconds(30))
        slot.start(loop("B", slowFirst: false)) // user toggled play / occlusion flipped while A was reloading
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(aResumed)
        XCTAssertNil(steps["A"], "a replaced task must not keep stepping")
        XCTAssertTrue(slot.isOccupied, "A must not clear B's slot")
        XCTAssertGreaterThan(steps["B"] ?? 0, 0)

        slot.cancel() // pause / hide
        let afterPause = steps["B"] ?? 0
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(steps["B"] ?? 0, afterPause, "no steps after pause")
        XCTAssertFalse(slot.isOccupied)
    }
}
