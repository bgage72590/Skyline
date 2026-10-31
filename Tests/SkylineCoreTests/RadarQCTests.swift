#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
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
        #expect(okx.urlTemplate.hasSuffix("&qc=https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610161718/{z}/{x}/{y}.png"))
        #expect(out.dropLast().allSatisfy { $0.urlTemplate.contains("qc=https") })
        // Idempotent.
        #expect(RadarQC.masked(out, latestMask: latest) == out)
        // The image half goes to the server without the fragment; the mask comes back as a template.
        let url = okx.url(z: 8, x: 75, y: 95)!
        let (image, mask, tile, _) = RadarQC.split(url)
        #expect(image.absoluteString == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/ridge::OKX-N0B-202610161719/8/75/95.png")
        #expect(mask == "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610161718/{z}/{x}/{y}.png")
        #expect(tile == .init(z: 8, x: 75, y: 95))
        #expect(RadarQC.split(image).maskTemplate == nil)
    }

    typealias T = RadarQCMask.TileID

    // CR #6.1: the margin is ≥ 9 km on the ground at every display zoom.
    @Test func marginIsInKilometresAtEveryZoom() {
        for z in 3...14 {
            let display = T(z: z, x: Int(Double(1 << z) * 0.2965), y: Int(Double(1 << z) * 0.3714)) // ~Fairfield
            let m = RadarQCMask.maskTile(for: display).tile
            #expect(m.z == min(z, 6))
            let r = RadarQCMask.radiusPixels(maskZoom: m.z, tileY: m.y)
            let ground = Double(r) * RadarQCMask.metersPerPixel(zoom: m.z, tileY: m.y)
            #expect(ground >= 9_000 && ground < 9_000 + RadarQCMask.metersPerPixel(zoom: m.z, tileY: m.y) + 1)
        }
        #expect(RadarQCMask.radiusPixels(maskZoom: 6, tileY: 23) == 6) // 1.79 km/px at the tile centre, ~43°N
    }

    @Test func displayTilesMapIntoTheMaskTile() {
        let m = RadarQCMask.maskTile(for: T(z: 8, x: 75, y: 95))
        #expect(m.tile == T(z: 6, x: 18, y: 23) && m.scale == 4 && m.offsetX == 192 && m.offsetY == 192)
        let low = RadarQCMask.maskTile(for: T(z: 4, x: 4, y: 5))
        #expect(low.tile == T(z: 4, x: 4, y: 5) && low.scale == 1 && low.offsetX == 0)
        // Neighbourhood wraps in x and stops at the poles.
        let n = RadarQCMask.neighbourhood(of: T(z: 2, x: 0, y: 0))
        #expect(n[0] == nil && n[1] == nil && n[2] == nil)
        #expect(n[3] == T(z: 2, x: 3, y: 0) && n[5] == T(z: 2, x: 1, y: 0))
    }

    static func alpha(_ on: [(Int, Int)]) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 256 * 256); for (x, y) in on { a[y * 256 + x] = 255 }; return a
    }

    // CR #6.2: an echo just across a seam keeps the edge of this tile, in all directions.
    @Test func dilationCrossesTileSeams() {
        var block = [[UInt8]?](repeating: nil, count: 9)
        block[5] = Self.alpha([(0, 100)])     // right neighbour, its first column
        block[0] = Self.alpha([(255, 255)])   // top-left neighbour corner
        let m = RadarQCMask.dilatedCentre(block, radius: 3)
        #expect(m[100 * 256 + 255] == 1 && m[100 * 256 + 253] == 1 && m[100 * 256 + 252] == 0)
        #expect(m[97 * 256 + 255] == 1 && m[96 * 256 + 255] == 0)
        #expect(m[0] == 1 && m[2 * 256 + 2] == 1 && m[3 * 256 + 3] == 0)
        #expect(RadarQCMask.dilatedCentre([[UInt8]?](repeating: nil, count: 9), radius: 5).allSatisfy { $0 == 0 })
    }

    @Test func applyClearsOutsideTheMaskAtHigherZoom() {
        var mask = [UInt8](repeating: 0, count: 256 * 256)
        for y in 192..<256 { for x in 192..<200 { mask[y * 256 + x] = 1 } } // left 8 mask px of the child tile
        var rgba = [UInt8](repeating: 200, count: 256 * 256 * 4)
        RadarQCMask.apply(rgba: &rgba, tile: T(z: 8, x: 75, y: 95), mask: mask)
        // Interior of the on-block stays exact. The edge is a bilinear feather (scale 4), quantized to
        // multiples of 32: x=31 weight 0.625 → 128, x=32 weight 0.375 → 64. Well outside is clear.
        #expect(rgba[(10 * 256 + 16) * 4 + 3] == 200)
        #expect(rgba[(10 * 256 + 31) * 4 + 3] == 128)
        #expect(rgba[(10 * 256 + 32) * 4 + 3] == 64)
        #expect(rgba[(10 * 256 + 80) * 4 + 3] == 0 && rgba[(255 * 256 + 255) * 4 + 3] == 0)
        // This buffer is premultiplied (the IEM path). RGB scales with the new alpha; a straight
        // nearest-site tile must not (see straightAlphaMaskKeepsLegendRGBOnAPartialEdge).
        #expect(rgba[(10 * 256 + 31) * 4] == 128 && rgba[(10 * 256 + 32) * 4] == 64)
        #expect(rgba[(10 * 256 + 80) * 4] == 0)
        // A fully-on mask does not fade the display tile's border (edge samples repeat the edge pixel).
        let full = [UInt8](repeating: 1, count: 256 * 256)
        var edge = [UInt8](repeating: 180, count: 256 * 256 * 4)
        RadarQCMask.apply(rgba: &edge, tile: T(z: 8, x: 72, y: 92), mask: full)
        #expect(edge[3] == 180 && edge[(255 * 256 + 255) * 4 + 3] == 180)
    }

    final class Counter: @unchecked Sendable {
        let lock = NSLock(); var urls: [String] = []
        func note(_ u: URL) { lock.lock(); urls.append(u.absoluteString); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return urls.count }
    }
    static let template = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/mrms::lcref-202610160134/{z}/{x}/{y}.png"

    // CR #6.4: masks are cached per (time, tile) and neighbours are shared, so extra requests stay small.
    @Test func masksAreCachedAndNeighboursShared() async {
        let c = Counter()
        let store = RadarQCMaskStore { url in c.note(url); return url.absoluteString.hasSuffix("/6/18/23.png") ? Self.alpha([(128, 128)]) : [] }
        let a = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(c.count == 9 && a?[128 * 256 + 128] == 1 && a?[0] == 0)
        _ = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(c.count == 9)
        _ = await store.mask(template: Self.template, tile: T(z: 6, x: 19, y: 23))
        #expect(c.count == 12) // 6 of 9 neighbours already held
        // Every display tile under the mask tile (16 at z8) shares one mask.
        let under = (72..<76).flatMap { x in (92..<96).map { y in RadarQCMask.maskTile(for: T(z: 8, x: x, y: y)).tile } }
        #expect(Set(under) == [T(z: 6, x: 18, y: 23)])
    }

    // Closing the window drops decoded masks and raw tiles. The RLE copy answers the next ask.
    @Test func purgeKeepsCompressedMasksWithoutRefetch() async {
        let c = Counter()
        let store = RadarQCMaskStore { url in c.note(url); return [] }
        let first = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        let fetched = c.count
        #expect(await store.cachedCount > 0)
        #expect(await store.compressedBytes > 0)
        #expect(await store.compressedBytes <= RadarQCMaskStore.defaultCompressedBudget)
        _ = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(c.count == fetched) // cached
        await store.purge()
        #expect(await store.cachedCount == 0)
        let again = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(c.count == fetched && again == first)
        #expect(await store.compressedBytes <= RadarQCMaskStore.defaultCompressedBudget)
    }

    @Test func maskBytesRoundTripAndStaySmall() {
        var sparse = [UInt8](repeating: 0, count: 256 * 256)
        sparse[128 * 256 + 128] = 1
        sparse[128 * 256 + 129] = 1
        let packed = MaskRLE.compress(sparse)
        #expect(packed.count < 32)
        #expect(MaskRLE.decompress(packed) == sparse)
        let zeros = [UInt8](repeating: 0, count: 256 * 256)
        let ones = [UInt8](repeating: 1, count: 256 * 256)
        #expect(MaskRLE.compress(zeros).count == 1 && MaskRLE.decompress(MaskRLE.compress(zeros)) == zeros)
        #expect(MaskRLE.compress(ones).count == 1 && MaskRLE.decompress(MaskRLE.compress(ones)) == ones)
        #expect(MaskRLE.decompress(Data([9])) == nil)
    }

    @Test func encodedTilesStayInsideFourMegabytes() {
        var cache = EncodedTileCache(arguments: ["skyline", "-SkylineRetainedTilesMB", "4"])
        let blob = Data(repeating: 1, count: 100_000)
        for i in 0..<50 { cache.store("t\(i)", data: blob) }
        #expect(cache.budgetBytes == 4 << 20)
        #expect(cache.bytes <= cache.budgetBytes)
        #expect(cache.bytes > 0)
        #expect(cache.touch("t49")?.count == 100_000)
        #expect(cache.touch("t0") == nil)
        cache.store("big", data: Data(count: cache.budgetBytes + 1))
        #expect(cache.touch("big") == nil)
        RadarRetryLog.backoff(path: "transient", seconds: 5)
        RadarRetryLog.backoff(path: "transient", seconds: 5)
    }

    // Clear sky (all neighbours blank but present) masks everything: the Fairfield case.
    @Test func blankButPresentMaskRemovesEverything() async {
        let store = RadarQCMaskStore { _ in [] }
        let m = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(m != nil && m!.allSatisfy { $0 == 0 })
    }

    // CR #6.3/#6.5: any failed neighbour (IEM answers a missing slot with 503) fails open, and the failure
    // is not cached: the next ask fetches again and can succeed.
    @Test func failureFailsOpenAndIsRetried() async {
        let c = Counter()
        final class Flag: @unchecked Sendable { var down = true }
        let flag = Flag()
        let store = RadarQCMaskStore { url in
            c.note(url)
            return flag.down && url.absoluteString.hasSuffix("/6/19/23.png") ? nil : []
        }
        #expect(await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23)) == nil)
        flag.down = false
        let before = c.count
        let m = await store.mask(template: Self.template, tile: T(z: 6, x: 18, y: 23))
        #expect(m != nil)
        #expect(c.count > before)
    }

