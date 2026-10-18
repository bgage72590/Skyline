import Foundation
import Testing
@testable import SkylineCore

/// Light rain stays a soft wash: low dBZ fades, cores stay solid, and the QC mask feathers instead of
/// cutting the field into mask-pixel squares.
struct RadarSoftEchoTests {
    @Test func alphaRampsWithReflectivityAndCoverage() {
        // Index 80 ≈ 7.5 dBZ (light rain): translucent, and a multiple of 32.
        let light = RidgeRaster.echoAlpha(level: 80, cover: 1)
        #expect(light < 200 && light >= 32 && light % 32 == 0)
        // Index 16 ≈ −24.5 dBZ, the faint edge of the fixture: still drawn, still soft.
        let faint = RidgeRaster.echoAlpha(level: 16, cover: 1)
        #expect(faint == 32)
        // The ≥ ½ contour is feathered but never dropped, so the alpha>0 footprint is unchanged.
        #expect(RidgeRaster.echoAlpha(level: 16, cover: 0.5) >= 32)
        #expect(RidgeRaster.echoAlpha(level: 80, cover: 0.5) < light)
        // 18 dBZ is index 101 (−32 + 0.5×100). Cores there and above are opaque.
        #expect(RidgeRaster.echoAlpha(level: 101, cover: 1) == 255)
        #expect(RidgeRaster.echoAlpha(level: 140, cover: 1) == 255)
        // A heavy core's edge still feathers.
        #expect(RidgeRaster.echoAlpha(level: 140, cover: 0.5) < 255)
        #expect(RidgeRaster.echoAlpha(level: 0, cover: 1) == 0)
    }

    @Test func renderTileFadesLightEchoAndKeepsCoresSolid() {
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
        let light = raster(80).renderTile(z: z, x: x, y: y)
        let a = Int(RidgeRaster.echoAlpha(level: 80, cover: 1))
        #expect(light[p + 3] == a && a < 255)
        #expect(light[p] == UInt8(80 * a / 255) && light[p + 1] == UInt8(10 * a / 255) && light[p + 2] == UInt8(20 * a / 255))
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
