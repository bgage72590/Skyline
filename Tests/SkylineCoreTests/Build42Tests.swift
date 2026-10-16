import XCTest
@testable import SkylineCore

/// Build 42: radar policy (code review build 41, missing radar tests 1–7), sync mediums, location filter.
final class Build42RadarPolicyTests: XCTestCase {
    // 1. Ring policy and load order.
    func testRingPolicyCoversEveryHeldFrameAndLoadsShownPlusAheadFirst() {
        XCTAssertEqual(RadarPolicy.loadOrder(count: 17, shown: 15, holdsLoop: true).prefix(4), [15, 16, 0, 1])
        XCTAssertEqual(Set(RadarPolicy.loadOrder(count: 17, shown: 15, holdsLoop: true)), Set(0..<17))
        XCTAssertEqual(RadarPolicy.ringFrames(count: 17, shown: 3, holdsLoop: true), Set(0..<17), "ring for all frames")
        XCTAssertEqual(RadarPolicy.loadOrder(count: 17, shown: 3, holdsLoop: false), [3])
        XCTAssertEqual(RadarPolicy.loadOrder(count: 17, shown: 3, holdsLoop: true, limitToAhead: true), [3, 4, 5, 6])
        XCTAssertEqual(RadarPolicy.loadOrder(count: 2, shown: 1, holdsLoop: true), [1, 0])
        XCTAssertEqual(RadarPolicy.loadOrder(count: 1, shown: 0, holdsLoop: true), [0])
        XCTAssertEqual(RadarPolicy.loadOrder(count: 0, shown: 0, holdsLoop: true), [])
    }

    // 2. Zoom doesn't depend on playing.
    func testZoomIsTheSamePausedAndPlaying() {
        let v = MapRectValue(x: 7.5e7, y: 1.0e8, width: 1.1e7, height: 7e6)
        let z = RadarPolicy.zoom(visible: v, viewWidth: 1200, maxZ: 9, perFrameBudget: 160)
        XCTAssertEqual(z, TileMath.zoom(fitting: v, viewWidth: 1200, maxZ: 9, frames: 1, tileBudget: 160))
        XCTAssertGreaterThan(z, TileMath.zoom(fitting: v, viewWidth: 1200, maxZ: 9, frames: 17, tileBudget: 160),
                             "never the old loop-wide budget's lower zoom")
    }

    // 3. Gesture never prunes; settled prune keeps the ring. (Modelled with the policy's sets.)
    func testSettledPruneKeepsRingForEveryFrame() {
        let v = MapRectValue(x: 7.5e7, y: 1.0e8, width: 1.1e7, height: 7e6)
        let z = RadarPolicy.zoom(visible: v, viewWidth: 1200, maxZ: 9, perFrameBudget: 160)
        let ring = Set(TileMath.tiles(covering: v, z: z, margin: 1))
        let visible = Set(TileMath.tiles(covering: v, z: z))
        XCTAssertTrue(visible.isSubset(of: ring))
        XCTAssertGreaterThan(ring.count, visible.count)
        for f in RadarPolicy.ringFrames(count: 13, shown: 5, holdsLoop: true) { XCTAssertTrue((0..<13).contains(f)) }
    }

    // 4. Pending-generation memory bound during a scan swap.
    func testScanSwapLoadsOnlyShownPlusAhead() {
        let pending = RadarPolicy.loadOrder(count: 19, shown: 10, holdsLoop: true, limitToAhead: true)
        XCTAssertEqual(pending.count, 1 + RadarPolicy.aheadFrames)
        let ring = 42
        let peak = RadarMemoryBudget.peakBytes(ringTiles: ring, frames: 19, swapping: true)
        XCTAssertEqual(peak, (19 + 4) * ring * RadarMemoryBudget.rgbaTileBytes)
        XCTAssertLessThan(Double(peak) / Double(RadarMemoryBudget.peakBytes(ringTiles: ring, frames: 19, swapping: false)), 1.25,
                          "a swap adds at most 4 frames, not a second loop")
    }

    // 5. Draw order: current zoom last on zoom in and out.
    func testCurrentZoomTilesAreDrawnLast() {
        let keys = [TileKey(z: 8, x: 1, y: 1), TileKey(z: 6, x: 0, y: 0), TileKey(z: 7, x: 0, y: 0), TileKey(z: 9, x: 2, y: 2)]
        XCTAssertEqual(RadarPolicy.drawOrder(keys, currentZoom: 7).last?.z, 7, "zoom-out: finer z8/z9 leftovers drawn before")
        XCTAssertEqual(RadarPolicy.drawOrder(keys, currentZoom: 9).last?.z, 9)
        XCTAssertEqual(RadarPolicy.drawOrder(keys, currentZoom: 7).map(\.z), [6, 8, 9, 7])
        // Frame switch: showable only when every on-screen tile is resolved (no mixing of two frames).
        let d = [TileKey(z: 7, x: 0, y: 0), TileKey(z: 7, x: 1, y: 0)]
        XCTAssertFalse(RadarPolicy.isShowable(have: [d[0]], resolved: [], desired: d))
        XCTAssertTrue(RadarPolicy.isShowable(have: [d[0]], resolved: [d[1]], desired: d))
    }

