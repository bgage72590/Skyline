import CoreGraphics
import Foundation
import ImageIO
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
        // Colours stay IEM palette colours (legend still valid).
        let paletteRGB = Set(r.palette.map { Self.rgb($0.0, $0.1, $0.2) })
        #expect(Self.usedColours(smooth).isSubset(of: paletteRGB))
        // And it still packs and compresses like a downloaded tile (≤ 256 colours, PNG ≪ RGBA).
        let img = try #require(RadarQC.image(rgba: smooth))
        let encoded = try #require(RadarQC.png(img))
        #expect(encoded.count < 256 * 256)
        #expect(RadarTilePacker.pack(img, encoded: encoded).heldBytes <= RadarMemoryBudget.packedTileBytes)
    }

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
                // Colour → level; IEM repeats some colours, so take the highest level with that colour.
                let key = Self.rgb(px[p], px[p + 1], px[p + 2])
                let lv = r.palette.indices.filter { !r.noEcho[$0] && Self.rgb(r.palette[$0].0, r.palette[$0].1, r.palette[$0].2) == key }.max() ?? 0
                drawnMax = max(drawnMax, lv)
            }
            #expect(drawnMax >= rawMax, "z\(z): drawn max \(drawnMax) < raw max \(rawMax)")
            // And per local maximum: each peak cell's centre pixel shows the peak's own colour.
            for row in 0..<r.height { for col in 0..<r.width {
                guard let v = r.echo(row, col), r.isPeak(row, col, v),
                      let (fx, fy) = pixel(lat: r.lat0 + Double(row) * r.dLat, lon: r.lon0 + Double(col) * r.dLon) else { continue }
                let p = (fy * 256 + fx) * 4, c = r.palette[Int(v)]
                #expect(px[p + 3] == 255 && px[p] == c.0 && px[p + 1] == c.1 && px[p + 2] == c.2)
            } }
        }
    }

    // CR #7.2: the "horizontal cut" is in the source. The raster's echo ends on a straight row
    // (row 486 has echo across the tile, row 487 mostly none), and IEM's own tile ends on the same line.
    // Smooth coverage tracks IEM's row by row, so no seam is introduced (no row differs by more than ~1/6, the contour-vs-block difference at cell edges).
    @Test func noSeamRowCoverageTracksIEM() throws {
        let r = try Self.raster()
        let smooth = r.renderTile(z: 10, x: 307, y: 383)
        let png = try Self.fixture("OKX_N0B_tile_10_307_383", "png")
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let iem = RadarTilePacker.render(try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)))
        func row(_ p: [UInt8], _ y: Int) -> Int { (0..<256).filter { p[(y * 256 + $0) * 4 + 3] > 0 }.count }
        for y in 0..<256 {
            let a = row(iem, y), b = row(smooth, y)
            #expect(abs(a - b) <= max(8, a / 6), "row \(y): IEM \(a) vs smooth \(b)")
        }
        // And smoothing adds no horizontal cut of its own: every row-to-row coverage jump in the smooth
        // tile is matched by a jump in IEM's tile at the same row (the straight edge lives in the source).
        for y in 1..<256 {
            let di = abs(row(iem, y) - row(iem, y - 1)), ds = abs(row(smooth, y) - row(smooth, y - 1))
            #expect(ds <= di + 24, "row \(y): smooth jumps \(ds) where IEM jumps \(di)")
        }
    }

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
}
