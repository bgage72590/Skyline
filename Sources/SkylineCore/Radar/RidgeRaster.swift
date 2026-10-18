#if canImport(Compression)
import Compression
#endif
import Foundation

/// Item 4: smooth local radar. IEM's single-site N0B tiles are drawn from a 1000×1000 lat/lon raster at
/// 0.011° (~1.2 × 0.9 km), so at the zooms used for a local site (z8–z10, 0.15–0.6 km/px) every radar
/// cell shows as a hard square. IEM also publishes that raster itself (8-bit palette PNG + world file),
/// whose indices are the reflectivity levels (0.5 dBZ steps). Skyline renders local tiles from it: the
/// level is interpolated bilinearly *before* colouring (IEM's own palette, so the legend still holds),
/// cores are kept at their full value (CR #7.3), and echo edges follow a coverage ≥ ½ contour instead of
/// a pixel staircase. One raster per scan serves every tile and zoom.
public struct RidgeRaster: Sendable {
    public let width: Int, height: Int
    /// Palette index per pixel, row-major from the north-west corner.
    public let indices: [UInt8]
    /// RGB per index (index 0 first).
    public let palette: [(UInt8, UInt8, UInt8)]
    /// Indices that mean "no echo": fully transparent in the PNG's tRNS (IEM: 0 and 1), else index 0.
    public let noEcho: [Bool]
    /// Centre of the north-west pixel, and the step per pixel (dLat negative).
    public let lon0: Double, lat0: Double, dLon: Double, dLat: Double

    /// Points within this fraction of a cell from a local-maximum cell's centre take its full value, so
    /// interpolation never lowers a core (CR #7.3). Small enough that cores stay round, not square.
    public static let peakRadius = 0.35

    public init(width: Int, height: Int, indices: [UInt8], palette: [(UInt8, UInt8, UInt8)], noEcho: [Bool]? = nil,
                lon0: Double, lat0: Double, dLon: Double, dLat: Double) {
        self.width = width; self.height = height; self.indices = indices; self.palette = palette
        self.noEcho = noEcho ?? (0..<256).map { $0 == 0 }
        self.lon0 = lon0; self.lat0 = lat0; self.dLon = dLon; self.dLat = dLat
    }

    /// ~1 MB per scan.
    public var heldBytes: Int { indices.count + palette.count * 3 + noEcho.count }

    /// ESRI world file: A, D, B, E, C, F (C/F = centre of the upper-left pixel). Rotation must be 0.
    public static func parseWorldFile(_ text: String) -> (dLon: Double, dLat: Double, lon0: Double, lat0: Double)? {
        let v = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard v.count == 6, v.allSatisfy(\.isFinite), v[1] == 0, v[2] == 0, v[0] > 0, v[0] < 1, v[3] < 0, v[3] > -1,
              abs(v[4]) <= 180, abs(v[5]) <= 90 else { return nil }
        return (v[0], v[3], v[4], v[5])
    }

    public static func decode(png: Data, worldFile: String) -> RidgeRaster? {
        guard let geo = parseWorldFile(worldFile), let img = PalettePNG.decode(png) else { return nil }
        return RidgeRaster(width: img.width, height: img.height, indices: img.indices, palette: img.palette,
                           noEcho: img.transparent, lon0: geo.lon0, lat0: geo.lat0, dLon: geo.dLon, dLat: geo.dLat)
    }

    @inline(__always) func echo(_ r: Int, _ c: Int) -> UInt8? {
        guard r >= 0, r < height, c >= 0, c < width else { return nil }
        let v = indices[r * width + c]
        return noEcho[Int(v)] ? nil : v
    }

