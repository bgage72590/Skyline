import Foundation

/// Item 4: smooth local radar. IEM's single-site N0B tiles are drawn from a 1000×1000 lat/lon raster at
/// 0.011° (~1.2 × 0.9 km), so at the zooms used for a local site (z8–z10, 0.15–0.6 km/px) every radar
/// cell shows as a hard square. IEM also publishes that raster itself (8-bit palette PNG + world file),
/// whose indices are the reflectivity levels. Skyline now renders local tiles from it: the level is
/// interpolated bilinearly *before* colouring (with IEM's own palette, so the legend still holds), and
/// echo edges follow a coverage ≥ ½ contour instead of a pixel staircase. No extra network for zooming
/// in (one raster per scan serves every tile and zoom), and tiles are still palette-sized.
public struct RidgeRaster: Sendable {
    public let width: Int, height: Int
    /// Palette index per pixel, row-major from the north-west corner. 0 and 1 are "no echo" (transparent).
    public let indices: [UInt8]
    /// RGB per index (index 0 first).
    public let palette: [(UInt8, UInt8, UInt8)]
    /// Centre of the north-west pixel, and the step per pixel (dLat negative).
    public let lon0: Double, lat0: Double, dLon: Double, dLat: Double

    public static let firstEchoIndex: UInt8 = 2

    public init(width: Int, height: Int, indices: [UInt8], palette: [(UInt8, UInt8, UInt8)],
                lon0: Double, lat0: Double, dLon: Double, dLat: Double) {
        self.width = width; self.height = height; self.indices = indices; self.palette = palette
        self.lon0 = lon0; self.lat0 = lat0; self.dLon = dLon; self.dLat = dLat
    }

    /// ~1 MB per scan.
    public var heldBytes: Int { indices.count + palette.count * 3 }

    /// ESRI world file: A, D, B, E, C, F (C/F = centre of the upper-left pixel). Rotation must be 0.
    public static func parseWorldFile(_ text: String) -> (dLon: Double, dLat: Double, lon0: Double, lat0: Double)? {
        let v = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard v.count == 6, v[1] == 0, v[2] == 0, v[0] > 0, v[3] < 0 else { return nil }
        return (v[0], v[3], v[4], v[5])
    }

    /// Decodes IEM's raster: an 8-bit, non-interlaced, palette PNG. (ImageIO expands palettes to RGB,
    /// and IEM's palette repeats colours, so the indices have to come from the PNG itself.)
    public static func decode(png: Data, worldFile: String) -> RidgeRaster? {
        guard let geo = parseWorldFile(worldFile), let img = PalettePNG.decode(png) else { return nil }
        return RidgeRaster(width: img.width, height: img.height, indices: img.indices, palette: img.palette,
                           lon0: geo.lon0, lat0: geo.lat0, dLon: geo.dLon, dLat: geo.dLat)
    }

    /// Smoothed palette index at a point, or nil for no echo. Bilinear over the 4 surrounding cells:
    /// the level is averaged over the cells that have echo, drawn only where those cover at least half.
    public func sample(lon: Double, lat: Double) -> UInt8? {
        let fc = (lon - lon0) / dLon, fr = (lat - lat0) / dLat
        let c0 = Int(fc.rounded(.down)), r0 = Int(fr.rounded(.down))
        let tx = fc - Double(c0), ty = fr - Double(r0)
        var sum = 0.0, cover = 0.0
        for (dr, dc, w) in [(0, 0, (1 - tx) * (1 - ty)), (0, 1, tx * (1 - ty)), (1, 0, (1 - tx) * ty), (1, 1, tx * ty)] {
            let r = r0 + dr, c = c0 + dc
            guard r >= 0, r < height, c >= 0, c < width else { continue }
            let v = indices[r * width + c]
            guard v >= Self.firstEchoIndex else { continue }
            sum += Double(v) * w; cover += w
        }
        guard cover >= 0.5 else { return nil }
        return UInt8(min(255, max(Double(Self.firstEchoIndex), (sum / cover).rounded())))
    }

