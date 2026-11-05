import XCTest
@testable import SkylineCore

/// Plan §6: Accuracy bias-correction copy. The auto-off rule is pinned, not changed.
final class AccuracyBiasCopyTests: XCTestCase {

    func testAutoOffStatusLine() {
        let line = BiasCorrection.statusLine(
            entry: CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 0.5, autoOff: true),
            gated: true, sitingOK: true, switchOn: true, nDays: 20, units: { $0 })
        XCTAssertEqual(line, "paused: worse recently · rechecks after 7+ new days")
        XCTAssertEqual(line, BiasCorrection.autoOffLine)
        XCTAssertTrue(line.contains("\(BiasCorrection.autoOffReenableDays)"))
    }

    func testAutoOffStatusLinePrecedenceUnchanged() {
        let entry = CorrectionEntry(loc: "x", target: .dailyHigh, autoOff: true)
        XCTAssertEqual(
            BiasCorrection.statusLine(entry: entry, gated: true, sitingOK: true, switchOn: false,
                                     nDays: 20, units: { $0 }),
            "off: switched off")
        XCTAssertEqual(
            BiasCorrection.statusLine(entry: entry, gated: true, sitingOK: false, switchOn: true,
                                     nDays: 20, units: { $0 }),
            "off: station")
        XCTAssertEqual(
            BiasCorrection.statusLine(entry: entry, gated: true, sitingOK: false, switchOn: true,
                                     nDays: 20, units: { $0 }, stationPending: true),
            BiasCorrection.offStationPending)
    }

    func testAutoOffRuleGuard() {
        XCTAssertEqual(BiasCorrection.autoOffReenableDays, 7)
        XCTAssertEqual(BiasCorrection.autoOffHysteresisC, 0.05)
    }

    func testAccuracyCorrectionCopyConstants() {
        XCTAssertTrue(AccuracyCorrectionCopy.scoresCaption.contains("before bias correction"))
        XCTAssertTrue(AccuracyCorrectionCopy.howItWorksSuffix.contains("before bias correction"))
        XCTAssertEqual(
            AccuracyCorrectionCopy.scoresCaption,
            "Scores grade Skyline’s forecast before bias correction.")
        XCTAssertEqual(
            AccuracyCorrectionCopy.howItWorksSuffix,
            " All scores on this page grade forecasts before bias correction, so they show how the raw blend did, not the small adjustments listed under Bias correction.")
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("7"))
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("0.05 °C"))
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("0.1 °F"))
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("\(BiasCorrection.autoOffReenableDays)"))
        XCTAssertEqual(
            AccuracyCorrectionCopy.autoOffFootnote,
            "“Paused” means the correction made recent forecasts worse, so Skyline stopped applying it. It turns back on only after at least 7 more scored days and only if it would have cut the error by at least 0.1 °F (0.05 °C).")
    }
}
