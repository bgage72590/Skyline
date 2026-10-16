import CoreGraphics
import Foundation
import Testing
@testable import SkylineCore

/// Item 3: false green over Fairfield on a clear night. Raw N0Q/N0B echoes are masked by MRMS QC'd lcref.
struct RadarQCTests {
    static func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func decodesLatestMaskTime() throws {
        let json = #"{"meta": {"start_valid": "2026-10-16T17:22:00Z", "end_valid": "2026-10-16T17:22:00Z", "product": "lcref", "units": "0.5 dBZ"}}"#
        #expect(try RadarQC.latestValid(Data(json.utf8)) == Self.utc("2026-10-16T17:22:00Z"))
        // The N0Q index JSON (no end_valid) is not a mask index.
        #expect(throws: (any Error).self) { try RadarQC.latestValid(Data(#"{"meta":{"valid":"2026-10-16T17:30:00Z"}}"#.utf8)) }
    }

    @Test func maskTimeSnapsToTwoMinuteSlotsAndCapsAtLatest() {
        let latest = Self.utc("2026-10-16T17:22:00Z")
        #expect(RadarQC.maskTime(for: Self.utc("2026-10-16T01:35:00Z"), latestMask: latest) == Self.utc("2026-10-16T01:34:00Z"))
        #expect(RadarQC.maskTime(for: Self.utc("2026-10-16T17:20:00Z"), latestMask: latest) == Self.utc("2026-10-16T17:20:00Z"))
        // Newer than the newest mask: reuse it within 15 minutes, otherwise leave the frame unmasked.
        #expect(RadarQC.maskTime(for: Self.utc("2026-10-16T17:30:00Z"), latestMask: latest) == latest)
        #expect(RadarQC.maskTime(for: Self.utc("2026-10-16T17:40:00Z"), latestMask: latest) == nil)
    }

    @Test func masksObservedNexradFramesOnly() {
        let latest = Self.utc("2026-10-16T17:22:00Z")
        let comp = IEMNexrad.frames(latest: Self.utc("2026-10-16T17:20:00Z"))
        let site = IEMRidge.frames(site: "OKX", scans: [Self.utc("2026-10-16T17:19:00Z")], range: .oneHour)
        let forecast = RadarFrame(time: latest, urlTemplate: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::REFP-F0015-0/{z}/{x}/{y}.png", isForecast: true)
        let out = RadarQC.masked(comp + site + [forecast], latestMask: latest)
        #expect(out.last == forecast)
        let okx = out[out.count - 2]
        #expect(okx.urlTemplate.hasSuffix("#qc=https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610161718/{z}/{x}/{y}.png"))
        #expect(out.dropLast().allSatisfy { $0.urlTemplate.contains("#qc=") })
        // Idempotent.
        #expect(RadarQC.masked(out, latestMask: latest) == out)
        // Both halves get the tile coordinates; the fragment never reaches the server.
        let url = okx.url(z: 8, x: 75, y: 95)!
        let (image, mask) = RadarQC.split(url)
        #expect(image.absoluteString == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::OKX-N0B-202610161719/8/75/95.png")
        #expect(mask?.absoluteString == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610161718/8/75/95.png")
        #expect(RadarQC.split(image).mask == nil)
    }

    @Test func clearsPixelsWithoutNearbyMaskEcho() {
        let w = 10, h = 1
        var rgba = [UInt8](repeating: 200, count: w * h * 4)
        var mask = [UInt8](repeating: 0, count: w * h)
        mask[2] = 255
        RadarQC.apply(rgba: &rgba, width: w, height: h, maskAlpha: mask, dilation: 1)
        let alive = (0..<w).map { rgba[$0 * 4 + 3] > 0 }
        #expect(alive == [false, true, true, true, false, false, false, false, false, false])
        // An empty mask (clear sky, IEM's blank 334-byte tile) removes everything: the Fairfield case.
        var all = [UInt8](repeating: 200, count: w * h * 4)
        RadarQC.apply(rgba: &all, width: w, height: h, maskAlpha: [UInt8](repeating: 0, count: w * h))
        #expect(all.allSatisfy { $0 == 0 })
        // Wrong sizes: untouched.
        var same = [UInt8](repeating: 9, count: 8)
        RadarQC.apply(rgba: &same, width: 2, height: 1, maskAlpha: [0])
        #expect(same == [UInt8](repeating: 9, count: 8))
    }

    @Test func dilationIsSquare() {
        var on = [Bool](repeating: false, count: 25); on[12] = true
        let d = RadarQC.dilate(on, width: 5, height: 5, radius: 1)
        #expect(d.filter { $0 }.count == 9)
        #expect(d[6] && d[18] && !d[0] && !d[24])
    }

    static func image(_ w: Int, _ h: Int, _ px: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](); for y in 0..<h { for x in 0..<w { let p = px(x, y); bytes += [p.0, p.1, p.2, p.3] } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func masksImageAndKeepsColours() {
        // N0Q 20 dBZ green everywhere (biological returns + a real cell); MRMS has echo only on the left.
        let green: (UInt8, UInt8, UInt8, UInt8) = (67, 214, 126, 255)
        let tile = Self.image(32, 32) { _, _ in green }
        let mask = Self.image(32, 32) { x, _ in x < 8 ? (45, 90, 179, 255) : (0, 0, 0, 0) }
        let out = RadarQC.masked(tile, mask: mask)!
        let px = RadarTilePacker.render(out, space: CGColorSpace(name: CGColorSpace.sRGB))
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * 32 + x) * 4..<(y * 32 + x) * 4 + 4]) }
        #expect(at(0, 5) == [67, 214, 126, 255])
        #expect(at(8 + RadarQC.dilation - 1, 5) == [67, 214, 126, 255])
        #expect(at(8 + RadarQC.dilation, 5) == [0, 0, 0, 0])
        #expect(at(31, 31) == [0, 0, 0, 0])
        #expect(RadarQC.masked(tile, mask: Self.image(16, 16) { _, _ in green }) == nil)
    }
}
