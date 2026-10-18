#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import SkylineCore

/// Light drizzle stays readable in the legend colour. Edges and the QC mask still feather; the bin
/// itself does not fade to a wash.
struct RadarSoftEchoTests {
    /// N0B index for a dBZ value. Index 1 is −32 dBZ; each step is +0.5 dBZ.
    static func level(dbz: Double) -> Int { 1 + Int((dbz + 32) * 2) }

    @Test func weakestBinIsVisibleAndMatchesTheLegendColor() {
        // ≤ 0 dBZ is at least ~60% of an opaque core (160/255), not the old 32/255 wash.
        #expect(RidgeRaster.echoAlphaFloor >= 153) // 153/255 = 60%
        #expect(Double(RidgeRaster.echoAlphaFloor) / 255 >= 0.60)
        let weakest = RidgeRaster.echoAlpha(level: 2, cover: 1) // −31.5 dBZ, first echo index
        let atZero = RidgeRaster.echoAlpha(level: Self.level(dbz: 0), cover: 1)
        #expect(weakest >= RidgeRaster.echoAlphaFloor && weakest == atZero)
        #expect(weakest % 32 == 0)
        // Ramp reaches opaque by 18 dBZ. 5/10/15 dBZ (legend stops) sit on that ramp and stay above the floor.
        let a5 = RidgeRaster.echoAlpha(level: Self.level(dbz: 5), cover: 1)
        let a10 = RidgeRaster.echoAlpha(level: Self.level(dbz: 10), cover: 1)
        let a15 = RidgeRaster.echoAlpha(level: Self.level(dbz: 15), cover: 1)
        #expect(a5 > RidgeRaster.echoAlphaFloor && a10 > a5 && a15 >= a10)
        #expect(RidgeRaster.echoAlpha(level: Self.level(dbz: 18), cover: 1) == 255)
        #expect(RidgeRaster.echoAlpha(level: 140, cover: 1) == 255)
        // The contour still feathers (edge anti-alias) and is never dropped.
        #expect(RidgeRaster.echoAlpha(level: 2, cover: 0.5) < weakest)
        #expect(RidgeRaster.echoAlpha(level: 2, cover: 0.5) >= 32)
        #expect(RidgeRaster.echoAlpha(level: 140, cover: 0.5) < 255)
        #expect(RidgeRaster.echoAlpha(level: 0, cover: 1) == 0)

        // A painted bin uses the palette RGB exactly (the legend colour), not RGB scaled by alpha.
        let z = 4, x = 4, y = 6
        let n = pow(2.0, Double(z))
        let lon = (Double(x) + 128.5 / 256) / n * 360 - 180
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + 128.5 / 256) / n))) * 180 / .pi
        func raster(_ level: UInt8) -> RidgeRaster {
            RidgeRaster(width: 1, height: 1, indices: [level],
                        palette: (0..<256).map { (UInt8($0), 10, 20) },
                        lon0: lon, lat0: lat, dLon: 1, dLat: -1)
        }
        let p = (128 * 256 + 128) * 4
        let drizzle = raster(2).renderTile(z: z, x: x, y: y)
        #expect(drizzle[p] == 2 && drizzle[p + 1] == 10 && drizzle[p + 2] == 20)
        #expect(drizzle[p + 3] == weakest)
        let light = raster(80).renderTile(z: z, x: x, y: y) // ~7.5 dBZ
        #expect(light[p] == 80 && light[p + 1] == 10 && light[p + 2] == 20)
        #expect(light[p + 3] == RidgeRaster.echoAlpha(level: 80, cover: 1))
        #expect(light[p + 3] > weakest && light[p + 3] < 255)
        let core = raster(140).renderTile(z: z, x: x, y: y)
        #expect(core[p + 3] == 255 && core[p] == 140 && core[p + 1] == 10 && core[p + 2] == 20)
    }

    @Test func maskFeatherIsBetweenTheOldCliffAndAHardEdge() {
        var mask = [UInt8](repeating: 0, count: 256 * 256)
        for y in 192..<256 { for x in 192..<200 { mask[y * 256 + x] = 1 } }
        let on = RadarQCMask.coverage(mask: mask, scale: 4, offsetX: 192, offsetY: 192, x: 16, y: 10)
        let edgeIn = RadarQCMask.coverage(mask: mask, scale: 4, offsetX: 192, offsetY: 192, x: 31, y: 10)
        let edgeOut = RadarQCMask.coverage(mask: mask, scale: 4, offsetX: 192, offsetY: 192, x: 32, y: 10)
        let off = RadarQCMask.coverage(mask: mask, scale: 4, offsetX: 192, offsetY: 192, x: 80, y: 10)
        #expect(on == 1 && off == 0)
        #expect(edgeIn > 0.5 && edgeIn < 1)
        #expect(edgeOut > 0 && edgeOut < 0.5 && edgeOut < edgeIn)
        // Scale 1 lands on pixel centres: still exact.
        var row = [UInt8](repeating: 0, count: 256 * 256)
        for y in 0..<256 { for x in 0..<64 { row[y * 256 + x] = 1 } }
        #expect(RadarQCMask.coverage(mask: row, scale: 1, offsetX: 0, offsetY: 0, x: 63, y: 5) == 1)
        #expect(RadarQCMask.coverage(mask: row, scale: 1, offsetX: 0, offsetY: 0, x: 64, y: 5) == 0)
        // Past the mask origin, a fully-on mask stays fully on (edge repeat, no border seam).
        let full = [UInt8](repeating: 1, count: 256 * 256)
        #expect(RadarQCMask.coverage(mask: full, scale: 4, offsetX: 0, offsetY: 0, x: 0, y: 0) == 1)
        #expect(RadarQCMask.coverage(mask: full, scale: 4, offsetX: 0, offsetY: 0, x: 255, y: 255) == 1)
    }

    /// Nearest-site tiles are straight legend RGB. The QC mask must scale alpha only, so a pixel half
    /// inside the mask keeps its colour. Fully outside the mask is transparent.
    @Test func straightAlphaMaskKeepsLegendRGBOnAPartialEdge() throws {
        let z = 8, x = 75, y = 95
        let n = pow(2.0, Double(z))
        let lon = (Double(x) + 128.5 / 256) / n * 360 - 180
        let lat = atan(sinh(Double.pi * (1 - 2 * (Double(y) + 128.5 / 256) / n))) * 180 / .pi
        let level: UInt8 = 2 // weakest bin, alpha well below opaque
        let legend: (UInt8, UInt8, UInt8) = (180, 64, 220)
        var palette = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: 256)
        palette[Int(level)] = legend
        // One cell much larger than the tile, centred on it, so every pixel is that bin at full cover.
        let raster = RidgeRaster(width: 1, height: 1, indices: [level], palette: palette,
                                 lon0: lon, lat0: lat, dLon: 40, dLat: -40)
        var px = raster.renderTile(z: z, x: x, y: y)
        let bin = Int(RidgeRaster.echoAlpha(level: Int(level), cover: 1))
        func rgba(_ buf: [UInt8], _ px: Int, _ py: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (py * 256 + px) * 4
            return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
        }
        #expect(rgba(px, 16, 10) == (legend.0, legend.1, legend.2, UInt8(bin)))
        #expect(rgba(px, 31, 10).3 == UInt8(bin) && rgba(px, 80, 10).3 == UInt8(bin))

        var mask = [UInt8](repeating: 0, count: 256 * 256)
        for row in 192..<256 { for col in 192..<200 { mask[row * 256 + col] = 1 } }
        RadarQCMask.apply(rgba: &px, tile: .init(z: z, x: x, y: y), mask: mask, straightAlpha: true)

        let inside = rgba(px, 16, 10)
        #expect(inside == (legend.0, legend.1, legend.2, UInt8(bin)))

        let w = RadarQCMask.coverage(mask: mask, scale: 4, offsetX: 192, offsetY: 192, x: 31, y: 10)
        let edge = rgba(px, 31, 10)
        #expect(edge.0 == legend.0 && edge.1 == legend.1 && edge.2 == legend.2)
        let raw = Int((Double(bin) * w).rounded())
        let quantized = min(bin, max(32, Int((Double(raw) / 32).rounded()) * 32))
        #expect(Int(edge.3) == quantized)
        #expect(abs(Double(edge.3) - Double(bin) * w) <= 16)

        #expect(rgba(px, 80, 10) == (0, 0, 0, 0))
        #expect(rgba(px, 255, 255) == (0, 0, 0, 0))

