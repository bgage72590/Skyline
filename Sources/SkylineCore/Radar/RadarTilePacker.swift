#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// A decoded radar tile as held in memory (build 42). Radar tiles use a small palette with fully
/// transparent or fully opaque pixels, so a 256² RGBA tile (256 KB) is kept as 8-bit palette indices
/// (64 KB), the same pixels. Only the frame on screen is expanded back to RGBA, for drawing.
/// Tiles with more than 256 colours or any partial transparency are kept exactly as decoded.
public final class RadarTile: @unchecked Sendable {
    public let width: Int, height: Int
    private let rgba: CGImage?
    private let indices: [UInt8]
    /// Premultiplied RGBA per palette index; index 0 is transparent.
    private let palette: [UInt32]
    private let space: CGColorSpace

    init(rgba: CGImage) {
        self.rgba = rgba; width = rgba.width; height = rgba.height
        indices = []; palette = []; space = rgba.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    }

    init(width: Int, height: Int, indices: [UInt8], palette: [UInt32], space: CGColorSpace) {
        rgba = nil; self.width = width; self.height = height
        self.indices = indices; self.palette = palette; self.space = space
    }

    public var isPacked: Bool { rgba == nil }

    /// Bytes this tile holds.
    public var heldBytes: Int { rgba.map { $0.bytesPerRow * $0.height } ?? indices.count + palette.count * 4 }

    /// A drawable image: the stored one, or a fresh RGBA expansion (released with the caller's copy,
    /// so nothing is cached per tile).
    public func image() -> CGImage? {
        if let rgba { return rgba }
        var out = [UInt32](repeating: 0, count: width * height)
        palette.withUnsafeBufferPointer { pal in
            for i in 0..<indices.count { out[i] = pal[Int(indices[i])] }
        }
        let data = out.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

public enum RadarTilePacker {
    public static func pack(_ image: CGImage) -> RadarTile {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 1024 * 1024 else { return RadarTile(rgba: image) }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpaceCreateDeviceRGB()
        var px = [UInt32](repeating: 0, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return RadarTile(rgba: image) }
        var lookup: [UInt32: UInt8] = [0: 0]
        var palette: [UInt32] = [0]
        var indices = [UInt8](repeating: 0, count: w * h)
        for p in 0..<(w * h) {
            let v = px[p]
            // Byte order in memory is R,G,B,A; alpha is the top byte of the little-endian UInt32.
            let a = UInt8(truncatingIfNeeded: v.littleEndian >> 24)
            if a == 0 { continue }
            guard a == 255 else { return RadarTile(rgba: image) }
            if let i = lookup[v] { indices[p] = i; continue }
            guard palette.count < 256 else { return RadarTile(rgba: image) }
            let i = UInt8(palette.count)
            lookup[v] = i
            palette.append(v)
            indices[p] = i
        }
        return RadarTile(width: w, height: h, indices: indices, palette: palette, space: space)
    }

    /// Premultiplied RGBA bytes of `image` drawn 1:1 (for lossless checks).
    public static func render(_ image: CGImage, space: CGColorSpace? = nil) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: space ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.interpolationQuality = .none
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }
}
#endif
