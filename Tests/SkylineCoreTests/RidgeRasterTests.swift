#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
import Foundation
import Testing
@testable import SkylineCore

/// Item 4: local KOKX radar rendered smoothly from IEM's scan raster (fixture: KOKX 17:48Z Oct 16, 2026).
struct RidgeRasterTests {
    static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    static func raster() throws -> RidgeRaster {
        let png = try fixture("OKX_N0B_202610161748", "png")
        let wld = String(decoding: try fixture("OKX_N0B_202610161748", "wld"), as: UTF8.self)
        return try #require(RidgeRaster.decode(png: png, worldFile: wld))
    }
    static let tile = (z: 10, x: 307, y: 383)

    @Test func decodesPaletteIndicesAndGeo() throws {
        let r = try Self.raster()
        #expect(r.width == 1000 && r.height == 1000 && r.palette.count == 256)
        #expect(abs(r.dLon - 0.010969) < 1e-9 && abs(r.lat0 - 46.349683) < 1e-9)
        // Same counts as an independent decode (Pillow): 984,709 empty cells, max level 159.
        #expect(r.indices.filter { $0 == 0 }.count == 984_709)
        #expect(r.noEcho[0] && r.noEcho[1] && !r.noEcho[2]) // from the PNG's tRNS, not hard-coded
        #expect(r.indices.max() == 159)
        #expect(RidgeRaster.parseWorldFile("1 0 0 -1 0") == nil)
        #expect(RidgeRaster.parseWorldFile("0.01 0.1 0 -0.01 -78 46") == nil) // rotated
        #expect(RidgeRaster.parseWorldFile("0.01 0 0 -0.01 nan 46") == nil)
        #expect(RidgeRaster.parseWorldFile("0.01 0 0 -0.01 -500 46") == nil)
        #expect(PalettePNG.decode(Data([1, 2, 3])) == nil)
    }

    @Test func sampleInterpolatesBeforeColouring() {
        // 2×1 raster: levels 100 and 140 at cell centres lon 0 and 1.
        let r = RidgeRaster(width: 2, height: 1, indices: [100, 140], palette: (0..<256).map { (UInt8($0), 0, 0) },
                            lon0: 0, lat0: 0, dLon: 1, dLat: -1)
        #expect(r.sample(lon: 0.5, lat: 0) == 120)
        // Near the higher cell's centre its full value is kept (it is a local max: cores aren't lowered).
        #expect(r.sample(lon: 0.9, lat: 0) == 140)
        #expect(r.sample(lon: 0.25, lat: 0) == 110)
        // Edge of the echo: drawn while the echo covers ≥ half, no low-level halo.
        let e = RidgeRaster(width: 2, height: 1, indices: [140, 0], palette: r.palette, lon0: 0, lat0: 0, dLon: 1, dLat: -1)
        #expect(e.sample(lon: 0.4, lat: 0) == 140)
        #expect(e.sample(lon: 0.6, lat: 0) == nil)
    }

    /// The default argument is `t: 1`, so this only checks that the explicit argument takes that path.
    /// Base output is pinned by `renderTileFullSmoothMatchesBaseDigest`.
    @Test func renderTileDefaultCallMatchesExplicitFullSmooth() throws {
        let r = try Self.raster()
        for (z, x, y) in [(10, 307, 383), (9, 153, 191), (8, 76, 95)] {
            #expect(r.renderTile(z: z, x: x, y: y, t: 1) == r.renderTile(z: z, x: x, y: y))
            #expect(r.sample(lon: r.lon0, lat: r.lat0, t: 1) == r.sample(lon: r.lon0, lat: r.lat0))
        }
    }