    // 6. Crossfade state machine.
    func testCrossfadeRunsForPoint35sAndRetargetsFromTheBlend() {
        var c = RadarCrossfade(shown: 0)
        XCTAssertEqual(c.layers(at: 0).map(\.frame), [0])
        c.show(1, at: 10, animated: true)
        XCTAssertEqual(c.layers(at: 10).map(\.alpha), [1, 0])
        let mid = c.layers(at: 10 + 0.175)
        XCTAssertEqual(mid[0].alpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid[1].alpha, 0.5, accuracy: 0.001)
        XCTAssertTrue(c.isActive(at: 10.3))
        XCTAssertFalse(c.isActive(at: 10.36))
        XCTAssertEqual(c.layers(at: 10.4).map(\.frame), [1])
        // New index mid-fade: the incoming frame becomes the outgoing one at its current alpha.
        c.show(2, at: 20, animated: true)
        c.show(3, at: 20 + 0.175, animated: true)
        let l = c.layers(at: 20 + 0.175)
        XCTAssertEqual(l.map(\.frame), [2, 3])
        XCTAssertEqual(l[0].alpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(l[1].alpha, 0, accuracy: 0.001)
        c.show(4, at: 30, animated: false)
        XCTAssertEqual(c.layers(at: 30).map(\.frame), [4])
    }

    // 7. Memory budget table.
    func testMemoryBudgetTable() {
        var lines: [String] = []
        for (w, h) in [(1200.0, 800.0), (1512, 945), (2560, 1440), (3840, 2160)] {
            let t = RadarMemoryBudget.tiles(viewWidth: w, viewHeight: h)
            let mb = { (frames: Int, swap: Bool, b: Int) in Double(RadarMemoryBudget.peakBytes(ringTiles: t.ring, frames: frames, bytesPerTile: b, swapping: swap)) / 1_048_576 }
            let rgba = RadarMemoryBudget.rgbaTileBytes, packed = RadarMemoryBudget.packedTileBytes
            lines.append(String(format: "%4.0fx%4.0f z%d visible %3d ring %3d | 19 fr + swap: RGBA %4.0f MB, packed %4.0f MB",
                                w, h, t.z, t.visible, t.ring, mb(19, true, rgba), mb(19, true, packed)))
            XCTAssertGreaterThanOrEqual(t.ring, t.visible)
        }
        print(lines.joined(separator: "\n"))
        let laptop = RadarMemoryBudget.tiles(viewWidth: 1200, viewHeight: 800)
        XCTAssertLessThan(RadarMemoryBudget.peakBytes(ringTiles: laptop.ring, frames: 19, bytesPerTile: RadarMemoryBudget.packedTileBytes,
                                                      swapping: true), 100 << 20, "laptop window, every frame ringed, mid-swap")
    }
}

final class Build42SyncTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func pair(_ issuedMin: Double, model: String) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: "nyc", issued: t0.addingTimeInterval(issuedMin * 60), valid: t0.addingTimeInterval(10 * 3600),
                                      f: [model: SourceValues(t: issuedMin)]), ObservedHour(t: 15))
    }

    func testChainOfMacsNeverFoldsOneMacsOwnIssuances() {
        // A 0 → B 70 → C 140 → A 180: A's two issuances are 3 h apart and must both count.
        let recs = [pair(0, model: "a"), pair(70, model: "b"), pair(140, model: "c"), pair(180, model: "a")]
        for order in [recs, recs.reversed(), [recs[2], recs[0], recs[3], recs[1]]] {
            let scored = AccuracySync.collapsedForScoring(AccuracySync.merge(order, []))
            XCTAssertEqual(scored.count, 2)
            XCTAssertEqual(scored.filter { $0.r.f["a"] != nil }.count, 2, "both of Mac A's issuances count")
        }
    }

    func testFastWritersResetIsSkewCorrectedNotClampedToReadersNow() {
        // Mac A's clock is 2 days fast. It reset at real time t0 and wrote the file then (stamps t0+2d);
        // Mac B reads it a day later with no usable file date. Pairs B issued after t0 are kept.
        let now = t0.addingTimeInterval(86400)
        let skew: TimeInterval = 2 * 86400
        let remote = AccuracyFile(reset: AccuracyReset(generation: 1, at: t0.addingTimeInterval(skew)), writtenAt: t0.addingTimeInterval(skew + 60))
        let mine = AccuracyFile(pairs: (2...20).map { i in
            VerifiedRecord(ForecastRecord(loc: "nyc", issued: t0.addingTimeInterval(Double(i) * 3600), valid: t0.addingTimeInterval(Double(i) * 3600 + 3600),
                                          f: ["blend": SourceValues(t: 1)]), ObservedHour(t: 1))
        })
        let m = AccuracyFile.merge(local: mine, remote: remote, now: now, remoteFileDate: t0.addingTimeInterval(60))
        XCTAssertEqual(m.file.reset?.at.timeIntervalSince(t0) ?? 99, 0, accuracy: 120)
        XCTAssertEqual(m.file.pairs.count, 19)
    }
}

