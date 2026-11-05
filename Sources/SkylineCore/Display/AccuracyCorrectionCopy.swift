import Foundation

/// Accuracy-page copy only. Scores always grade the uncorrected blend.
/// The auto-off rule itself is unchanged; this text describes it.
public enum AccuracyCorrectionCopy {
    public static let scoresCaption = "Scores grade Skyline’s forecast before bias correction."
    public static let howItWorksSuffix = " All scores on this page grade forecasts before bias correction, so they show how the raw blend did, not the small adjustments listed under Bias correction."
    public static let autoOffFootnote = "“Paused” means the correction made recent forecasts worse, so Skyline stopped applying it. It turns back on only after at least \(BiasCorrection.autoOffReenableDays) more scored days and only if it would have cut the error by at least 0.1 °F (0.05 °C)."
}