    /// A4b: full smooth matches the base render. Digests were taken at `00f7e028` (FNV-1a-64 over
    /// z6–z11, 9 tiles each) on a synthetic raster, so this runs without the palette PNG.
    @Test func renderTileFullSmoothMatchesBaseDigest() {
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng }
        let w = 120, h = 100
        var idx = [UInt8](repeating: 0, count: w * h)
        for i in 0..<idx.count {
            let roll = next() % 100
            idx[i] = roll < 45 ? 0 : UInt8(2 + next() % 200)
        }
        let raster = RidgeRaster(width: w, height: h, indices: idx,
                                 palette: (0..<256).map { (UInt8($0), UInt8(255 - $0), UInt8($0 / 2)) },
                                 lon0: -98.6, lat0: 36.0, dLon: 0.01, dLat: -0.01)
        let plain = Self.tileDigest(raster, explicit: false)
        let full = Self.tileDigest(raster, explicit: true)
        #expect(plain.hash == 0x7ecc24932c8e431e && plain.nonzero == 3_170_464)
        #expect(full.hash == 0x7ecc24932c8e431e && full.nonzero == 3_170_464)
    }

    /// FNV-1a-64 over the same tiles the base probe hashed. `explicit` passes `t: 1`; otherwise the default.
    private static func tileDigest(_ raster: RidgeRaster, explicit: Bool) -> (hash: UInt64, nonzero: Int) {
        var acc: UInt64 = 1469598103934665603
        var nonzero = 0
        for z in [6, 7, 8, 9, 10, 11] {
            let n = pow(2.0, Double(z))
            let x = Int((-98.0 + 180) / 360 * n)
            let latR = 35.5 * Double.pi / 180
            let y = Int((1 - log(tan(latR) + 1 / cos(latR)) / Double.pi) / 2 * n)
            for dx in -1...1 {
                for dy in -1...1 {
                    let px = explicit ? raster.renderTile(z: z, x: x + dx, y: y + dy, t: 1)
                                      : raster.renderTile(z: z, x: x + dx, y: y + dy)
                    for b in px {
                        acc = (acc ^ UInt64(b)) &* 1099511628211
                        if b != 0 { nonzero += 1 }
                    }
                }
            }
        }
        return (acc, nonzero)
    }

    static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int { Int(r) << 16 | Int(g) << 8 | Int(b) }
    static func usedColours(_ px: [UInt8]) -> Set<Int> {
        var out = Set<Int>()
        for p in stride(from: 0, to: px.count, by: 4) where px[p + 3] > 0 { out.insert(rgb(px[p], px[p + 1], px[p + 2])) }
        return out
    }

    static func edgeSteps(_ px: [UInt8]) -> Int {
        // Number of rows whose opaque/clear pattern differs from the row above: a staircase repeats rows.
        var steps = 0
        for y in 1..<256 {
            var differs = false
            for x in 0..<256 where (px[((y - 1) * 256 + x) * 4 + 3] > 0) != (px[(y * 256 + x) * 4 + 3] > 0) { differs = true; break }
            if differs { steps += 1 }
        }
        return steps
    }

#if canImport(CoreGraphics)
    @Test func smoothTileMatchesIEMCoverageButIsNotBlocky() throws {
        let r = try Self.raster()
        let smooth = r.renderTile(z: Self.tile.z, x: Self.tile.x, y: Self.tile.y)
        let png = try Self.fixture("OKX_N0B_tile_10_307_383", "png")
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let iem = RadarTilePacker.render(try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)))
        func count(_ p: [UInt8]) -> Int { var n = 0; for i in stride(from: 3, to: p.count, by: 4) where p[i] > 0 { n += 1 }; return n }
        // Same echo area within 2 % (IEM 45,381 px; smooth 45,406 in the Python prototype).
        #expect(abs(Double(count(smooth)) / Double(count(iem)) - 1) < 0.02)
        // IEM's squares: echo outlines only change at source-cell rows (19 of 255 rows here, one per
        // ~13 px). Smooth contours change on most rows (158).
        #expect(Self.edgeSteps(iem) < 30)
        #expect(Self.edgeSteps(smooth) > 5 * Self.edgeSteps(iem))
        // Every drawn pixel keeps its legend (palette) RGB. Alpha is 255 or a multiple of 32;
        // bins at or below 0 dBZ stay at least echoAlphaFloor in the interior.
        var unmatched = 0, badAlpha = 0
        for p in stride(from: 0, to: smooth.count, by: 4) {
            let a = Int(smooth[p + 3])
            guard a > 0 else { continue }
            if a != 255 && a % 32 != 0 { badAlpha += 1 }
            let ok = r.palette.indices.contains { i in
                !r.noEcho[i] && r.palette[i].0 == smooth[p] && r.palette[i].1 == smooth[p + 1] && r.palette[i].2 == smooth[p + 2]
            }
            if !ok { unmatched += 1 }
        }
        #expect(unmatched == 0 && badAlpha == 0)
        // And it still packs and compresses like a downloaded tile (≤ 256 colours, PNG ≪ RGBA).
        let img = try #require(RadarQC.image(rgba: smooth))
        let encoded = try #require(RadarQC.png(img))
        #expect(encoded.count < 256 * 256)
        #expect(RadarTilePacker.pack(img, encoded: encoded).heldBytes <= RadarMemoryBudget.packedTileBytes)
    }