    /// True when cell (r, c) has echo and no neighbour (8-connected) is higher.
    func isPeak(_ r: Int, _ c: Int, _ v: UInt8) -> Bool {
        for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
            if let n = echo(r + dr, c + dc), n > v { return false }
        } }
        return true
    }

    /// Smoothed palette index at a point, or nil for no echo. Bilinear over the 4 surrounding cells,
    /// averaging only cells with echo (no halo), drawn where those cover at least half. Near a local-max
    /// cell's centre the full peak value is kept, so every core reaches its raw maximum.
    public func sample(lon: Double, lat: Double) -> UInt8? {
        let fc = (lon - lon0) / dLon, fr = (lat - lat0) / dLat
        guard fc > -1, fr > -1, fc < Double(width), fr < Double(height) else { return nil }
        let c0 = Int(fc.rounded(.down)), r0 = Int(fr.rounded(.down))
        let tx = fc - Double(c0), ty = fr - Double(r0)
        var sum = 0.0, cover = 0.0
        let corners = [(0, 0, (1 - tx) * (1 - ty)), (0, 1, tx * (1 - ty)), (1, 0, (1 - tx) * ty), (1, 1, tx * ty)]
        for (dr, dc, w) in corners {
            guard let v = echo(r0 + dr, c0 + dc) else { continue }
            sum += Double(v) * w; cover += w
        }
        // Peak: the nearest cell, when it is a local maximum and the point is close to its centre.
        let nr = Int(fr.rounded()), nc = Int(fc.rounded())
        if let v = echo(nr, nc), (fr - Double(nr)) * (fr - Double(nr)) + (fc - Double(nc)) * (fc - Double(nc)) <= Self.peakRadius * Self.peakRadius,
           isPeak(nr, nc, v) {
            return v
        }
        guard cover >= 0.5 else { return nil }
        return UInt8(min(255, (sum / cover).rounded()))
    }

    /// Premultiplied RGBA (opaque or clear) for Web Mercator tile z/x/y, 256², palette colours only.
    public func renderTile(z: Int, x: Int, y: Int, size: Int = 256) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        guard (0...22).contains(z) else { return out }
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

/// Strict PNG reader for 8-bit palette images (colour type 3, no interlace), for untrusted bytes
/// (CR #7.1): every length is bounds-checked, dimensions are capped before multiplying, CRCs are
/// verified, and inflation stops at exactly the expected size. Anything odd returns nil; never traps.
public enum PalettePNG {
    public static let maxDimension = 4096
    /// Compressed IDAT bytes accepted (IEM rasters are ~25 KB).
    public static let maxCompressedBytes = 8 << 20
    public static let maxFileBytes = 8 << 20

    public struct Image: Sendable {
        public let width: Int, height: Int
        public let indices: [UInt8]
        public let palette: [(UInt8, UInt8, UInt8)]
        public let transparent: [Bool]
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func adler32(_ b: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0, i = 0
        while i < b.count {
            let end = min(i + 5552, b.count) // largest block before the sums can overflow 32 bits
            while i < end { a += UInt32(b[i]); s += a; i += 1 }
            a %= 65521; s %= 65521
        }
        return s << 16 | a
    }

