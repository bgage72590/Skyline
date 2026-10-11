import Foundation

/// The Accuracy screen's plain-English headline (T9): one sentence and one number instead of
/// MAE / Brier jargon. `delta` formats a temperature difference in °C for display (e.g. "1.9°F").
public enum AccuracySummary {
    public static func headline(_ r: AccuracyReport, delta: (Double) -> String) -> String {
        let days = daysPhrase(r.daysCollected)
        guard let blend = r.overall[.blend], let mae = blend.tempMAE, r.verifiedPairs > 0 else {
            return "Skyline is checking its forecasts against what the nearest weather station measures. "
                + "The first results appear once a few hours have been verified."
        }
        let best = VerificationSource.inputs
            .compactMap { s in r.overall[s]?.tempMAE.map { (source: s, mae: $0) } }
            .min { $0.mae < $1.mae }
        var text: String
        if r.status == .collecting {
            text = "Early numbers (\(days)): Skyline’s temperatures have been off by about \(delta(mae)) on average."
        } else {
            text = "Over \(days) of checks, Skyline’s temperatures were off by \(delta(mae)) on average"
            if let best {
                if mae <= best.mae + 0.05 {
                    text += ", as good as or better than any single model (best: \(best.source.displayName), \(delta(best.mae)))."
                } else {
                    text += "; \(best.source.displayName) alone did slightly better here (\(delta(best.mae)))."
                }
            } else {
                text += "."
            }
        }
        if let right = blend.rainAccuracy, blend.rainN >= 12 {
            text += " Rain calls were right \(Int((right * 100).rounded()))% of the time"
            if blend.hits + blend.misses >= 1 {
                text += " (\(Int(blend.hits.rounded())) of \(Int((blend.hits + blend.misses).rounded())) rainy hours caught)."
            } else {
                text += "."
            }
        }
        return text
    }

    static func daysPhrase(_ d: Double) -> String {
        if d < 1 { return "the first day" }
        let n = Int(min(d, 90).rounded())
        return n == 1 ? "1 day" : "\(n) days"
    }
}
