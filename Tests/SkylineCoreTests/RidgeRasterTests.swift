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
        #expect(r.indices.max() == 159)
        #expect(RidgeRaster.parseWorldFile("1 0 0 -1 0") == nil)
        #expect(PalettePNG.decode(Data([1, 2, 3])) == nil)
    }

    @Test func sampleInterpolatesBeforeColouring() {
        // 2×1 raster: levels 100 and 140 at cell centres lon 0 and 1.
        let r = RidgeRaster(width: 2, height: 1, indices: [100, 140], palette: (0..<256).map { (UInt8($0), 0, 0) },
                            lon0: 0, lat0: 0, dLon: 1, dLat: -1)
        #expect(r.sample(lon: 0.5, lat: 0) == 120)
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

    @Test func rasterStoreCachesPerScanAndRetriesFailures() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png"), wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        final class Flag: @unchecked Sendable { var down = true }
        let flag = Flag()
        let store = RidgeRasterStore { url in
            if flag.down { return nil }
            return url.pathExtension == "png" ? png : wld
        }
        #expect(await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1") == nil)
        flag.down = false
        #expect(await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1") != nil)
        _ = await store.raster(base: "https://mesonet.agron.iastate.edu/x/OKX_N0B_1")
        #expect(await store.fetches == 2) // one failed + one good; the third came from cache
        let small = RidgeRasterStore(limit: 1) { url in url.pathExtension == "png" ? png : wld }
        _ = await small.raster(base: "https://a/1"); _ = await small.raster(base: "https://a/2"); _ = await small.raster(base: "https://a/1")
        #expect(await small.fetches == 3) // evicted at the limit (memory bound)
    }
}