#endif

    // CR #7.3: every core keeps its raw maximum. For each 16×16-cell block of the raster inside the tile,
    // the highest rendered level equals the highest raw level of the cells whose centres fall inside it.
    @Test func smoothingPreservesPeakReflectivityPerRegion() throws {
        let r = try Self.raster()
        for (z, x, y) in [(10, 307, 383), (9, 153, 191), (8, 76, 95)] {
            let px = r.renderTile(z: z, x: x, y: y)
            var inverse: [Int: UInt8] = [:]
            for (i, c) in r.palette.enumerated() where !r.noEcho[i] { inverse[Self.rgb(c.0, c.1, c.2)] = inverse[Self.rgb(c.0, c.1, c.2)] ?? UInt8(i) }
            let n = pow(2.0, Double(z))
            func pixel(lat: Double, lon: Double) -> (Int, Int)? {
                let fx = ((lon + 180) / 360 * n - Double(x)) * 256
                let fy = ((1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * n - Double(y)) * 256
                guard fx >= 0, fy >= 0, fx < 256, fy < 256 else { return nil }
                return (Int(fx), Int(fy))
            }
            var rawMax = 0, cells = 0
            for row in 0..<r.height { for col in 0..<r.width {
                guard let v = r.echo(row, col), pixel(lat: r.lat0 + Double(row) * r.dLat, lon: r.lon0 + Double(col) * r.dLon) != nil else { continue }
                rawMax = max(rawMax, Int(v)); cells += 1
            } }
            #expect(cells > 0)
            var drawnMax = 0
            for p in Swift.stride(from: 0, to: px.count, by: 4) where px[p + 3] > 0 {
                // Colour → level. RGB is the palette entry (not scaled by alpha). IEM repeats some colours.
                let lv = r.palette.indices.filter { i in
                    !r.noEcho[i] && r.palette[i].0 == px[p] && r.palette[i].1 == px[p + 1] && r.palette[i].2 == px[p + 2]
                }.max() ?? 0
                drawnMax = max(drawnMax, lv)
            }
            #expect(drawnMax >= rawMax, "z\(z): drawn max \(drawnMax) < raw max \(rawMax)")
            // Each peak cell's centre shows that peak's legend colour. Alpha is the bin ramp (255 at ≥ 18 dBZ).
            for row in 0..<r.height { for col in 0..<r.width {
                guard let v = r.echo(row, col), r.isPeak(row, col, v),
                      let (fx, fy) = pixel(lat: r.lat0 + Double(row) * r.dLat, lon: r.lon0 + Double(col) * r.dLon) else { continue }
                let p = (fy * 256 + fx) * 4, c = r.palette[Int(v)]
                let a = RidgeRaster.echoAlpha(level: Int(v), cover: 1)
                #expect(px[p + 3] == a)
                #expect(px[p] == c.0 && px[p + 1] == c.1 && px[p + 2] == c.2)
            } }
        }
    }

    /// Tile-pixel centre → (lat, lon).
    static func pixelLatLon(z: Int, x: Int, y: Int, px: Int, py: Int) -> (Double, Double) {
        let n = pow(2.0, Double(z))
        let lon = (Double(x) + (Double(px) + 0.5) / 256) / n * 360 - 180
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + (Double(py) + 0.5) / 256) / n))) * 180 / .pi
        return (lat, lon)
    }

    /// Longest horizontal run of "drawn here, nothing directly below" in an RGBA image (w × h).
    static func longestFlatEdge(_ px: [UInt8], width w: Int, rows: Range<Int>) -> Int {
        var best = 0
        for y in rows where y + 1 < px.count / (w * 4) {
            var run = 0
            for x in 0..<w {
                if px[(y * w + x) * 4 + 3] > 0, px[((y + 1) * w + x) * 4 + 3] == 0 { run += 1; best = max(best, run) } else { run = 0 }
            }
        }
        return best
    }

    // CR #7.2 (final), the ~41.01°N "cut" 16 km north of KOKX. Evidence, all strict:
    // 1. The raw IEM grid has echo on both sides of 41.01°N (rows 486/487) and no straight edge there.
    // 2. Our render never clips: wherever all four cells around a pixel have echo it is drawn, wherever
    //    none do it is clear. Zero exceptions, across the 40.98°N tile edge (the nearest tile boundary at
    //    every zoom) at z9 and z10.
    // 3. Coverage tracks IEM's own tile row by row (per IEM pixel band, ≤ max(8, 1/12)).
