import Foundation

/// False-green fix (item 3). IEM's NEXRAD tiles (national `USCOMP-N0Q` and single-site `N0B`) are
/// coloured from raw base reflectivity, which keeps non-precipitation echoes: on a clear October night
/// (KBDR "CLR", 9:35 PM ET Oct 15) the N0Q mosaic read 20–33 dBZ over Fairfield (nocturnal bird
/// migration / clear-air returns), so a higher dBZ floor would not have removed it. NOAA's MRMS
/// lowest-altitude composite reflectivity (`lcref`) is quality-controlled (dual-pol non-meteorological
/// echo removal) and was empty there while still showing real rain elsewhere.
///
/// So each NEXRAD frame carries an MRMS QC mask: a tile pixel is drawn only where the matching `lcref`
/// tile has an echo nearby. Colours and the dBZ legend are unchanged (still N0Q/N0B). The mask rides in
/// the frame URL's fragment (`#qc=<mask template>`), which is never sent to the server, so tile caching
/// and coalescing keep working off one string.
public enum RadarQC {
    public static let tileSize = 256
    public static let fragmentKey = "qc="
    /// MRMS publishes `lcref` every 2 minutes, ~5–8 minutes behind real time.
    public static let stepMinutes = 2
    /// Frames newer than the newest mask reuse it only within this gap; beyond it they go unmasked.
    public static let maxMaskLag: TimeInterval = 15 * 60
    /// Mask growth on the ground (CR #6.1): a 60 km/h storm moves 8 km in the ≤ 8 min a mask can lag
    /// its frame, plus 1 km for MRMS cells. Converted to pixels per mask zoom and latitude.
    public static let marginMeters = 9_000.0

    struct Raw: Decodable { struct Meta: Decodable { var end_valid: String }; var meta: Meta }

    /// Newest MRMS `lcref` valid time from IEM's `lcref.json`.
    public static func latestValid(_ data: Data) throws -> Date? {
        ISO8601DateFormatter().date(from: try JSONDecoder().decode(Raw.self, from: data).meta.end_valid)
    }

    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }

    /// The `lcref` time to mask a frame at `time` with: the frame's own 2-minute slot, capped at the newest
    /// published mask. nil when the newest mask is too old to trust for this frame.
    public static func maskTime(for time: Date, latestMask: Date) -> Date? {
        let slot = Date(timeIntervalSince1970: (time.timeIntervalSince1970 / Double(stepMinutes * 60)).rounded(.down) * Double(stepMinutes * 60))
        if slot <= latestMask { return slot }
        return time.timeIntervalSince(latestMask) <= maxMaskLag ? latestMask : nil
    }

    public static func maskTemplate(at time: Date) -> String {
        "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-\(formatter().string(from: time))/{z}/{x}/{y}.png"
    }

    /// Adds the QC mask to observed IEM NEXRAD frames (forecast and already-masked frames untouched).
    public static func masked(_ frames: [RadarFrame], latestMask: Date) -> [RadarFrame] {
        frames.map { f in
            guard !f.isForecast, !f.urlTemplate.contains("#"),
                  f.urlTemplate.contains("ridge::"),
                  let t = maskTime(for: f.time, latestMask: latestMask) else { return f }
            var g = f
            g.urlTemplate = f.urlTemplate + "#" + fragmentKey + maskTemplate(at: t)
            return g
        }
    }

    /// Splits a tile URL into the image to download, its QC mask template (`…/{z}/{x}/{y}.png`, the
    /// fragment had the display tile's numbers substituted in) and the display tile.
    public static func split(_ url: URL) -> (image: URL, maskTemplate: String?, tile: RadarQCMask.TileID?) {
        let s = url.absoluteString
        guard let r = s.range(of: "#" + fragmentKey) else { return (url, nil, nil) }
        let base = String(s[..<r.lowerBound])
        let image = URL(string: base) ?? url
        func zxy(_ u: String) -> (prefix: Substring, tile: RadarQCMask.TileID)? {
            let parts = u.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count > 4, let z = Int(parts[parts.count - 3]), let x = Int(parts[parts.count - 2]),
                  let y = Int(parts[parts.count - 1].split(separator: ".").first ?? "") else { return nil }
            return (u.dropLast(parts.suffix(3).joined(separator: "/").count), .init(z: z, x: x, y: y))
        }
        guard let img = zxy(base), let mask = zxy(String(s[r.upperBound...])) else { return (image, nil, nil) }
        return (image, mask.prefix + "{z}/{x}/{y}.png", img.tile)
    }

}

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO

extension RadarQC {
    /// Alpha bytes of a 256² mask tile; `[]` if every pixel is transparent (clear sky: nothing to keep).
    public static func alpha(of mask: CGImage) -> [UInt8]? {
        guard mask.width == tileSize, mask.height == tileSize else { return nil }
        let px = RadarTilePacker.render(mask, space: CGColorSpaceCreateDeviceRGB())
        let a = (0..<(tileSize * tileSize)).map { px[$0 * 4 + 3] }
        return a.contains { $0 > 0 } ? a : []
    }

    /// Display tile `image` with pixels outside the dilated `mask` cleared, plus its PNG encoding (so it
    /// is stored compressed). nil if sizes differ or drawing fails; the caller then fails open.
    public static func masked(_ image: CGImage, tile: RadarQCMask.TileID, mask: [UInt8]) -> (image: CGImage, png: Data)? {
        let w = image.width, h = image.height
        guard w == tileSize, h == tileSize else { return nil }
        // Same space as the tile so the N0Q/N0B colours come through unchanged.
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        var px = RadarTilePacker.render(image, space: space)
        RadarQCMask.apply(rgba: &px, tile: tile, mask: mask)
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out, data as Data)
    }
}
#endif
