import Foundation

/// Moon phase from the mean synodic month (accurate to a few hours, plenty for a weather app).
public struct MoonPhase: Hashable, Sendable {
    /// 0 = new, 0.25 = first quarter, 0.5 = full, 0.75 = last quarter.
    public let fraction: Double

    public static let synodicMonth = 29.530588853
    /// Reference new moon: 2000-01-06 18:14 UTC.
    static let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)

    public init(date: Date) {
        let days = date.timeIntervalSince(Self.referenceNewMoon) / 86_400
        let f = (days / Self.synodicMonth).truncatingRemainder(dividingBy: 1)
        fraction = f < 0 ? f + 1 : f
    }

    /// Illuminated fraction of the disc, 0…1.
    public var illumination: Double { (1 - cos(2 * .pi * fraction)) / 2 }

    public var name: String {
        switch fraction {
        case ..<0.0339, 0.9661...: return "New Moon"
        case ..<0.216: return "Waxing Crescent"
        case ..<0.284: return "First Quarter"
        case ..<0.466: return "Waxing Gibbous"
        case ..<0.534: return "Full Moon"
        case ..<0.716: return "Waning Gibbous"
        case ..<0.784: return "Last Quarter"
        default: return "Waning Crescent"
        }
    }

    public var symbolName: String {
        switch name {
        case "New Moon": return "moonphase.new.moon"
        case "Waxing Crescent": return "moonphase.waxing.crescent"
        case "First Quarter": return "moonphase.first.quarter"
        case "Waxing Gibbous": return "moonphase.waxing.gibbous"
        case "Full Moon": return "moonphase.full.moon"
        case "Waning Gibbous": return "moonphase.waning.gibbous"
        case "Last Quarter": return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }

    /// Days until the next full moon (0 if it's full now).
    public var daysUntilFull: Double {
        if name == "Full Moon" { return 0 }
        let d = (0.5 - fraction) * Self.synodicMonth
        return d >= 0 ? d : d + Self.synodicMonth
    }
}

/// Slippy-map tile math in MapKit "map points" (MKMapSize.world is 2^28 points square).
public struct TileKey: Hashable, Sendable, CustomStringConvertible {
    public let z: Int, x: Int, y: Int
    public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y }
    public var description: String { "\(z)/\(x)/\(y)" }
}

public struct MapRectValue: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum TileMath {
    public static let worldSize: Double = 268_435_456

    public static func tileSize(_ z: Int) -> Double { worldSize / Double(1 << z) }

    /// Zoom level whose tiles render at roughly `targetPoints` on screen (radar data is coarse, so tiles are
    /// allowed to be upscaled ~1.5× to keep tile counts and memory low), clamped to the provider's native range.
    public static func zoom(visibleWidth: Double, viewWidth: Double, maxZ: Int, targetPoints: Double = 384) -> Int {
        guard visibleWidth > 0, viewWidth > 0 else { return 1 }
        let worldPoints = viewWidth * worldSize / visibleWidth
        let z = Int(log2(worldPoints / targetPoints).rounded())
        return min(max(z, 1), maxZ)
    }

    /// Tiles covering `visible` (+ `margin` tiles around it), nearest to the centre first.
    public static func tiles(covering visible: MapRectValue, z: Int, margin: Int = 0) -> [TileKey] {
        let ts = tileSize(z), n = 1 << z
        let x0 = max(0, Int(floor(visible.x / ts)) - margin), x1 = min(n - 1, Int(ceil((visible.x + visible.width) / ts)) - 1 + margin)
        let y0 = max(0, Int(floor(visible.y / ts)) - margin), y1 = min(n - 1, Int(ceil((visible.y + visible.height) / ts)) - 1 + margin)
        guard x0 <= x1, y0 <= y1 else { return [] }
        var keys: [TileKey] = []
        for x in x0...x1 { for y in y0...y1 { keys.append(TileKey(z: z, x: x, y: y)) } }
        let cx = visible.midX / ts, cy = visible.midY / ts
        return keys.sorted {
            let a = pow(Double($0.x) + 0.5 - cx, 2) + pow(Double($0.y) + 0.5 - cy, 2)
            let b = pow(Double($1.x) + 0.5 - cx, 2) + pow(Double($1.y) + 0.5 - cy, 2)
            return a < b
        }
    }

    public static func rect(_ key: TileKey) -> MapRectValue {
        let ts = tileSize(key.z)
        return MapRectValue(x: Double(key.x) * ts, y: Double(key.y) * ts, width: ts, height: ts)
    }
}