#if canImport(CoreGraphics)
    @Test func noSeamAt41N() throws {
        let r = try Self.raster()
        let seamRow = (41.01 - r.lat0) / r.dLat
        #expect(Int(seamRow) == 486)
        let north = (0..<r.width).filter { r.echo(486, $0) != nil }.count
        let south = (0..<r.width).filter { r.echo(487, $0) != nil }.count
        #expect(north > 50 && south > 50 && abs(north - south) <= 10, "raw rows 486/487: \(north) / \(south)")
        // Source: no straight east–west echo edge longer than 10 cells (≈ 9 km) anywhere in rows 476–497.
        var longest = 0
        for row in 476...497 {
            var run = 0
            for c in 0..<r.width {
                if r.echo(row, c) != nil, r.echo(row + 1, c) == nil { run += 1; longest = max(longest, run) } else { run = 0 }
            }
        }
        #expect(longest <= 10, "raw straight edge \(longest) cells")

        // Render: the strict support rule on a 2-tile-tall strip straddling the 40.98°N tile boundary.
        for (z, xs, y0) in [(10, [305, 306, 307], 383), (9, [152, 153], 191)] {
            for x in xs {
                let strip = r.renderTile(z: z, x: x, y: y0) + r.renderTile(z: z, x: x, y: y0 + 1)
                var violations = 0
                for py in 0..<512 { for px in 0..<256 {
                    let (lat, lon) = Self.pixelLatLon(z: z, x: x, y: y0, px: px, py: py)
                    let fc = (lon - r.lon0) / r.dLon, fr = (lat - r.lat0) / r.dLat
                    let c0 = Int(fc.rounded(.down)), r0 = Int(fr.rounded(.down))
                    let cells = [r.echo(r0, c0), r.echo(r0, c0 + 1), r.echo(r0 + 1, c0), r.echo(r0 + 1, c0 + 1)]
                    let drawn = strip[(py * 256 + px) * 4 + 3] > 0
                    if cells.allSatisfy({ $0 != nil }) && !drawn { violations += 1 }
                    if cells.allSatisfy({ $0 == nil }) && drawn { violations += 1 }
                } }
                #expect(violations == 0, "z\(z) x\(x): \(violations) clipped/extra pixels")
                // No flat edge in our output at the seam latitudes beyond what the source has (≤ 10 cells).
                let cellPx = Int((256 * pow(2.0, Double(z)) / 360 * r.dLon).rounded(.up))
                #expect(Self.longestFlatEdge(strip, width: 256, rows: 0..<511) <= 10 * cellPx)
            }
        }

        // IEM's own tile for the same scan: identical coverage per pixel band (each IEM band is one raster
        // row, so compare band means; the per-pixel-row difference is the contour inside a band).
        let smooth = r.renderTile(z: 10, x: 307, y: 383)
        let png = try Self.fixture("OKX_N0B_tile_10_307_383", "png")
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let iem = RadarTilePacker.render(try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)))
        func row(_ p: [UInt8], _ y: Int) -> Int { (0..<256).filter { p[(y * 256 + $0) * 4 + 3] > 0 }.count }
        var y = 0
        while y < 256 {
            var e = y + 1
            while e < 256, (0..<256).allSatisfy({ iem[(e * 256 + $0) * 4 + 3] == iem[((e - 1) * 256 + $0) * 4 + 3] }) { e += 1 }
            let a = (y..<e).map { row(iem, $0) }.reduce(0, +) / (e - y)
            let b = (y..<e).map { row(smooth, $0) }.reduce(0, +) / (e - y)
            #expect(abs(a - b) <= max(8, a / 12), "IEM band \(y)..<\(e): IEM \(a) vs smooth \(b)")
            y = e
        }
    }
