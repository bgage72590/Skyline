import XCTest
@testable import SkylineCore

final class SearchFixTests: XCTestCase {
    func testReturnOnlyUsesResultsForTheCurrentText() {
        let portResults = ["Port Said", "Porto"]
        XCTAssertNil(SearchSubmit.pick(results: portResults, resultsQuery: "Port", currentText: "Portland"),
                     "results for 'Port' must not be added while 'Portland' is in the field")
        XCTAssertEqual(SearchSubmit.pick(results: portResults, resultsQuery: "Port", currentText: " port "), "Port Said")
        XCTAssertNil(SearchSubmit.pick(results: [String](), resultsQuery: "Portland", currentText: "Portland"))
        XCTAssertNil(SearchSubmit.pick(results: portResults, resultsQuery: "", currentText: ""))
    }

    func testSearchErrorsAreErrorsNotEmptyResults() async {
        let client = MockHTTPClient()
        client.offline = true
        let service = WeatherService(client: client, cache: ResponseCache(directory: nil))
        do {
            _ = try await service.search("Portland")
            XCTFail("offline search must throw so the sidebar can say so instead of 'No matches'")
        } catch {
            XCTAssertFalse(UserFacingError.message(error).isEmpty)
        }
    }
}
