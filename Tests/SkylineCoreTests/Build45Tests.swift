import XCTest
@testable import SkylineCore
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Build 45: SXM search, frame timeout, location-filter gaps, wording C1/L3, storage S1, compressed tiles.
final class Build45SearchTests: XCTestCase {
    func place(_ id: Int, _ name: String, _ code: String?, cc: String = "SX") -> PlaceSearchResult {
        PlaceSearchResult(id: id, name: name, admin1: nil, country: nil, countryCode: cc,
                          coordinate: Coordinate(latitude: 18, longitude: -63), timeZoneIdentifier: nil, population: nil, featureCode: code)
    }

    func testDecodesFeatureCode() throws {
        let json = #"{"results":[{"id":1,"name":"Sint Maarten","latitude":18.04,"longitude":-63.07,"country_code":"SX","feature_code":"PCLIX"},{"id":2,"name":"Princess Juliana International Airport","latitude":18.04,"longitude":-63.11,"country_code":"SX","feature_code":"AIRP"}]}"#
        let r = try OpenMeteoGeocodingResponse.decode(Data(json.utf8))
        XCTAssertEqual(r.map(\.featureCode), ["PCLIX", "AIRP"])
        XCTAssertTrue(r[0].isCountryLevel); XCTAssertTrue(r[1].isAirport)
    }

    func testSXMReturnAddsTheAirportNeverTheCountry() {
        let live = [place(1, "Sint Maarten", "PCLIX"), place(2, "Princess Juliana International Airport", "AIRP")]
        XCTAssertEqual(SearchSubmit.ranked(live, query: "SXM").map(\.id), [2, 1], "airports first for a 3-letter query")
        XCTAssertEqual(SearchSubmit.pick(results: live, resultsQuery: "SXM", currentText: "sxm ")?.id, 2)
        XCTAssertEqual(SearchSubmit.ranked(live, query: "Sint Maarten").map(\.id), [1, 2], "other queries keep the service's order")
        XCTAssertNil(SearchSubmit.pick(results: live, resultsQuery: "Sint Maarten", currentText: "Sint Maarten"),
                     "a country first: nothing auto-added, the list stays open")
        let pbi = [place(3, "West Palm Beach", "PPLA2", cc: "US"), place(4, "Palm Beach International Airport", "AIRP", cc: "US")]
        XCTAssertEqual(SearchSubmit.pick(results: pbi, resultsQuery: "PBI", currentText: "PBI")?.id, 4)
        XCTAssertEqual(live[1].subtitle, "Airport · Sint Maarten")
    }
}

final class Build45RadarTests: XCTestCase {
    func testStuckFrameIsShownAfterTimeout() {
        XCTAssertTrue(RadarPolicy.shouldShow(complete: true, nothingShown: false, waited: 0))
        XCTAssertFalse(RadarPolicy.shouldShow(complete: false, nothingShown: false, waited: 1.0), "waits briefly for missing tiles")
        XCTAssertTrue(RadarPolicy.shouldShow(complete: false, nothingShown: false, waited: RadarPolicy.incompleteTimeout),
                      "a tile that never resolves can't freeze the display")
        XCTAssertTrue(RadarPolicy.shouldShow(complete: false, nothingShown: true, waited: 0))
    }

    /// Review missing test: memory with a measured pack ratio. RainViewer measured 142 packed / 326
    /// compressed / 0 RGBA (Mac, build 45); even all-RGBA-sized compressed bytes stay small.
    func testMemoryWithMeasuredRainViewerMix() {
        let compressedTile = 40 * 1024 // upper end of RainViewer PNGs
        let mixed = (142 * RadarMemoryBudget.packedTileBytes + 326 * compressedTile) / 468
        let full = RadarMemoryBudget.tiles(viewWidth: 2560, viewHeight: 1440)
        let peak = RadarMemoryBudget.peakBytes(ringTiles: full.ring, frames: 19, bytesPerTile: mixed, swapping: true)
        XCTAssertLessThan(peak, 150 << 20, "2560×1440, 19 frames, mid-swap")
    }
}