#if canImport(CoreGraphics)
    static func image(_ w: Int, _ h: Int, _ px: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](); for y in 0..<h { for x in 0..<w { let p = px(x, y); bytes += [p.0, p.1, p.2, p.3] } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test func masksImageKeepsColoursAndEncodesPNG() throws {
        let green: (UInt8, UInt8, UInt8, UInt8) = (67, 214, 126, 255)
        let tile = Self.image(256, 256) { _, _ in green }
        var mask = [UInt8](repeating: 0, count: 256 * 256)
        for y in 0..<256 { for x in 0..<64 { mask[y * 256 + x] = 1 } }
        let out = try #require(RadarQC.masked(tile, tile: T(z: 4, x: 1, y: 1), mask: mask))
        let px = RadarTilePacker.render(out.image, space: CGColorSpace(name: CGColorSpace.sRGB))
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * 256 + x) * 4..<(y * 256 + x) * 4 + 4]) }
        #expect(at(0, 5) == [67, 214, 126, 255] && at(63, 5) == [67, 214, 126, 255])
        #expect(at(64, 5) == [0, 0, 0, 0])
        // Stored compressed: the PNG is far smaller than RGBA and decodes back to the same pixels.
        #expect(out.png.count < 256 * 256)
        let src = try #require(CGImageSourceCreateWithData(out.png as CFData, nil))
        let back = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(RadarTilePacker.render(back, space: CGColorSpace(name: CGColorSpace.sRGB)) == px)
        #expect(RadarQC.masked(Self.image(16, 16) { _, _ in green }, tile: T(z: 4, x: 1, y: 1), mask: mask) == nil)
        #expect(RadarQC.alpha(of: Self.image(256, 256) { _, _ in (0, 0, 0, 0) }) == [])
    }
#endif
}
