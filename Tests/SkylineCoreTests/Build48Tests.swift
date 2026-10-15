import XCTest
@testable import SkylineCore

final class Build48Tests: XCTestCase {
    /// The two-phase crossfade (fade in over the old frame, then the old fades out over the new)
    /// takes about as long as the 0.35 s single fade it replaced, plus MapKit's draw time.
    func testTwoPhaseCrossfadeTiming() {
        XCTAssertEqual(RadarCrossfade.fadeIn + RadarCrossfade.fadeOut, RadarCrossfade.duration, accuracy: 0.001)
        XCTAssertGreaterThan(RadarCrossfade.fadeIn, RadarCrossfade.fadeOut)
    }
}