    /// Premultiplied RGBA (opaque or clear) for Web Mercator tile z/x/y, 256², palette colours only.
    public func renderTile(z: Int, x: Int, y: Int, size: Int = 256) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let n = pow(2.0, Double(z))
        var lons = [Double](repeating: 0, count: size)
        for px in 0..<size { lons[px] = (Double(x) + (Double(px) + 0.5) / Double(size)) / n * 360 - 180 }
        for py in 0..<size {
            let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + (Double(py) + 0.5) / Double(size)) / n))) * 180 / .pi
            let fr = (lat - lat0) / dLat
            if fr < -1 || fr > Double(height) { continue }
            for px in 0..<size {
                guard let v = sample(lon: lons[px], lat: lat), Int(v) < palette.count else { continue }
                let c = palette[Int(v)], p = (py * size + px) * 4
                out[p] = c.0; out[p + 1] = c.1; out[p + 2] = c.2; out[p + 3] = 255
            }
        }
        return out
    }
}

/// Minimal PNG reader for 8-bit palette images (colour type 3, no interlace): IHDR, PLTE, IDAT.
public enum PalettePNG {
    public static func decode(_ data: Data) -> (width: Int, height: Int, indices: [UInt8], palette: [(UInt8, UInt8, UInt8)])? {
        let b = [UInt8](data)
        guard b.count > 8, b[0..<8].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        var i = 8, w = 0, h = 0
        var palette: [(UInt8, UInt8, UInt8)] = []
        var idat = Data()
        while i + 8 <= b.count {
            let len = u32(i), type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let start = i + 8
            guard start + len + 4 <= b.count else { return nil }
            switch type {
            case "IHDR":
                w = u32(start); h = u32(start + 4)
                // bit depth 8, colour type 3 (palette), compression/filter 0, no interlace.
                guard b[start + 8] == 8, b[start + 9] == 3, b[start + 12] == 0 else { return nil }
            case "PLTE":
                palette = stride(from: start, to: start + len - 2, by: 3).map { (b[$0], b[$0 + 1], b[$0 + 2]) }
            case "IDAT": idat.append(contentsOf: b[start..<(start + len)])
            case "IEND": i = b.count
            default: break
            }
            i = start + len + 4
        }
        guard w > 0, h > 0, w * h <= 4_000_000, !palette.isEmpty, idat.count > 2,
              let raw = try? (idat.dropFirst(2) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let r = [UInt8](raw), stride = w + 1
        guard r.count >= stride * h else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let f = r[y * stride], row = y * stride + 1
            for x in 0..<w {
                let a = x > 0 ? out[y * w + x - 1] : 0
                let up = y > 0 ? out[(y - 1) * w + x] : 0
                let ul = (x > 0 && y > 0) ? out[(y - 1) * w + x - 1] : 0
                let v = r[row + x]
                let pred: UInt8
                switch f {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = up
                case 3: pred = UInt8((Int(a) + Int(up)) / 2)
                case 4:
                    let p = Int(a) + Int(up) - Int(ul), pa = abs(p - Int(a)), pb = abs(p - Int(up)), pc = abs(p - Int(ul))
                    pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : ul)
                default: return nil
                }
                out[y * w + x] = v &+ pred
            }
        }
        return (w, h, out, palette)
    }
}

/// Fetches and caches one raster per scan, shared by every tile and zoom of that frame.
public actor RidgeRasterStore {
    public typealias Fetch = @Sendable (URL) async -> Data?
    private let fetch: Fetch
    private var cache: [String: RidgeRaster] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<RidgeRaster?, Never>] = [:]
    private let limit: Int
    public private(set) var fetches = 0

    /// 40 scans ≈ 40 MB: a full 3-hour loop (37 frames) plus a fresh scan.
    public init(limit: Int = 40, fetch: @escaping Fetch) { self.fetch = fetch; self.limit = limit }

    /// `base` is the scan URL without extension (`…/OKX_N0B_202610161748`). nil on failure (not cached).
    public func raster(base: String) async -> RidgeRaster? {
        if let r = cache[base] { return r }
        if let t = inFlight[base] { return await t.value }
        let t = Task { () -> RidgeRaster? in
            guard let png = URL(string: base + ".png"), let wld = URL(string: base + ".wld") else { return nil }
            await self.noteFetch()
            async let p = fetch(png)
            async let w = fetch(wld)
            guard let pd = await p, let wd = await w, let text = String(data: wd, encoding: .ascii) else { return nil }
            return RidgeRaster.decode(png: pd, worldFile: text)
        }
        inFlight[base] = t
        let r = await t.value
        inFlight[base] = nil
        if let r {
            if cache[base] == nil { order.append(base) }
            cache[base] = r
            while order.count > limit { cache[order.removeFirst()] = nil }
        }
        return r
    }

    private func noteFetch() { fetches += 1 }
}
