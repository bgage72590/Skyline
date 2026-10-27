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
        // Compare each model with the blend on the same lead times (a model that only forecasts 0–48 h
        // must not be compared with the blend's 5-day error), and only with enough hours to mean anything.
        func blendOnSameLeads(_ s: VerificationSource) -> Double? {
            guard !r.byBucket.isEmpty else { return mae }
            var num = 0.0, den = 0.0
            for bucket in r.byBucket.values {
                guard let n = bucket[s]?.tempN, n > 0, let b = bucket[.blend]?.tempMAE else { continue }
                num += b * n; den += n
            }
            return den > 0 ? num / den : nil
        }
        let best = VerificationSource.inputs
            .compactMap { s -> (source: VerificationSource, mae: Double, blend: Double)? in
                guard let sc = r.overall[s], (sc.tempHours > 0 ? Double(sc.tempHours) : sc.tempN) >= minHours,
                      let m = sc.tempMAE, let b = blendOnSameLeads(s)
                else { return nil }
                return (s, m, b)
            }
            .min { $0.mae - $0.blend < $1.mae - $1.blend }
        var text: String
        if r.status == .collecting {
            text = "Early numbers (\(days)): Skyline’s temperatures have been off by about \(delta(mae)) on average."
        } else {
            text = "Over \(days) of checks, Skyline’s temperatures were off by \(delta(mae)) on average"
            if let best {
                // When the model covers fewer forecast ranges, say what it's compared with on the same hours.
                let sameHours = abs(best.blend - mae) < 0.05 ? "" : " vs Skyline’s \(delta(best.blend)) on the same forecast hours"
                if best.blend <= best.mae + 0.05 {
                    text += ", as good as or better than any single model (best: \(best.source.displayName), \(delta(best.mae))\(sameHours))."
                } else {
                    text += "; \(best.source.displayName) alone did slightly better here (\(delta(best.mae))\(sameHours))."
                }
            } else {
                text += "."
            }
        }
        // Fix 2: headline % = age-weighted hitRate (same accessor as the Accuracy card), not rainAccuracy.
        // Guard uses real rainy-hour counts when present (plan: rainy hours, not rainN).
        let rainyHours = blend.wetHours > 0 ? Double(blend.wetHours) : (blend.hits + blend.misses)
        if let caught = blend.hitRate, rainyHours >= minRainyHoursForHeadline {
            let pct = Int((caught * 100).rounded())
            text += " Rain: caught \(pct)% of rainy hours"
            if blend.wetHours > 0 {
                text += " (\(blend.wetHoursCaught) of \(blend.wetHours) rainy hours)."
            } else {
                let caughtN = Int(blend.hits.rounded())
                let totalN = Int((blend.hits + blend.misses).rounded())
                text += " (\(caughtN) of \(totalN) rainy hours)."
            }
        }
        return text
    }

    /// Fewest verified hours before a single model is named in the headline.
    static let minHours = 20.0
    /// Fewest rainy hours (weighted hits+misses) before the rain clause appears.
    public static let minRainyHoursForHeadline = 12.0

    static func daysPhrase(_ d: Double) -> String {
        if d < 1 { return "the first day" }
        let n = Int(min(d, 90).rounded())
        return n == 1 ? "1 day" : "\(n) days"
    }
}