#endif

    @Test func tilesOutsideTheRasterAreEmpty() throws {
        let r = try Self.raster()
        #expect(r.renderTile(z: 10, x: 100, y: 383).allSatisfy { $0 == 0 })
    }

    @Test func siteFramesCarryTheRasterAndQC() {
        let t = ISO8601DateFormatter().date(from: "2026-10-16T17:48:00Z")!
        let frames = IEMRidge.frames(site: "OKX", scans: [t], range: .oneHour)
        let base = "https://mesonet.agron.iastate.edu/archive/data/2026/10/16/GIS/ridge/OKX/N0B/OKX_N0B_202610161748"
        #expect(frames.first?.urlTemplate.hasSuffix("#raw=" + base) == true)
        let masked = RadarQC.masked(frames, latestMask: t)
        let url = masked[0].url(z: 10, x: 307, y: 383)!
        let parts = RadarQC.split(url)
        #expect(parts.image.absoluteString == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::OKX-N0B-202610161748/10/307/383.png")
        #expect(parts.raster == base)
        #expect(parts.maskTemplate == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610161748/{z}/{x}/{y}.png")
        #expect(parts.tile == .init(z: 10, x: 307, y: 383))
        #expect(RadarQC.masked(masked, latestMask: t) == masked)
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
    final class Flag: @unchecked Sendable { var down = true; var calls = 0 }

    // CR #7.4: failures are negative-cached with back-off (no storm), then retried.
    @Test func rasterStoreBacksOffFailuresThenRetries() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        let clock = Clock(), flag = Flag()
        let store = RidgeRasterStore(clock: { clock.now }) { url in
            flag.calls += 1
            return flag.down ? nil : (url.pathExtension == "png" ? png : wld)
        }
        let base = "https://mesonet.agron.iastate.edu/x/OKX_N0B_1"
        #expect(await store.raster(base: base) == nil)
        let calls = flag.calls
        for _ in 0..<50 { #expect(await store.raster(base: base) == nil) } // 50 tiles of the frame
        #expect(flag.calls == calls) // no new requests inside the back-off
        #expect(await store.isBackingOff(base))
        flag.down = false
        clock.now += RidgeRasterStore.backoff(attempts: 1) + 1
        #expect(await store.raster(base: base) != nil)
        #expect(await store.isBackingOff(base) == false)
        #expect(RidgeRasterStore.backoff(attempts: 1) == 10 && RidgeRasterStore.backoff(attempts: 9) == 300)
    }

    // CR #7.5: LRU, and memory pressure trims to the newest scans until restored.
    @Test func rasterStoreIsLRUAndTrimsUnderPressure() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        let store = RidgeRasterStore(limit: 3) { url in url.pathExtension == "png" ? png : wld }
        for k in 1...3 { _ = await store.raster(base: "https://a/\(k)") }
        _ = await store.raster(base: "https://a/1") // touch 1: 2 is now least recent
        _ = await store.raster(base: "https://a/4")
        #expect(await store.fetches == 4)
        _ = await store.raster(base: "https://a/1")
        #expect(await store.fetches == 4) // 1 kept (LRU, not FIFO)
        await store.trim(keep: 1)
        #expect(await store.count == 1)
        _ = await store.raster(base: "https://a/3"); _ = await store.raster(base: "https://a/4")
        #expect(await store.count == 1)
        await store.restore()
        _ = await store.raster(base: "https://a/1")
        #expect(await store.count == 2)
    }

    // Memory: closing the window purges every scan; the cap is unchanged and the next radar re-fetches.
    @Test func rasterStorePurgeDropsEverythingAndKeepsTheCap() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        let store = RidgeRasterStore(limit: 3) { url in url.pathExtension == "png" ? png : wld }
        for k in 1...3 { _ = await store.raster(base: "https://a/\(k)") }
        #expect(await store.count == 3)
        await store.purge()
        #expect(await store.count == 0)
        #expect(await store.raster(base: "https://a/1") != nil)
        #expect(await store.fetches == 4) // re-fetched after the purge
        for k in 2...5 { _ = await store.raster(base: "https://a/\(k)") }
        #expect(await store.count == 3) // same cap as before
    }

    // CR #7.5: decodes run concurrently, off the actor (two slow fetches overlap).
    @Test func decodesRunConcurrently() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        final class Gauge: @unchecked Sendable { let lock = NSLock(); var now = 0, peak = 0
            func enter() { lock.lock(); now += 1; peak = max(peak, now); lock.unlock() }
            func leave() { lock.lock(); now -= 1; lock.unlock() } }
        let g = Gauge()
        let store = RidgeRasterStore { url in
            g.enter(); try? await Task.sleep(for: .milliseconds(150)); g.leave()
            return url.pathExtension == "png" ? png : wld
        }
        async let a = store.raster(base: "https://a/1")
        async let b = store.raster(base: "https://a/2")
        let (ra, rb) = await (a, b)
        #expect(ra != nil && rb != nil)
        #expect(g.peak >= 3) // both scans' png + wld in flight together
    }

    @Test func rasterStoreCachesPerScanAndRetriesFailures() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        final class Flag: @unchecked Sendable { var down = true }
        final class TestClock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let flag = Flag(), clock = TestClock()
        let store = RidgeRasterStore(clock: { clock.now }) { url in
            if flag.down { return nil }
            return url.pathExtension == "png" ? png : wld
        }
        #expect(await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1") == nil)
        flag.down = false
        clock.now += RidgeRasterStore.backoff(attempts: 1) + 1 // past the negative-cache window
        #expect(await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1") != nil)
        _ = await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1")
        #expect(await store.fetches == 2) // one failed + one good; the third came from cache
        let small = RidgeRasterStore(limit: 1) { url in url.pathExtension == "png" ? png : wld }
        _ = await small.raster(base: "https://a/1"); _ = await small.raster(base: "https://a/2"); _ = await small.raster(base: "https://a/1")
        #expect(await small.fetches == 3) // evicted at the limit (memory bound)
    }

    // CR #7 (final), item 4: the newest scan shows IEM's tile at once and swaps to smooth in place.
    @Test func newestFrameShowsBlockyThenSwapsToSmoothInPlace() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let scans = (0..<6).map { t0.addingTimeInterval(Double($0) * 300) }
        let smooth = IEMRidge.frames(site: "OKX", scans: scans, range: .oneHour)
        let pending = IEMRidge.newestBlocky(smooth, site: "OKX")
        #expect(pending.count == smooth.count)
        #expect(pending.dropLast().allSatisfy { $0.urlTemplate.contains("#raw=") }) // older frames stay smooth
        #expect(!pending.last!.urlTemplate.contains("#raw=") && pending.last!.urlTemplate.contains("ridge::OKX-N0B-"))
        #expect(IEMRidge.isPendingSmooth(pending))
        #expect(!IEMRidge.isPendingSmooth(smooth))
        #expect(!IEMRidge.isPendingSmooth(IEMRidge.frames(site: "OKX", scans: scans, range: .oneHour, smooth: false)))
        // Raster archived: only the newest changes, so it's an in-place swap (no loop reload).
        #expect(IEMRidge.isNewestUpgrade(from: pending, to: smooth))
        #expect(!IEMRidge.isNewestUpgrade(from: smooth, to: pending))
        // A new scan arriving is a normal reload, not an upgrade.
        let later = IEMRidge.frames(site: "OKX", scans: scans + [t0.addingTimeInterval(1800)], range: .oneHour)
        #expect(!IEMRidge.isNewestUpgrade(from: pending, to: later))
    }
}
