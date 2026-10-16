import Foundation

/// Radar loop playback speed multipliers (radar-features §4).
public enum RadarPlaybackSpeed: Double, CaseIterable, Codable, Sendable, Identifiable {
    case half = 0.5
    case one = 1
    case two = 2
    case four = 4

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .half: "½×"
        case .one: "1×"
        case .two: "2×"
        case .four: "4×"
        }
    }

    /// Frame dwell in milliseconds for a given base interval at this speed.
    public func frameMilliseconds(baseMs: Double) -> Double {
        max(40, baseMs / rawValue)
    }

    /// Hold-on-latest / hold-on-now dwells scale with speed the same way as frame interval.
    public func holdMilliseconds(baseMs: Double) -> Double {
        max(40, baseMs / rawValue)
    }
}
