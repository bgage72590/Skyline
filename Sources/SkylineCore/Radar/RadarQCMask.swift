import Foundation

/// MRMS QC masks for NEXRAD tiles (PR #6 review fixes).
///
/// Masks are fetched at one fixed zoom (`maskZoom`, at most 6, ~1.8 km/px at 41°N) whatever zoom the map
/// is at, so one mask tile serves every display tile under it (16 at z8, 64 at z9): far fewer extra
/// requests than one mask per tile, and the masks are cached per (time, tile). The margin is dilated in
/// metres, not display pixels, so it is the same ~9 km at every zoom (CR #6.1), and each mask is dilated
/// over its 3×3 neighbourhood and then cropped, so an echo just across a tile seam still counts (CR #6.2).
public enum RadarQCMask {
    public static let maxMaskZoom = 6

    public static func maskZoom(forDisplayZoom z: Int) -> Int { max(0, min(z, maxMaskZoom)) }

    /// Ground metres per pixel at the centre row of tile `y` at zoom `z` (Web Mercator, 256 px tiles).
    public static func metersPerPixel(zoom z: Int, tileY y: Int) -> Double {
        let n = pow(2.0, Double(z))
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + 0.5) / n)))
        return 40_075_016.686 * cos(lat) / (Double(RadarQC.tileSize) * n)
    }

    /// The dilation radius in mask pixels for `marginMeters` (at least 1, at most one tile).
    public static func radiusPixels(maskZoom z: Int, tileY y: Int, marginMeters: Double = RadarQC.marginMeters) -> Int {
        min(RadarQC.tileSize, max(1, Int((marginMeters / metersPerPixel(zoom: z, tileY: y)).rounded(.up))))
    }

    public struct TileID: Hashable, Sendable { public var z, x, y: Int
        public init(z: Int, x: Int, y: Int) { self.z = z; self.x = x; self.y = y } }

    /// The mask tile covering display tile `t`, and where `t` sits inside it.
    public static func maskTile(for t: TileID) -> (tile: TileID, scale: Int, offsetX: Int, offsetY: Int) {
        let mz = maskZoom(forDisplayZoom: t.z), d = t.z - mz, s = 1 << d
        return (TileID(z: mz, x: t.x >> d, y: t.y >> d), s,
                (t.x & (s - 1)) * RadarQC.tileSize / s, (t.y & (s - 1)) * RadarQC.tileSize / s)
    }

    /// The 3×3 neighbourhood of a mask tile, row-major; x wraps round the antimeridian, rows past the
    /// poles are nil (no echoes there).
    public static func neighbourhood(of t: TileID) -> [TileID?] {
        let n = 1 << t.z
        return (-1...1).flatMap { dy in (-1...1).map { dx -> TileID? in
            let y = t.y + dy
            guard y >= 0, y < n else { return nil }
            return TileID(z: t.z, x: ((t.x + dx) % n + n) % n, y: y)
        } }
    }

    /// `true` where an echo lies within `radius` px (square window), computed over the 3×3 block of
    /// alpha tiles (nil = empty) and cropped to the centre tile. 256² bytes, 1 = keep.
    public static func dilatedCentre(_ block: [[UInt8]?], radius r: Int) -> [UInt8] {
        let t = RadarQC.tileSize, w = 3 * t
        var on = [UInt8](repeating: 0, count: w * w)
        for (k, alpha) in block.enumerated() {
            guard let alpha, alpha.count == t * t else { continue }
            let ox = (k % 3) * t, oy = (k / 3) * t
            for y in 0..<t { for x in 0..<t where alpha[y * t + x] > 0 { on[(oy + y) * w + ox + x] = 1 } }
        }
        // Separable square window via prefix sums; only rows within r of the centre tile matter.
        let lo = max(0, t - r), hi = min(w, 2 * t + r)
        var rows = [UInt8](repeating: 0, count: w * w)
        var prefix = [Int](repeating: 0, count: w + 1)
        for y in lo..<hi {
            for x in 0..<w { prefix[x + 1] = prefix[x] + Int(on[y * w + x]) }
            for x in t..<(2 * t) where prefix[min(w, x + r + 1)] - prefix[max(0, x - r)] > 0 { rows[y * w + x] = 1 }
        }
        var out = [UInt8](repeating: 0, count: t * t)
        for x in t..<(2 * t) {
            for y in 0..<w { prefix[y + 1] = prefix[y] + Int(rows[y * w + x]) }
            for y in t..<(2 * t) where prefix[min(w, y + r + 1)] - prefix[max(0, y - r)] > 0 { out[(y - t) * t + (x - t)] = 1 }
        }
        return out
    }

    /// Coverage of display pixel (x, y) in mask space. Pixel centres are sampled bilinearly so a mask
    /// fetched at z≤6 (4–16 display pixels per mask pixel) feathers instead of stamping hard squares
    /// onto light rain. Samples past the mask tile repeat the edge pixel: a fully-on mask does not fade
    /// the tile border, and a fully-off neighbour does not turn the border on.
    static func coverage(mask: [UInt8], scale: Int, offsetX: Int, offsetY: Int, x: Int, y: Int) -> Double {
        let n = RadarQC.tileSize
        let s = Double(max(scale, 1))
        let mx = min(Double(n - 1), max(0, Double(offsetX) + (Double(x) + 0.5) / s - 0.5))
        let my = min(Double(n - 1), max(0, Double(offsetY) + (Double(y) + 0.5) / s - 0.5))
        let x0 = min(n - 1, max(0, Int(mx.rounded(.down))))
        let y0 = min(n - 1, max(0, Int(my.rounded(.down))))
        let x1 = min(n - 1, x0 + 1), y1 = min(n - 1, y0 + 1)
        let fx = x0 == n - 1 ? 0 : mx - Double(x0)
        let fy = y0 == n - 1 ? 0 : my - Double(y0)
        let v00 = Double(mask[y0 * n + x0]), v10 = Double(mask[y0 * n + x1])
        let v01 = Double(mask[y1 * n + x0]), v11 = Double(mask[y1 * n + x1])
        let top = v00 * (1 - fx) + v10 * fx
        let bot = v01 * (1 - fx) + v11 * fx
        return top * (1 - fy) + bot * fy
    }

    /// Scales every RGBA pixel of display tile `t` by its bilinear mask coverage. Fully inside stays
    /// as drawn; fully outside is cleared. The feather (a mask-pixel edge) quantizes alpha to a multiple
    /// of 32 so the extra partial pixels stay a small PNG. Scale 1 samples pixel centres exactly, so a
    /// mask at the display zoom is still a hard on/off.
    ///
    /// `straightAlpha`: nearest-site tiles store legend RGB with an independent alpha (`RidgeRaster.renderTile`).
    /// The mask then changes alpha only, and `RadarQC.image` is the one premultiply before Quartz. IEM tiles
    /// arrive already premultiplied (`RadarTilePacker.render`); leave this false so RGB scales with alpha
    /// and a partial edge keeps its colour instead of a bright fringe.
    public static func apply(rgba: inout [UInt8], tile t: TileID, mask: [UInt8], straightAlpha: Bool = false) {
        let n = RadarQC.tileSize
        guard rgba.count == n * n * 4, mask.count == n * n else { return }
        let m = maskTile(for: t)
        for y in 0..<n {
            for x in 0..<n {
                let w = coverage(mask: mask, scale: m.scale, offsetX: m.offsetX, offsetY: m.offsetY, x: x, y: y)
                let p = (y * n + x) * 4
                let oldA = Int(rgba[p + 3])
                if w >= 0.999 || oldA == 0 { continue }
                if w <= 0.001 {
                    rgba[p] = 0; rgba[p + 1] = 0; rgba[p + 2] = 0; rgba[p + 3] = 0
                    continue
                }
                var a = Int((Double(oldA) * w).rounded())
                let q = Int((Double(a) / 32).rounded()) * 32
                a = min(oldA, max(32, q))
                if !straightAlpha {
                    rgba[p] = UInt8(Int(rgba[p]) * a / oldA)
                    rgba[p + 1] = UInt8(Int(rgba[p + 1]) * a / oldA)
                    rgba[p + 2] = UInt8(Int(rgba[p + 2]) * a / oldA)
                }
                rgba[p + 3] = UInt8(a)
            }
        }
    }
}

