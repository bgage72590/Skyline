import XCTest
@testable import SkylineCore

final class NexradConusTests: XCTestCase {
    func testOverseasSitesExcludedFromConus() {
        let ids = Set(NexradStation.conus.map(\.id))
        for id in ["KJK", "KSG", "ODN"] { XCTAssertFalse(ids.contains(id), id) }
        XCTAssertFalse(NexradStation.conus.contains { $0.state.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertFalse(NexradStation.conus.map(\.icao).contains("KKJK"))
        XCTAssertTrue(ids.contains("OKX"))
    }
}
