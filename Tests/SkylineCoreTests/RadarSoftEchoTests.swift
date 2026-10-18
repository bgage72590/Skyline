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
}