/// Fetches, dilates and caches QC masks. `fetchAlpha` returns a mask tile's alpha bytes (256²), `.empty`
/// for a tile outside coverage, or nil on any failure (IEM answers a missing MRMS slot with 503, not a
/// blank tile, checked Oct 16, 2026). Any failure in a neighbourhood makes the whole mask unavailable, so
/// the caller fails open for now and asks again later; failures are never cached.
/// Deferred #6 note: provisional (unmasked) tiles retried forever. After this many tries (5 s doubling
/// to 60 s ≈ 2.5 min) they stay as shown until the network returns, the Mac wakes or Retry is pressed.
public enum RadarProvisionalRetry {
    public static let maxAttempts = 6
    public static func shouldRetry(attempts: Int) -> Bool { attempts < maxAttempts }
}

/// Dilated QC masks are mostly zeros. RLE keeps 96 of them under half a megabyte, so a reopen
/// can apply the mask without the nine MRMS fetches that used to miss and back off.
enum MaskRLE {
    static func compress(_ bytes: [UInt8]) -> Data {
        if bytes.allSatisfy({ $0 == 0 }) { return Data([0]) }
        if bytes.allSatisfy({ $0 == 1 }) { return Data([1]) }
        var out = Data([2])
        var i = 0
        while i < bytes.count {
            let v = bytes[i]
            var n = 1
            let limit = min(bytes.count, i + 65535)
            while i + n < limit, bytes[i + n] == v { n += 1 }
            out.append(v)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            i += n
        }
        return out
    }

