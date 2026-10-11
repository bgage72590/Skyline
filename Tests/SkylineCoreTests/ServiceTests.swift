import XCTest
@testable import SkylineCore

final class ServiceTests: XCTestCase {
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
    let paris = WeatherLocation(name: "Paris", country: "France", coordinate: Coordinate(latitude: 48.85, longitude: 2.35))

    func testUSReportBlendsAllSources() async throws {
        let client = MockHTTPClient()
        // Fixed clock at the fixtures' time (09:30 ET Oct 11): NWS data is recent and the fixture Tornado
        // Warning (ends 10:00 ET) is still active. With the wall clock this test used to rely on an expired alert.
        let clock = TestClock(Date(timeIntervalSince1970: 1_791_725_400))
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let report = try await service.report(for: nyc)

        XCTAssertEqual(report.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(report.current.temperature, 15.6, accuracy: 0.001)
        XCTAssertEqual(report.daily.count, 10)
        XCTAssertEqual(report.hourly.count, 240)
        XCTAssertEqual(report.alerts.count, 2)
        XCTAssertEqual(report.airQuality?.usAQI, 79)
        XCTAssertTrue(report.sources.contains("NWS OKX"))
        XCTAssertTrue(report.sources.contains("NOAA HRRR"))
        XCTAssertEqual(report.nwsOffice, "New York, NY")
        XCTAssertEqual(report.nowcastSummary, "Rain stopping in about 75 min")
        XCTAssertTrue(client.requests.contains { $0.absoluteString.contains("models=best_match,gfs_hrrr") })
    }

    func testNonUSReportSkipsNWS() async throws {
        let client = MockHTTPClient()
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil))
        let report = try await service.report(for: paris)
        XCTAssertEqual(report.timeZoneIdentifier, "Europe/Paris")
        XCTAssertTrue(report.alerts.isEmpty)
        XCTAssertNil(report.nwsOffice)
        XCTAssertFalse(client.requests.contains { $0.host == "api.weather.gov" })
        XCTAssertFalse(client.requests.contains { $0.absoluteString.contains("gfs_hrrr") })
        XCTAssertFalse(report.sources.contains { $0.hasPrefix("NWS") })
    }

    func testCacheAvoidsRefetchAndServesStaleWhenOffline() async throws {
        let client = MockHTTPClient()
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let service = WeatherService(client: client, cache: cache, now: { clock.now })

        _ = try await service.report(for: nyc)
        let firstCount = client.requests.count
        XCTAssertEqual(firstCount, 6) // OM, AQ, points, forecast, hourly, alerts

        _ = try await service.report(for: nyc)
        XCTAssertEqual(client.requests.count, firstCount, "second call within TTL must be served from cache")

        clock.now = clock.now.addingTimeInterval(3600)
        client.offline = true
        let offlineReport = try await service.report(for: nyc)
        XCTAssertEqual(offlineReport.daily.count, 10, "stale cache is used when the network fails")
    }

    func testOfflineWithEmptyCacheThrows() async {
        let client = MockHTTPClient()
        client.offline = true
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil))
        do {
            _ = try await service.report(for: nyc)
            XCTFail("expected error")
        } catch {}
    }

    func testDiskCacheRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = ResponseCache(directory: dir)
        await a.store(Data("hello".utf8), for: "k")
        let b = ResponseCache(directory: dir) // new instance reads from disk
        let fresh = await b.fresh("k", maxAge: 60)
        XCTAssertEqual(fresh, Data("hello".utf8))
        let expired = await b.fresh("k", maxAge: -1)
        XCTAssertNil(expired)
        XCTAssertEqual(ResponseCache.hash("abc"), ResponseCache.hash("abc"))
        XCTAssertNotEqual(ResponseCache.hash("abc"), ResponseCache.hash("abd"))
    }

    func testSearchAndRadar() async throws {
        let service = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: nil))
        let results = try await service.search("Portland")
        XCTAssertEqual(results.first?.admin1, "Oregon")
        let none = try await service.search("a")
        XCTAssertTrue(none.isEmpty)
        let rv = try await service.radarFrames(.rainViewer)
        XCTAssertEqual(rv.count, 13)
        let nx = try await service.radarFrames(.nexrad)
        XCTAssertEqual(nx.count, 11)
    }

    func testEndpointsAreKeyless() {
        let url = Endpoints.openMeteoForecast(Coordinate(latitude: 40.71234567, longitude: -74.0), models: [.bestMatch, .ecmwf])
        XCTAssertTrue(url.absoluteString.contains("latitude=40.7123"))
        XCTAssertTrue(url.absoluteString.contains("timeformat=unixtime"))
        XCTAssertFalse(url.absoluteString.lowercased().contains("key"))
        XCTAssertEqual(Endpoints.nwsPoint(Coordinate(latitude: 40.71, longitude: -74.01)).absoluteString,
                       "https://api.weather.gov/points/40.7100,-74.0100")
    }
}