final class Build45LocationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func fix(_ lat: Double, _ lon: Double, _ dt: TimeInterval) -> LocationFixFilter.Fix {
        .init(latitude: lat, longitude: lon, accuracy: 65, timestamp: now.addingTimeInterval(dt))
    }

    func testFutureDatedFixIsInvalid() {
        var f = LocationFixFilter(last: Coordinate(latitude: 41.14, longitude: -73.26))
        XCTAssertEqual(f.evaluate(fix(41.14, -73.26, 600), now: now), .rejectInvalid)
    }

    func testRepeatedBogusFixNeedsTwoMinutesOfAgreement() {
        var f = LocationFixFilter(last: Coordinate(latitude: 41.14, longitude: -73.26)) // Fairfield
        XCTAssertEqual(f.evaluate(fix(18.04, -63.07, 0), now: now), .holdForConfirmation)
        XCTAssertEqual(f.evaluate(fix(18.04, -63.07, 20), now: now.addingTimeInterval(20)), .holdForConfirmation,
                       "the same Wi-Fi answer 20 s later is not a confirmation")
        XCTAssertEqual(f.evaluate(fix(18.05, -63.06, 130), now: now.addingTimeInterval(130)), .accept, "real travel: agreement over 2 min")
    }

    func testFirstFixWithoutSeedChecksTheTimeZone() {
        var ny = LocationFixFilter(timeZoneOffset: -4 * 3600)
        XCTAssertEqual(ny.evaluate(fix(52.37, 4.9, 0), now: now), .holdForConfirmation, "Amsterdam on a New York Mac")
        var ok = LocationFixFilter(timeZoneOffset: -4 * 3600)
        XCTAssertEqual(ok.evaluate(fix(41.14, -73.26, 0), now: now), .accept)
        XCTAssertFalse(LocationFixFilter.zoneMismatch(longitude: 179, offsetSeconds: -11 * 3600), "date-line wrap")
    }
}

final class Build45WordingTests: XCTestCase {
    func testC1SameShownSpreadSameLevel() {
        func level(_ spread: Double) -> ForecastInsight.Level {
            let day = DailyForecast(date: Date(timeIntervalSince1970: 1_800_000_000), weatherCode: 3, high: 20, low: 10, highSpread: spread)
            return ForecastInsight.confidence(day: day, hourly: [], timeZone: TimeZone(identifier: "America/New_York")!,
                                              now: day.date, hourLabel: { _ in "" }, delta: { Int(($0 * 1.8).rounded()) }).level
        }
        XCTAssertEqual(level(4.49), level(4.5), "both read \"differ by 8°\" in °F")
    }

    func testL3SharesUseEachFieldsOwnDedupe() {
        // HRRR = GFS on the high only: one NOAA vote for the high, two for the low.
        let rows = [SourceReading(name: "HRRR", high: 20, low: 10, weight: 2.0),
                    SourceReading(name: "GFS", high: 20, low: 11, weight: 1.0),
                    SourceReading(name: "ECMWF", high: 21, low: 10, weight: 1.5),
                    SourceReading(name: "National Weather Service", high: 20.5, low: nil, weight: 2.5)]
        let s = SourceReading.withShares(rows, family: [true, true, false, false])
        XCTAssertEqual(s[1].highShare, 0, "GFS's high is HRRR's vote")
        XCTAssertEqual(s[0].highShare!, 2.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(s[1].lowShare!, 1.0 / 4.5, accuracy: 1e-9)
        XCTAssertNil(s[3].lowShare)
    }
}

final class Build45SyncTests: XCTestCase {
    func testS1TwoMacsCopiesDontHalveRetention() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // 2 Macs × 25 cities × 640 hours (inside the 30-day window), each Mac's copy 5 min apart.
        let n = 640
        var recs: [VerifiedRecord] = []
        for i in 0..<n { for city in 0..<25 {
            for mac in 0..<2 {
                recs.append(VerifiedRecord(ForecastRecord(loc: "c\(city)", issued: t0.addingTimeInterval(Double(i) * 3600 + Double(mac) * 300),
                                                          valid: t0.addingTimeInterval(Double(i) * 3600 + 7200),
                                                          f: ["blend": SourceValues(t: 1)]), ObservedHour(t: 1)))
            }
        } }
        let merged = AccuracySync.merge(recs, [], now: t0.addingTimeInterval(Double(n) * 3600))
        let scored = AccuracySync.collapsedForScoring(merged).count
        XCTAssertLessThanOrEqual(scored, AccuracySync.maxRecords)
        XCTAssertGreaterThan(scored, AccuracySync.maxRecords * 9 / 10, "nearly the full scored history kept, not half")
        XCTAssertLessThanOrEqual(merged.count, AccuracySync.maxStoredRecords)
        XCTAssertEqual(AccuracySync.merge(recs.reversed(), [], now: t0.addingTimeInterval(Double(n) * 3600)), merged, "order-independent")
    }
}

#if canImport(CoreGraphics)
final class Build45CompressedTileTests: XCTestCase {
    func testUnpackableTileKeepsCompressedBytesLosslessly() throws {
        let w = 256, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where hypot(Double(x - 128), Double(y - 128)) < 100 {
            let i = (y * w + x) * 4, a: UInt8 = x % 3 == 0 ? 128 : 255
            px[i] = UInt8(x) / (a == 128 ? 2 : 1); px[i + 1] = UInt8(y) / (a == 128 ? 2 : 1); px[i + 2] = 60; px[i + 3] = a
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let src = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, src, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data, nil)!, 0, nil)!
        let tile = RadarTilePacker.pack(decoded, encoded: data as Data)
        XCTAssertTrue(tile.isCompressed, "partial alpha: kept as the original PNG bytes")
        XCTAssertLessThan(tile.heldBytes * 2, w * h * 4)
        XCTAssertEqual(RadarTilePacker.render(tile.image()!), RadarTilePacker.render(decoded), "same pixels")
    }
}
#endif
