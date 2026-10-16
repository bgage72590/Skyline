import XCTest
@testable import SkylineCore

final class Build48Tests: XCTestCase {
    /// Review L6: the build-48 two-phase constants (fadeIn/fadeOut) are gone; the simultaneous fade is
    /// one `duration`. Review L3 / QA X1-b: shared rain no longer dips to 0.75 mid-fade.
    func testCrossfadeKeepsSharedRainNearFullStrength() {
        XCTAssertEqual(RadarCrossfade.duration, 0.35, accuracy: 0.001)
        let linearMid = 0.5 + 0.5 * 0.5 // the old equal-sum stack at t = 0.5
        XCTAssertEqual(linearMid, 0.75, accuracy: 1e-9)
        var minimum = 1.0
        for i in 0...100 { minimum = min(minimum, RadarCrossfade.stackedAlpha(Double(i) / 100)) }
        XCTAssertGreaterThan(minimum, 0.84)
        // Old fades monotonically from its start to 0; ends clean.
        var last = 2.0
        for i in 0...100 {
            let a = RadarCrossfade.outgoingAlpha(Double(i) / 100)
            XCTAssertLessThanOrEqual(a, last + 1e-9); last = a
        }
        XCTAssertEqual(RadarCrossfade.outgoingAlpha(0), 1, accuracy: 1e-6)
        XCTAssertEqual(RadarCrossfade.outgoingAlpha(1), 0, accuracy: 1e-6)
        // Review L2: a mid-fade switch starts from the blended alpha, scaled.
        XCTAssertEqual(RadarCrossfade.outgoingAlpha(0, from: 0.6), 0.6, accuracy: 1e-6)
    }
}