    public static func crc32(_ b: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in b { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func decode(_ data: Data) -> (width: Int, height: Int, indices: [UInt8], palette: [(UInt8, UInt8, UInt8)], transparent: [Bool])? {
        guard data.count <= maxFileBytes else { return nil }
        let b = [UInt8](data)
        guard b.count >= 8 + 25, b[0..<8].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else { return nil }
        // CR #7 (final): read as UInt32, never as a signed Int shift (a length with the top bit set went
        // negative on 32-bit Int and slipped past the bounds check). PNG lengths are ≤ 2³¹ − 1.
        func be32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        func u32(_ i: Int) -> Int? { let v = be32(i); return v <= 0x7FFF_FFFF ? Int(v) : nil }
        var i = 8, w = 0, h = 0, sawIHDR = false, sawIEND = false
        var palette: [(UInt8, UInt8, UInt8)] = []
        var alpha: [UInt8] = []
        var idat: [UInt8] = []
        while i < b.count {
            guard b.count - i >= 12 else { return nil }
            guard let len = u32(i), len <= b.count - i - 12 else { return nil } // chunk + type + CRC must fit
            let start = i + 8, end = start + len
            let type = String(bytes: b[(i + 4)..<start], encoding: .ascii) ?? ""
            guard be32(end) == crc32(b[(i + 4)..<end]) else { return nil }
            if !sawIHDR, type != "IHDR" { return nil }
            switch type {
            case "IHDR":
                guard !sawIHDR, len == 13 else { return nil }
                sawIHDR = true
                guard let iw = u32(start), let ih = u32(start + 4) else { return nil }
                w = iw; h = ih
                // Capped *before* any multiplication (CR #7.1: no overflow).
                guard w > 0, h > 0, w <= maxDimension, h <= maxDimension else { return nil }
                // bit depth 8, palette, deflate, filter method 0, no interlace.
                guard b[start + 8] == 8, b[start + 9] == 3, b[start + 10] == 0, b[start + 11] == 0, b[start + 12] == 0 else { return nil }
            case "PLTE":
                guard palette.isEmpty, idat.isEmpty, len > 0, len % 3 == 0, len <= 768 else { return nil }
                palette = stride(from: start, to: end, by: 3).map { (b[$0], b[$0 + 1], b[$0 + 2]) }
            case "tRNS":
                guard !palette.isEmpty, idat.isEmpty, len <= palette.count else { return nil }
                alpha = Array(b[start..<end])
            case "IDAT":
                guard !palette.isEmpty, idat.count + len <= maxCompressedBytes else { return nil }
                idat.append(contentsOf: b[start..<end])
            case "IEND":
                sawIEND = true
            default:
                // Unknown critical chunks (uppercase first letter) can't be skipped safely.
                if let f = type.utf8.first, f >= 65, f <= 90 { return nil }
            }
            i = end + 4
            if sawIEND { break }
        }
        guard sawIEND, sawIHDR, !palette.isEmpty, idat.count > 6,
              idat[0] & 0x0F == 8, (UInt16(idat[0]) << 8 | UInt16(idat[1])) % 31 == 0, idat[1] & 0x20 == 0 else { return nil }
        let stride = w + 1, expected = stride * h // ≤ 4097 × 4096: no overflow
        guard let raw = inflate(idat[2...], exactly: expected) else { return nil }
        // CR #7 (final): the zlib trailer's Adler-32 must match what was inflated.
        let n = idat.count, trailer = UInt32(idat[n - 4]) << 24 | UInt32(idat[n - 3]) << 16 | UInt32(idat[n - 2]) << 8 | UInt32(idat[n - 1])
        guard adler32(raw) == trailer else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let f = raw[y * stride], row = y * stride + 1
            guard f <= 4 else { return nil }
            for x in 0..<w {
                let a = x > 0 ? out[y * w + x - 1] : 0
                let up = y > 0 ? out[(y - 1) * w + x] : 0
                let ul = (x > 0 && y > 0) ? out[(y - 1) * w + x - 1] : 0
                let pred: UInt8
                switch f {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = up
                case 3: pred = UInt8((Int(a) + Int(up)) / 2)
                default:
                    let p = Int(a) + Int(up) - Int(ul), pa = abs(p - Int(a)), pb = abs(p - Int(up)), pc = abs(p - Int(ul))
                    pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : ul)
                }
                out[y * w + x] = raw[row + x] &+ pred
            }
        }
        // Indices past the palette would read nothing: treat them as no echo.
        let transparent = (0..<256).map { $0 >= palette.count || ($0 < alpha.count && alpha[$0] == 0) || (alpha.isEmpty && $0 == 0) }
        return (w, h, out, palette, transparent)
    }

    /// Raw-deflate stream inflate that fails if the output would exceed `exactly` bytes (zip bombs) or
    /// ends short. Memory stays at `exactly` + a 64 KB window.
    public static func inflate(_ input: ArraySlice<UInt8>, exactly expected: Int) -> [UInt8]? {
        #if !canImport(Compression)
        return nil // no Compression framework (Linux CI/box): rasters fall back to IEM tiles
        #else
        guard expected > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: expected)
        let src = Array(input)
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(dst_ptr: scratch, dst_size: 0, src_ptr: UnsafePointer(scratch), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var produced = 0
        var overflow = false
        let ok: Bool = src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                guard let sp = s.baseAddress, let op = o.baseAddress else { return false }
                stream.src_ptr = sp; stream.src_size = s.count
                stream.dst_ptr = op; stream.dst_size = expected
                while true {
                    let before = stream.dst_size
                    let st = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    produced = expected - stream.dst_size
                    if st == COMPRESSION_STATUS_END { return true }
                    if st == COMPRESSION_STATUS_ERROR { return false }
                    if stream.dst_size == 0 {
                        // Output full but the stream wants to continue: probe one more byte.
                        var probe: UInt8 = 0
                        let more: Bool = withUnsafeMutablePointer(to: &probe) { pp in
                            stream.dst_ptr = pp; stream.dst_size = 1
                            let st2 = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                            return st2 == COMPRESSION_STATUS_ERROR || stream.dst_size == 0
                        }
                        if more { overflow = true; return false }
                        return true
                    }
                    // Input gone and no more output: truncated stream. (The decoder can still hold
                    // buffered output after the last input byte, so only stop once it stalls.)
                    if stream.src_size == 0, stream.dst_size == before { return false }
                }
            }
        }
        guard ok, !overflow, produced == expected else { return nil }
        return out
        #endif
    }
}

