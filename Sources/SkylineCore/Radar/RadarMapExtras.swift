import Foundation

/// Hit-testing helpers for NWS alert polygons on the radar map (radar-features §4).
public enum AlertHitTesting {
    /// The topmost alert whose ring contains `point` (later shapes win when they overlap), or nil.
    /// Uses the same ray-cast rule as `USCoverage.contains` so outline and click agree.
    public static func alertID(at point: Coordinate, shapes: [(id: String, rings: [[Coordinate]])]) -> String? {
        var hit: String?
        for shape in shapes {
            if shape.rings.contains(where: { USCoverage.contains($0, point) }) {
                hit = shape.id
            }
        }
        return hit
    }

    /// True when `point` is inside any ring of `shapes` (for overlay hitTest pass-through).
    public static func contains(_ point: Coordinate, shapes: [(id: String, rings: [[Coordinate]])]) -> Bool {
        alertID(at: point, shapes: shapes) != nil
    }
}

/// Range rings drawn around the forecast pin (10 / 25 / 50 miles).
public enum RangeRings {
    public static let miles: [Double] = [10, 25, 50]
    public static func meters(_ miles: Double) -> Double { miles * 1609.344 }

    /// Destination point `meters` away from `from` on bearing `degrees` (0 = north, clockwise).
    public static func destination(from: Coordinate, meters: Double, bearingDegrees: Double) -> Coordinate {
        let r = 6_371_000.0
        let δ = meters / r
        let θ = bearingDegrees * .pi / 180
        let φ1 = from.latitude * .pi / 180
        let λ1 = from.longitude * .pi / 180
        let sinφ2 = sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ)
        let φ2 = asin(min(1, max(-1, sinφ2)))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Coordinate(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }

    /// Sampled ring coordinates (closed) for drawing at the current zoom.
    public static func ring(center: Coordinate, miles: Double, samples: Int = 72) -> [Coordinate] {
        let m = meters(miles)
        return (0...samples).map { i in
            destination(from: center, meters: m, bearingDegrees: Double(i) * 360 / Double(samples))
        }
    }
}