final class Build42LocationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func fix(_ lat: Double, _ lon: Double, acc: Double = 65, age: TimeInterval = 0) -> LocationFixFilter.Fix {
        .init(latitude: lat, longitude: lon, accuracy: acc, timestamp: now.addingTimeInterval(-age))
    }

    func testInaccurateStaleAndInvalidFixesAreRejected() {
        var f = LocationFixFilter()
        XCTAssertEqual(f.evaluate(fix(41.14, -73.26, acc: 8_000), now: now), .rejectInaccurate)
        XCTAssertEqual(f.evaluate(fix(41.14, -73.26, acc: -1), now: now), .rejectInaccurate)
        XCTAssertEqual(f.evaluate(fix(41.14, -73.26, age: 600), now: now), .rejectStale)
        XCTAssertEqual(f.evaluate(fix(0, 0), now: now), .rejectInvalid)
        XCTAssertEqual(f.evaluate(fix(.nan, 1), now: now), .rejectInvalid)
        XCTAssertEqual(f.evaluate(fix(41.14, -73.26), now: now), .accept)
    }

    func testBigJumpNeedsASecondConfirmingFix() {
        var f = LocationFixFilter(last: Coordinate(latitude: 41.14, longitude: -73.26)) // Fairfield, CT
        XCTAssertEqual(f.evaluate(fix(18.03, -63.05), now: now), .holdForConfirmation, "Sint Maarten from one fix: held")
        XCTAssertEqual(f.evaluate(fix(41.15, -73.25), now: now), .accept, "back home: accepted, candidate dropped")
        XCTAssertEqual(f.evaluate(fix(18.03, -63.05, age: 299), now: now), .holdForConfirmation)
        // Build 45: confirmation needs nearby fixes spanning a while; NYC → Sint Maarten is a far jump, so
        // 10 min (QA G1-a). 299 s old + now is under 10 min: still held; the filter has no fix ≥ 10 min apart
        // within `maxAge`, so this path can't confirm from fixes all inside 5 min.
        XCTAssertEqual(f.evaluate(fix(18.04, -63.06, age: 0), now: now), .holdForConfirmation)
        XCTAssertEqual(f.evaluate(fix(18.05, -63.04, age: -301), now: now.addingTimeInterval(310)), .accept, "fixes 10+ min apart confirm a real trip")
    }
}

#if canImport(CoreGraphics)
import CoreGraphics
final class Build42TilePackerTests: XCTestCase {
    /// A radar-like tile: transparent background, ~15 palette colours in blobs.
    func radarTile(colors: Int = 15, partialAlpha: Bool = false) -> CGImage {
        let w = 256, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let d = hypot(Double(x - 128), Double(y - 110))
            guard d < 100 else { continue }
            let c = (x + y * 7) % colors
            let i = (y * w + x) * 4
            px[i] = UInt8(c % 256); px[i + 1] = UInt8(c / 256 * 60 + 40); px[i + 2] = 99
            px[i + 3] = partialAlpha && d > 90 ? 128 : 255
            if px[i + 3] == 128 { px[i] /= 2; px[i + 1] /= 2; px[i + 2] /= 2 }
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testPackingIsPixelExactAndSmaller() {
        let tile = radarTile()
        let packed = RadarTilePacker.pack(tile)
        XCTAssertTrue(packed.isPacked, "radar-like tile should pack")
        XCTAssertEqual(RadarTilePacker.render(packed.image()!), RadarTilePacker.render(tile), "lossless")
        XCTAssertLessThan(packed.heldBytes * 3, tile.bytesPerRow * tile.height)
    }

    func testPartialAlphaOrTooManyColoursStayUnchanged() {
        XCTAssertFalse(RadarTilePacker.pack(radarTile(partialAlpha: true)).isPacked, "partial alpha must not pack")
        XCTAssertFalse(RadarTilePacker.pack(radarTile(colors: 300)).isPacked, ">256 colours must not pack")
        let kept = radarTile(colors: 300)
        XCTAssertEqual(RadarTilePacker.render(RadarTilePacker.pack(kept).image()!), RadarTilePacker.render(kept))
    }
}
#endif