/// Fetches and caches one raster per scan, shared by every tile and zoom of that frame (LRU). Failures
/// are remembered with back-off (CR #7.4: no request storm while the archive lags). PNG decoding runs
/// off the actor, so lookups and other scans' decodes don't wait on it (CR #7.5).
public actor RidgeRasterStore {
    public typealias Fetch = @Sendable (URL) async -> Data?
    private let fetch: Fetch
    private var cache: [String: RidgeRaster] = [:]
    private var order: [String] = [] // least recently used first
    private var inFlight: [String: Task<RidgeRaster?, Never>] = [:]
    private var failures: [String: (at: Date, attempts: Int)] = [:]
    private var limit: Int
    public let normalLimit: Int
    private let clock: @Sendable () -> Date
    public private(set) var fetches = 0

    /// 40 scans ≈ 40 MB: a full 3-hour loop (37 frames) plus a fresh scan.
    public init(limit: Int = 40, clock: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping Fetch) {
        self.fetch = fetch; self.limit = limit; self.normalLimit = limit; self.clock = clock
    }

    /// Back-off after `attempts` consecutive failures: 10 s, 20 s, 40 s … capped at 5 min.
    public static func backoff(attempts: Int) -> TimeInterval { min(10 * pow(2, Double(max(attempts - 1, 0))), 300) }

    public func isBackingOff(_ base: String) -> Bool {
        guard let f = failures[base] else { return false }
        return clock().timeIntervalSince(f.at) < Self.backoff(attempts: f.attempts)
    }

    /// `base` is the scan URL without extension (`…/OKX_N0B_202610161748`). nil on failure or back-off.
    public func raster(base: String) async -> RidgeRaster? {
        if let r = cache[base] { touch(base); return r }
        if let t = inFlight[base] { return await t.value }
        if isBackingOff(base) { return nil }
        guard let png = URL(string: base + ".png"), let wld = URL(string: base + ".wld") else { return nil }
        fetches += 1
        let fetch = self.fetch
        let t = Task.detached(priority: .userInitiated) { () -> RidgeRaster? in
            async let p = fetch(png)
            async let w = fetch(wld)
            guard let pd = await p, let wd = await w, let text = String(data: wd, encoding: .ascii) else { return nil }
            return RidgeRaster.decode(png: pd, worldFile: text)
        }
        inFlight[base] = t
        let r = await t.value
        inFlight[base] = nil
        if let r {
            failures[base] = nil
            cache[base] = r
            touch(base)
            evict()
        } else {
            failures[base] = (clock(), (failures[base]?.attempts ?? 0) + 1)
            if failures.count > 200 { failures = failures.filter { isBackingOff($0.key) } }
        }
        return r
    }

    /// Memory pressure: keep only the newest `keep` scans (and use that as the cap) until `restore()`.
    public func trim(keep: Int) {
        limit = max(0, keep)
        evict()
    }
    public func restore() { limit = normalLimit }
    /// Window closed: drop every decoded scan (each ~1 MB). Back-off state and the cap are kept; the
    /// next radar shown re-fetches its scans (from the URL disk cache when they are still current).
    public func purge() {
        cache = [:]
        order = []
    }
    public var count: Int { cache.count }

    private func touch(_ base: String) {
        order.removeAll { $0 == base }
        order.append(base)
    }
    private func evict() {
        while order.count > limit { cache[order.removeFirst()] = nil }
    }
}
