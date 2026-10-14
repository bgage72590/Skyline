import XCTest
@testable import SkylineCore

/// Batch 7: hardening (L28 hosts, L4 location guard, L9 history off the first forecast, L23 reset and
/// counters, L17 type-to-jump, L12 text sizes) and Code Reviewer batch 6 nice-to-haves.
final class Batch7Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: L28 known hosts

    func testOnlyKnownWeatherHostsAreAllowed() {
        for ok in ["https://api.open-meteo.com/v1/forecast", "https://api.weather.gov/points/40,-74",
                   "https://tilecache.rainviewer.com/v2/radar/1/256/3/2/3/2/1_1.png",
                   "https://mesonet.agron.iastate.edu/cache/tile.py", "https://www.spc.noaa.gov/products/x.geojson",
                   "https://API.WEATHER.GOV/alerts"] {
            XCTAssertTrue(KnownHosts.isAllowed(URL(string: ok)), ok)
        }
        for bad in ["http://api.weather.gov/points", "https://evil.example.com/x", "https://api.weather.gov.evil.com/",
                    "https://weather.gov/", "file:///etc/passwd", "https://forecast.weather.gov/product.php"] {
            XCTAssertFalse(KnownHosts.isAllowed(URL(string: bad)), bad)
        }
    }

    /// A tampered NWS response pointing somewhere else is refused before anything is sent.
    func testHTTPClientRefusesUnknownHostsWithoutSending() async {
        let client = URLSessionHTTPClient()
        let before = RequestStats.shared.total
        do {
            _ = try await client.get(URL(string: "https://evil.example.com/forecast")!, headers: [:])
            XCTFail("should throw")
        } catch let e as HTTPError {
            XCTAssertEqual(e, .disallowedHost("evil.example.com"))
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(RequestStats.shared.total, before, "nothing was sent or counted")
        XCTAssertEqual(UserFacingError.message(HTTPError.disallowedHost("x")), "Weather service sent data Skyline couldn’t read.")
    }

    // MARK: L4 My Location

    func testOnlyResultsForTheCurrentFixApply() {
        let a = Coordinate(latitude: 41.14, longitude: -73.26), b = Coordinate(latitude: 41.30, longitude: -73.00)
        XCTAssertTrue(CurrentLocationGuard.isCurrent(a, current: a))
        XCTAssertFalse(CurrentLocationGuard.isCurrent(a, current: b), "moved meanwhile: the old answer is dropped")
        XCTAssertFalse(CurrentLocationGuard.isCurrent(a, current: nil))
    }

    // MARK: L17 type-to-jump

    func testTypeToJump() {
        let names = ["My Location", "New York", "Newark", "São Paulo", "Salt Lake City", "Fort Worth"]
        XCTAssertEqual(LocationList.typeSelect("n", in: names), 1)
        XCTAssertEqual(LocationList.typeSelect("newa", in: names), 2)
        XCTAssertEqual(LocationList.typeSelect("sao", in: names), 3, "accents ignored")
        XCTAssertEqual(LocationList.typeSelect("SAL", in: names), 4, "case ignored")
        XCTAssertEqual(LocationList.typeSelect("worth", in: names), 5, "word start")
        XCTAssertNil(LocationList.typeSelect("zz", in: names))
        XCTAssertNil(LocationList.typeSelect("", in: names))
    }

    // MARK: L9 first forecast doesn't wait for history

    func testWeightsIfLoadedDoesNotReadHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b7-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = t0
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { t })
        let notYet = await v.weightsIfLoaded("x")
        XCTAssertNil(notYet, "first forecast: neutral weights, no file reading")
        let loadedBefore = await v.isLoaded
        XCTAssertFalse(loadedBefore)
        _ = await v.weights("x")
        let now = await v.weightsIfLoaded("x")
        XCTAssertNotNil(now, "after the background load, learned weights are used")
    }

    func testFirstReportUsesNeutralWeightsAndLoadsHistoryInBackground() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b7s-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = t0
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { t })
        let service = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: nil), verifier: v, now: { t })
        _ = try await service.report(for: WeatherLocation(name: "NYC", country: "United States",
                                                          coordinate: Coordinate(latitude: 40.71, longitude: -74.01)))
        for _ in 0..<50 where !(await v.isLoaded) { try await Task.sleep(for: .milliseconds(20)) }
        let loaded = await v.isLoaded
        XCTAssertTrue(loaded, "history loads in the background for the next refresh")
    }

    // MARK: L23 reset

    func testResetAccuracyDataForgetsEverything() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b7r-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = t0
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { t })
        let rec = ForecastRecord(loc: "x", issued: t0, valid: t0.addingTimeInterval(3600),
                                 f: [VerificationSource.hrrr.rawValue: SourceValues(t: 10)])
        await v.record([rec], key: "x")
        let wants = await v.wantsIssuance("x")
        XCTAssertFalse(wants, "just recorded")
        await v.reset()
        let wantsAfter = await v.wantsIssuance("x")
        XCTAssertTrue(wantsAfter, "forgotten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pending.jsonl").path))
        // A fresh verifier on the same folder finds nothing either.
        let again = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { t })
        let fresh = await again.wantsIssuance("x")
        XCTAssertTrue(fresh)

        let h = ForecastHistory(directory: dir)
        let day = DailyForecast(date: t0, weatherCode: 3, high: 20, low: 10)
        await h.record("x", daily: [day], now: t0)
        let c1 = await h.count("x")
        XCTAssertEqual(c1, 1)
        await h.reset()
        let c2 = await ForecastHistory(directory: dir).count("x")
        XCTAssertEqual(c2, 0, "gone from disk too")
    }

    func testRequestRate() {
        let s = RequestStats()
        for _ in 0..<10 { s.note() }
        XCTAssertEqual(s.total, 10)
        XCTAssertNil(s.perHour(now: s.since.addingTimeInterval(60)), "too early to mean much")
        XCTAssertEqual(s.perHour(now: s.since.addingTimeInterval(1800)) ?? 0, 20, accuracy: 0.001)
    }

    // MARK: CR batch 6 nice-to-haves

    func testCountryCodeBeatsLocalizedName() {
        let c = Coordinate(latitude: 44.90, longitude: -66.99) // Eastport ME
        let german = WeatherLocation(name: "Eastport", country: "Vereinigte Staaten", coordinate: c, countryCode: "US")
        XCTAssertTrue(german.isLikelyInNWSCoverage && german.isInCONUS, "a German placemark name still counts as US")
        let nameOnly = WeatherLocation(name: "Eastport", country: "Vereinigte Staaten", coordinate: c)
        XCTAssertFalse(nameOnly.isLikelyInNWSCoverage, "the old name-only path is what the code fixes")
        let windsor = WeatherLocation(name: "Windsor", country: "Kanada", coordinate: Coordinate(latitude: 42.30, longitude: -83.02),
                                      countryCode: "CA")
        XCTAssertFalse(windsor.isLikelyInNWSCoverage || windsor.isInCONUS)
        let pr = WeatherLocation(name: "San Juan", coordinate: Coordinate(latitude: 18.47, longitude: -66.11), countryCode: "pr")
        XCTAssertTrue(pr.isLikelyInNWSCoverage)
        XCTAssertFalse(pr.isInCONUS)
        // Old saved cities (no code) decode and keep working by name.
        let old = #"{"id":"a","name":"NYC","country":"United States","coordinate":{"latitude":40.7,"longitude":-74},"isCurrentLocation":false}"#
        let decoded = try? JSONDecoder().decode(WeatherLocation.self, from: Data(old.utf8))
        XCTAssertNil(decoded?.countryCode)
        XCTAssertEqual(decoded?.isInCONUS, true)
    }

    func testSevereOutlookWordingAfterMidnight() {
        let ny = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        func at(_ h: Int) -> Date { cal.date(bySettingHour: h, minute: 30, second: 0, of: t0)! }
        let d1 = SevereOutlook(day: 1, risk: .slight, validFrom: t0, validUntil: t0.addingTimeInterval(86400))
        let d2 = SevereOutlook(day: 2, risk: .slight, validFrom: t0, validUntil: t0.addingTimeInterval(86400))
        XCTAssertTrue(d1.sentence(now: at(10), timeZone: ny).contains("today"))
        XCTAssertTrue(d1.sentence(now: at(19), timeZone: ny).contains("tonight"))
        XCTAssertTrue(d1.sentence(now: at(1), timeZone: ny).contains("tonight"), "1:30 AM: last night's Day 1 is still running")
        XCTAssertTrue(d2.sentence(now: at(14), timeZone: ny).contains("tomorrow"))
        XCTAssertTrue(d2.sentence(now: at(1), timeZone: ny).contains("today"), "after midnight, Day 2 is the day starting")
    }

    // MARK: L12 no text under 10 pt

    func testNoFixedFontsUnderTenPoints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dirs = ["Sources/Skyline", "Sources/SkylineWidget"].map { root.appendingPathComponent($0) }
        let pattern = try NSRegularExpression(pattern: #"\.system\(size: ([0-9]+(?:\.[0-9]+)?)"#)
        var small: [String] = []
        for dir in dirs {
            guard let files = FileManager.default.enumerator(atPath: dir.path) else { continue }
            for case let f as String in files where f.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    let v = Double((text as NSString).substring(with: m.range(at: 1))) ?? 99
                    if v < 10 { small.append("\(f): \(v)") }
                }
            }
        }
        XCTAssertEqual(small, [], "tiny text")
    }
}
