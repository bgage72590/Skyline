import XCTest
@testable import SkylineCore

final class NowcastCurveTests: XCTestCase {
    func testDenseMonotoneAndNonNegative() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let vals = [0.0, 0.0, 0.5, 2.0, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0]
        let m = vals.enumerated().map { MinutelyPrecipitation(time: t0.addingTimeInterval(Double($0.offset) * 900), precipitation: $0.element) }
        let s = NowcastCurve.samples(m, from: t0, minutes: 120)
        XCTAssertEqual(s.count, 121)
        XCTAssertTrue(s.allSatisfy { $0.rate >= 0 && $0.rate <= 8.0001 })
        // Peak rate (2 mm / 15 min = 8 mm/h) is reached near its interval centre.
        let peak = s.max { $0.rate < $1.rate }!
        XCTAssertEqual(peak.rate, 8, accuracy: 0.05)
        XCTAssertEqual(peak.time.timeIntervalSince(t0), 3 * 900 - 450, accuracy: 60)
        // Dry slots stay dry (no overshoot between two zero knots).
        XCTAssertEqual(s[100].rate, 0, accuracy: 1e-9)
    }

    func testLevels() {
        XCTAssertEqual(NowcastCurve.level(0), 0)
        XCTAssertEqual(NowcastCurve.level(2.5), 1, accuracy: 1e-9)
        XCTAssertEqual(NowcastCurve.level(7.6), 2, accuracy: 1e-9)
        XCTAssertEqual(NowcastCurve.level(100), 3)
        XCTAssertEqual(NowcastCurve.intensityName(5), "Moderate")
    }
}
