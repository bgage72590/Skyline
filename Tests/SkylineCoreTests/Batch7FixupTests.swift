import XCTest
@testable import SkylineCore

/// Batch 7 fix-up: QA lows N2 (localized country, no code), #13 (in-flight dedupe and coordinate)
/// and N1 ("as of" in the city's own time zone). SPC wording is in ReviewBatch7Tests.
final class Batch7FixupTests: XCTestCase {
    let f = Batch6Fixture()

    func testLocalizedUSNameWithoutCodeCountsAsUS() {
        let calais = Coordinate(latitude: 45.18, longitude: -67.28)
        for name in ["Estados Unidos", "Vereinigte Staaten", "États-Unis", "Stati Uniti", "アメリカ合衆国", "United States"] {
            let l = WeatherLocation(name: "Calais", country: name, coordinate: calais)
            XCTAssertTrue(l.isLikelyInNWSCoverage, name)
            XCTAssertEqual(USCoverage.isUS(code: nil, country: name), true, name)
        }
        XCTAssertEqual(USCoverage.isUS(code: nil, country: "Kanada"), false)
        XCTAssertEqual(USCoverage.isUS(code: "CA", country: "Estados Unidos"), false, "the code still wins")
    }

    func testSecondFixDuringSlowLoadGetsItsOwnReport() async throws {
        final class Slow: HTTPClient, @unchecked Sendable {
            let inner = MockHTTPClient()
            func get(_ url: URL, headers: [String: String]) async throws -> Data {
                try await Task.sleep(for: .milliseconds(150))
                return try await inner.get(url, headers: headers)
            }
        }
        let client = Slow()
        let t = f.now
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { t }), now: { t })
        let a = WeatherLocation(name: "My Location", coordinate: Coordinate(latitude: 40.71, longitude: -74.01), isCurrentLocation: true)
        var b = a; b.coordinate = Coordinate(latitude: 41.31, longitude: -72.92)
        async let r1 = service.report(for: a, forceRefresh: true)
        try await Task.sleep(for: .milliseconds(20))
        async let r2 = service.report(for: b, forceRefresh: true)
        _ = try await (r1, r2)
        let urls = client.inner.requests.map(\.absoluteString)
        XCTAssertTrue(urls.contains { $0.contains("41.31") }, "the new place was fetched, not deduped onto the old one")
        XCTAssertTrue(urls.contains { $0.contains("40.71") })
    }

    func testAsOfUsesTheCityTimeZoneForTheDay() {
        // Data from 10:30 PM Sunday in Tokyo, read at 12:30 AM Monday there (still Sunday morning by a
        // New York or UTC clock): the note needs the weekday.
        var old = f.report(fetched: f.now)
        old.timeZoneIdentifier = "Asia/Tokyo"
        XCTAssertEqual(IntentText.staleNote(old, now: f.now.addingTimeInterval(2 * 3600)), " (as of Sun 10:30 PM)")
        XCTAssertEqual(IntentText.staleNote(old, now: f.now.addingTimeInterval(65 * 60)), " (as of 10:30 PM)", "same Tokyo day")
    }
}
