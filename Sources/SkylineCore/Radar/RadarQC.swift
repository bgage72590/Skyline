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
    public static let fragmentKey = "qc="
    /// MRMS publishes `lcref` every 2 minutes, ~5–8 minutes behind real time.
    public static let stepMinutes = 2
    /// Frames newer than the newest mask reuse it only within this gap; beyond it they go unmasked.
    public static let maxMaskLag: TimeInterval = 15 * 60
    /// Mask growth in pixels: covers mask/frame timing (≤ 8 min), MRMS 1 km cells and edge smoothing.
    public static let dilation = 3

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

    /// Splits a tile URL into the image to download and its optional QC mask.
    public static func split(_ url: URL) -> (image: URL, mask: URL?) {
        let s = url.absoluteString
        guard let r = s.range(of: "#" + fragmentKey) else { return (url, nil) }
        let base = URL(string: String(s[..<r.lowerBound])) ?? url
        return (base, URL(string: String(s[r.upperBound...])))
    }

    /// Clears (sets to 0) every RGBA pixel with no mask echo within `dilation` pixels. `rgba` is
    /// width×height×4 bytes; `maskAlpha` is the mask tile's alpha channel at the same size.
    public static func apply(rgba: inout [UInt8], width: Int, height: Int, maskAlpha: [UInt8], dilation: Int = dilation) {
        guard width > 0, height > 0, rgba.count == width * height * 4, maskAlpha.count == width * height else { return }
        let keep = dilate(maskAlpha.map { $0 > 0 }, width: width, height: height, radius: dilation)
        for p in 0..<(width * height) where !keep[p] {
            rgba[p * 4] = 0; rgba[p * 4 + 1] = 0; rgba[p * 4 + 2] = 0; rgba[p * 4 + 3] = 0
        }
    }

    /// Square (Chebyshev) dilation, separable.
    static func dilate(_ on: [Bool], width w: Int, height h: Int, radius r: Int) -> [Bool] {
        guard r > 0 else { return on }
        var rows = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var hit = false
                for dx in max(0, x - r)...min(w - 1, x + r) where on[y * w + dx] { hit = true; break }
                rows[y * w + x] = hit
            }
        }
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var hit = false
                for dy in max(0, y - r)...min(h - 1, y + r) where rows[dy * w + x] { hit = true; break }
                out[y * w + x] = hit
            }
        }
        return out
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

extension RadarQC {
    /// `image` with pixels outside the (dilated) `mask` echoes cleared. nil if the sizes differ or drawing
    /// fails, in which case the caller shows the tile unmasked.
    public static func masked(_ image: CGImage, mask: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, mask.width == w, mask.height == h else { return nil }
        // Same space as the tile so the N0Q/N0B colours come through unchanged.
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        var px = RadarTilePacker.render(image, space: space)
        let m = RadarTilePacker.render(mask, space: space)
        guard px.count == w * h * 4, m.count == w * h * 4 else { return nil }
        let alpha = (0..<(w * h)).map { m[$0 * 4 + 3] }
        apply(rgba: &px, width: w, height: h, maskAlpha: alpha)
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#endif
