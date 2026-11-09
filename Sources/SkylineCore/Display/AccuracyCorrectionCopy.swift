import Foundation

/// Accuracy-page copy only. Scores always grade the uncorrected blend.
/// The footnote states the held-out on/off rule (C10).
public enum AccuracyCorrectionCopy {
    public static let scoresCaption = "Scores grade Skyline’s forecast before bias correction."
    public static let howItWorksSuffix = " All scores on this page grade forecasts before bias correction, so they show how the raw blend did, not the small adjustments listed under Bias correction."
    /// ≥7 held-out days and a ≥0.05 °F cut to turn on; stays on while it helps; pauses when it stops.
    public static var autoOffFootnote: String {
        let f = String(format: "%.2f", BiasCorrection.heldOutOnGainC * 1.8)
        let c = String(format: "%.2f", BiasCorrection.heldOutOnGainC)
        return "Needs at least \(BiasCorrection.heldOutMinDays) held-out days and a ≥\(f) °F (\(c) °C) cut to turn on. It stays on while it still helps, and pauses when it stops helping."
    }
}
