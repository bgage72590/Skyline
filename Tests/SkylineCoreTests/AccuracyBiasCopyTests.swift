import XCTest
@testable import SkylineCore

/// Plan §6: Accuracy bias-correction copy. Strings pin the held-out rule (C10).
final class AccuracyBiasCopyTests: XCTestCase {

    func testAutoOffStatusLine() {
        let line = BiasCorrection.statusLine(
            entry: CorrectionEntry(loc: "x", target: .dailyHigh, appliedC: 0.5, autoOff: true),
            gated: true, sitingOK: true, switchOn: true, nDays: 20, units: { $0 })
        XCTAssertEqual(line, "paused: did not help on recent held-out days · turns back on when it would have cut error by ≥0.05 °F")
        XCTAssertEqual(line, BiasCorrection.autoOffLine)
        XCTAssertFalse(line.contains("rechecks after"))
        XCTAssertFalse(line.contains("new days"))
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
        XCTAssertEqual(BiasCorrection.heldOutMinDays, 7)
        XCTAssertEqual(BiasCorrection.heldOutOnGainC, 0.05 / 1.8)
        XCTAssertNotEqual(BiasCorrection.heldOutOnGainC, 0.03, "ε stays 0.05 °F, not 0.03 °C")
        XCTAssertEqual(BiasCorrection.autoOffWindowDays, 14)
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
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("\(BiasCorrection.heldOutMinDays)"))
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("0.05 °F"))
        XCTAssertTrue(AccuracyCorrectionCopy.autoOffFootnote.contains("0.03 °C"))
        XCTAssertFalse(AccuracyCorrectionCopy.autoOffFootnote.contains("0.1 °F"))
        XCTAssertFalse(AccuracyCorrectionCopy.autoOffFootnote.contains("more scored days"))
        XCTAssertEqual(
            AccuracyCorrectionCopy.autoOffFootnote,
            "Needs at least 7 held-out days and a ≥0.05 °F (0.03 °C) cut to turn on. It stays on while it still helps, and pauses when it stops helping.")
    }
}
