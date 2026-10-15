import XCTest
@testable import SkylineCore

final class Build57Tests: XCTestCase {
    /// The dropdown's tinted Liquid Glass keeps white text (and 0.75-alpha secondary text) at ≥ 4.5 : 1
    /// for every sky, even over a pure white wallpaper (the worst case for see-through glass).
    func testGlassTintContrastOverWhite() {
        for category in SkyCategory.allCases {
            for isDay in [true, false] {
                let bg = SkyColors.glassComposite(category, isDay: isDay)
                XCTAssertGreaterThanOrEqual(SkyColors.whiteContrast(on: bg), 4.5, "\(category) day=\(isDay)")
                XCTAssertGreaterThanOrEqual(SkyColors.whiteContrast(on: bg, alpha: 0.75), 4.5, "\(category) day=\(isDay) secondary")
            }
        }
    }

    func testGlassStillSeeThrough() {
        XCTAssertLessThan(SkyColors.glassTintOpacity, 1)
    }
}
