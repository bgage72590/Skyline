import Foundation

/// Turns the 15-minute nowcast (mm accumulated over the *preceding* 15 min) into a smooth
/// per-minute rain-rate curve for the "Next 2 Hours" chart.
///
/// Each 15-min total becomes a rate (mm/h) centred in its interval; the rates are joined with a
/// monotone cubic (Fritsch–Carlson), so the curve is smooth but never overshoots below zero or above
/// the neighbouring values (no phantom showers between dry slots).
public enum NowcastCurve {
    public struct Sample: Hashable, Sendable {
        public let time: Date
        /// Rain rate in mm/h.
        public let rate: Double
    }

    /// Intensity bands (mm/h), as used by the NWS / AMS glossary.
    public static let lightUpper = 2.5
    public static let moderateUpper = 7.6
    public static let heavyRef = 16.0

    public static func samples(_ minutely: [MinutelyPrecipitation], from start: Date, minutes: Int = 120,
                               step: Int = 1) -> [Sample] {
        let knots = minutely.sorted { $0.time < $1.time }
            .map { (t: $0.time.timeIntervalSince1970 - 450, r: max(0, $0.precipitation) * 4) }
        guard minutes > 0, step > 0 else { return [] }
        let times = stride(from: 0, through: minutes, by: step).map { start.addingTimeInterval(Double($0) * 60) }
        guard knots.count >= 2 else {
            let r = knots.first?.r ?? 0
            return times.map { Sample(time: $0, rate: r) }
        }
        let n = knots.count
        let xs = knots.map(\.t), ys = knots.map(\.r)
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        return times.map { date in
            let x = date.timeIntervalSince1970
            if x <= xs[0] { return Sample(time: date, rate: ys[0]) }
            if x >= xs[n - 1] { return Sample(time: date, rate: ys[n - 1]) }
            var i = 0
            while i < n - 2, x > xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
            let t2 = t * t, t3 = t2 * t
            let v = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
            let lo = min(ys[i], ys[i + 1]), hi = max(ys[i], ys[i + 1])
            return Sample(time: date, rate: min(max(v, lo), hi))
        }
    }

    /// Perceptual chart level: 0…1 light (square-root, so drizzle is visible), 1…2 moderate, 2…3 heavy.
    public static func level(_ rate: Double) -> Double {
        if rate <= 0 { return 0 }
        if rate < lightUpper { return (rate / lightUpper).squareRoot() }
        if rate < moderateUpper { return 1 + (rate - lightUpper) / (moderateUpper - lightUpper) }
        return min(3, 2 + (rate - moderateUpper) / (heavyRef - moderateUpper))
    }

    /// The dropdown's 46-pt chart: a wet quarter's light rain (≥ 0.4 mm/h, i.e. 0.1 mm per 15 min) draws
    /// at least a quarter of the height instead of a ~6-pt sliver. Heavier rain is unchanged.
    public static let miniLightFloor = 0.75
    public static func miniLevel(_ rate: Double) -> Double {
        rate >= 0.4 ? max(level(rate), miniLightFloor) : level(rate)
    }

    public static func intensityName(_ rate: Double) -> String {
        rate < 0.1 ? "None" : rate < lightUpper ? "Light" : rate < moderateUpper ? "Moderate" : "Heavy"
    }
}