#if canImport(CoreGraphics)
        // image() is the one premultiply. Read those bytes; drawing the image again is a second composite.
        let img = try #require(RadarQC.image(rgba: px))
        let stored = try #require(img.dataProvider.flatMap(CGDataProviderCopyData)) as Data
        func unpremul(_ px: Int, _ py: Int) -> (Int, Int, Int, Int) {
            let i = (py * 256 + px) * 4
            let a = Int(stored[i + 3])
            guard a > 0 else { return (0, 0, 0, 0) }
            func u(_ c: UInt8) -> Int { (Int(c) * 255 + a / 2) / a }
            return (u(stored[i]), u(stored[i + 1]), u(stored[i + 2]), a)
        }
        let i = (10 * 256 + 31) * 4
        let a = Int(stored[i + 3])
        #expect(a == quantized)
        // Exactly one multiply of the legend colour. A second darken would not match this.
        #expect(Int(stored[i]) == Int(legend.0) * a / 255)
        #expect(Int(stored[i + 1]) == Int(legend.1) * a / 255)
        #expect(Int(stored[i + 2]) == Int(legend.2) * a / 255)
        let back = unpremul(31, 10)
        // 8-bit premultiply does not invert exactly (180×96/255 is 67, and 67×255/96 is 178).
        #expect(abs(back.0 - Int(legend.0)) <= 2)
        #expect(abs(back.1 - Int(legend.1)) <= 2)
        #expect(abs(back.2 - Int(legend.2)) <= 2)
        #expect(unpremul(80, 10) == (0, 0, 0, 0))
#endif
    }
}