    static func decompress(_ data: Data, count: Int = RadarQC.tileSize * RadarQC.tileSize) -> [UInt8]? {
        guard count > 0, let first = data.first else { return nil }
        if first == 0 { return [UInt8](repeating: 0, count: count) }
        if first == 1 { return [UInt8](repeating: 1, count: count) }
        guard first == 2 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(count)
        let b = [UInt8](data)
        var i = 1
        while i + 2 < b.count, out.count < count {
            let n = Int(b[i + 1]) | (Int(b[i + 2]) << 8)
            if n == 0 || out.count + n > count { return nil }
            out.append(contentsOf: repeatElement(b[i], count: n))
            i += 3
        }
        return out.count == count ? out : nil
    }
}

public actor RadarQCMaskStore {
    public typealias Fetch = @Sendable (URL) async -> [UInt8]?

    private let fetchAlpha: Fetch
    private var masks: [String: [UInt8]] = [:]
    private var maskOrder: [String] = []
    private var raw: [String: [UInt8]] = [:]
    private var rawOrder: [String] = []
    private var inFlight: [String: Task<[UInt8]?, Never>] = [:]
    private var rawInFlight: [String: Task<[UInt8]?, Never>] = [:]
    private var packed: [String: Data] = [:]
    private var packedOrder: [String] = []
    private var packedBytes = 0
    private let maxMasks: Int, maxRaw: Int, compressedBudget: Int
    public private(set) var fetches = 0
    /// Half a megabyte of RLE masks. The decoded copies are what `cachedCount` reports.
    public static let defaultCompressedBudget = 512 * 1024
    public var compressedBytes: Int { packedBytes }

    /// Window closed: drop decoded masks and raw alpha (~64 KB each). The RLE copies stay, so the
    /// next ask does not refetch the 3×3 neighbourhood.
    public func purge() {
        masks = [:]; maskOrder = []
        raw = [:]; rawOrder = []
    }
    public var cachedCount: Int { masks.count + raw.count }

    /// Decode retained masks back into the hot cache. `template` limits that to one frame's masks.
    public func prewarm(template: String?) {
        for key in packedOrder where template == nil || key.hasPrefix((template ?? "") + "|") {
            guard masks[key] == nil, let data = packed[key], let bytes = MaskRLE.decompress(data) else { continue }
            remember(&masks, &maskOrder, key, bytes, limit: maxMasks)
        }
    }

    public init(maxMasks: Int = 96, maxRaw: Int = 160, compressedBudget: Int = RadarQCMaskStore.defaultCompressedBudget,
                fetchAlpha: @escaping Fetch) {
        self.fetchAlpha = fetchAlpha
        self.maxMasks = maxMasks
        self.maxRaw = maxRaw
        self.compressedBudget = compressedBudget
    }

    /// The dilated mask for `maskTemplate` (`…/{z}/{x}/{y}.png`) at mask tile `t`, or nil (fail open).
    public func mask(template: String, tile t: RadarQCMask.TileID) async -> [UInt8]? {
        let key = "\(template)|\(t.z)/\(t.x)/\(t.y)"
        if let m = masks[key] { return m }
        if let data = packed[key], let m = MaskRLE.decompress(data) {
            remember(&masks, &maskOrder, key, m, limit: maxMasks)
            touchPacked(key)
            return m
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.build(template: template, tile: t) }
        inFlight[key] = task
        let m = await task.value
        inFlight[key] = nil
        if let m {
            remember(&masks, &maskOrder, key, m, limit: maxMasks)
            storePacked(key, m)
        }
        return m
    }

    private func build(template: String, tile t: RadarQCMask.TileID) async -> [UInt8]? {
        // Deferred #6 note: the 3×3 neighbours are fetched concurrently, not one after another.
        let hood = RadarQCMask.neighbourhood(of: t)
        let results = await withTaskGroup(of: (Int, [UInt8]?).self) { group in
            for (i, n) in hood.enumerated() {
                guard let n else { continue }
                group.addTask { (i, await self.alpha(template: template, tile: n)) }
            }
            var out = [Int: [UInt8]?]()
            for await (i, a) in group { out[i] = a }
            return out
        }
        var block: [[UInt8]?] = []
        for i in hood.indices {
            guard hood[i] != nil else { block.append(nil); continue }
            guard let a = results[i] ?? nil else { return nil }
            block.append(a.isEmpty ? nil : a)
        }
        let r = RadarQCMask.radiusPixels(maskZoom: t.z, tileY: t.y)
        return RadarQCMask.dilatedCentre(block, radius: r)
    }

    private func alpha(template: String, tile t: RadarQCMask.TileID) async -> [UInt8]? {
        let s = template.replacingOccurrences(of: "{z}", with: "\(t.z)")
            .replacingOccurrences(of: "{x}", with: "\(t.x)").replacingOccurrences(of: "{y}", with: "\(t.y)")
        if let a = raw[s] { return a }
        guard let url = URL(string: s) else { return nil }
        // Adjacent masks share neighbours; concurrent builds join one request per raw tile.
        if let task = rawInFlight[s] { return await task.value }
        fetches += 1
        let fetch = fetchAlpha
        let task = Task { await fetch(url) }
        rawInFlight[s] = task
        let a = await task.value
        rawInFlight[s] = nil
        guard let a else { return nil }
        remember(&raw, &rawOrder, s, a, limit: maxRaw)
        return a
    }

    private func remember(_ dict: inout [String: [UInt8]], _ order: inout [String], _ k: String, _ v: [UInt8], limit: Int) {
        if dict[k] == nil { order.append(k) }
        dict[k] = v
        while order.count > limit { dict[order.removeFirst()] = nil }
    }

    private func storePacked(_ key: String, _ mask: [UInt8]) {
        guard mask.count == RadarQC.tileSize * RadarQC.tileSize else { return }
        let data = MaskRLE.compress(mask)
        guard data.count <= compressedBudget else { return }
        if let old = packed.removeValue(forKey: key) {
            packedBytes -= old.count
            packedOrder.removeAll { $0 == key }
        }
        while packedBytes + data.count > compressedBudget, !packedOrder.isEmpty {
            let oldest = packedOrder.removeFirst()
            if let old = packed.removeValue(forKey: oldest) { packedBytes -= old.count }
        }
        guard packedBytes + data.count <= compressedBudget else { return }
        packed[key] = data
        packedOrder.append(key)
        packedBytes += data.count
    }

    private func touchPacked(_ key: String) {
        guard packed[key] != nil else { return }
        packedOrder.removeAll { $0 == key }
        packedOrder.append(key)
    }
}
