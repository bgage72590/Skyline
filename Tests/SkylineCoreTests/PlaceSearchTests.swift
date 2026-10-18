import XCTest
@testable import SkylineCore

/// Brian, Oct 17: adding a city failed silently. Every search outcome now says what happened.
final class PlaceSearchTests: XCTestCase {
    func place(_ name: String, _ admin1: String?, _ cc: String, id: Int) -> PlaceSearchResult {
        PlaceSearchResult(id: id, name: name, admin1: admin1, country: nil, countryCode: cc,
                          coordinate: Coordinate(latitude: 0, longitude: 0), timeZoneIdentifier: nil, population: nil)
    }

    func testCityCommaRegionIsSplit() {
        XCTAssertEqual(PlaceSearch.parse(" Portland, OR ").name, "Portland")
        XCTAssertEqual(PlaceSearch.parse(" Portland, OR ").qualifier, "OR")
        XCTAssertNil(PlaceSearch.parse("Portland").qualifier)
        XCTAssertNil(PlaceSearch.parse("Portland,").qualifier)
        XCTAssertEqual(PlaceSearch.parse("Paris, Texas, US").qualifier, "Texas, US")
    }

    func testQualifierRanksMatchesFirst() {
        let all = [place("Portland", "Oregon", "US", id: 1), place("Portland", "Maine", "US", id: 2),
                   place("Portland", "Victoria", "AU", id: 3)]
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: "ME").map(\.id), [2, 1, 3])
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: "maine").map(\.id), [2, 1, 3])
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: "AU").map(\.id), [3, 1, 2])
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: "Oregon, USA").map(\.id), [1, 2, 3])
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: "Narnia").map(\.id), [1, 2, 3], "no match: order unchanged")
        XCTAssertEqual(PlaceSearch.ranked(all, qualifier: nil).map(\.id), [1, 2, 3])
    }

    func testEveryStateSaysSomething() {
        XCTAssertNil(PlaceSearch.status(text: "", isSearching: false, resultCount: 0, resultsQuery: nil, error: nil))
        XCTAssertEqual(PlaceSearch.status(text: "P", isSearching: false, resultCount: 0, resultsQuery: nil, error: nil)?.kind, .hint)
        let searching = PlaceSearch.status(text: "Portland", isSearching: true, resultCount: 0, resultsQuery: nil, error: nil)
        XCTAssertEqual(searching?.message, "Searching for “Portland”…")
        let none = PlaceSearch.status(text: "Xyzzy", isSearching: false, resultCount: 0, resultsQuery: "xyzzy", error: nil)
        XCTAssertEqual(none?.kind, .noResults)
        XCTAssertEqual(none?.message, "No places found for “Xyzzy”.")
        XCTAssertEqual(PlaceSearch.status(text: "Portlnd, OR", isSearching: false, resultCount: 0, resultsQuery: "Portlnd, OR",
                                          error: nil)?.detail, "Try just the city name, like “Portlnd”.")
        let failed = PlaceSearch.status(text: "Portland", isSearching: false, resultCount: 0, resultsQuery: nil,
                                        error: "Couldn’t search. You’re offline.")
        XCTAssertEqual(failed?.kind, .failed)
        XCTAssertEqual(failed?.canRetry, true)
        XCTAssertEqual(PlaceSearch.status(text: "France", isSearching: false, resultCount: 1, resultsQuery: "France", error: nil,
                                          nothingAdded: true)?.kind, .chooseOne)
        XCTAssertNil(PlaceSearch.status(text: "Portland", isSearching: false, resultCount: 3, resultsQuery: "Portland", error: nil),
                     "results speak for themselves")
        // Results for older text never read as "No places found" for the new text.
        XCTAssertEqual(PlaceSearch.status(text: "Portland", isSearching: false, resultCount: 0, resultsQuery: "Port",
                                          error: nil)?.kind, .searching)
    }

    func testFailureMessages() {
        XCTAssertEqual(PlaceSearch.errorMessage(PlaceSearch.TimedOut()), "Couldn’t search: the place search didn’t answer.")
        XCTAssertFalse(PlaceSearch.errorMessage(HTTPError.backingOff(host: "geocoding-api.open-meteo.com", until: Date()))
            .contains("retrying at"), "search has no automatic retry, so it must not promise one")
        XCTAssertEqual(PlaceSearch.errorMessage(URLError(.notConnectedToInternet)), "Couldn’t search. You’re offline.")
    }

    func testSearchThatNeverAnswersTimesOut() async throws {
        do {
            _ = try await PlaceSearch.withTimeout(0.05) { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
            XCTFail("should time out")
        } catch is PlaceSearch.TimedOut {}
        let quick = try await PlaceSearch.withTimeout(5) { 7 }
        XCTAssertEqual(quick, 7)
    }

    func testCommaQuerySearchesTheNameAndRanksByRegion() async throws {
        let client = MockHTTPClient()
        let s = WeatherService(client: client, cache: ResponseCache(directory: nil))
        let r = try await s.search("Portland, ME")
        XCTAssertEqual(r.first?.admin1, "Maine")
        let url = try XCTUnwrap(client.requests.last)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Portland", "the geocoder can't match “Portland, ME”")
    }

    /// Empty first, real results after: an empty answer is re-asked after 10 minutes, not kept 30 days.
    final class EmptyThenFullClient: HTTPClient, @unchecked Sendable {
        let inner = MockHTTPClient()
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        private func count() -> Int { lock.lock(); defer { lock.unlock() }; _calls += 1; return _calls }
        func get(_ url: URL, headers: [String: String]) async throws -> Data {
            let n = count()
            if n == 1 { return Data(#"{"generationtime_ms":0.2}"#.utf8) }
            return try await inner.get(url, headers: headers)
        }
    }

    func testEmptyAnswersAreNotCachedForAMonth() async throws {
        let client = EmptyThenFullClient(), clock = TestClock(Date(timeIntervalSince1970: 1_791_725_400))
        let s = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }), now: { clock.now })
        let first = try await s.search("Portland")
        XCTAssertTrue(first.isEmpty)
        clock.now += 60
        let soon = try await s.search("Portland")
        XCTAssertTrue(soon.isEmpty)
        XCTAssertEqual(client.calls, 1, "a minute later the empty answer still stands")
        clock.now += PlaceSearch.emptyResultTTL
        let later = try await s.search("Portland")
        XCTAssertFalse(later.isEmpty, "asked again after 10 minutes")
        XCTAssertEqual(client.calls, 2)
    }
}
