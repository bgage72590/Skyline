import XCTest
@testable import SkylineCore

/// Build 33: code review M1–M4.
final class Build33SyncTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC, on a 3 h boundary

    func pair(_ loc: String = "nyc", issued: TimeInterval, valid: TimeInterval,
              _ f: [String: SourceValues] = ["blend": SourceValues(t: 14)], obs: Double = 15) -> VerifiedRecord {
        VerifiedRecord(ForecastRecord(loc: loc, issued: t0.addingTimeInterval(issued), valid: t0.addingTimeInterval(valid), f: f),
                       ObservedHour(t: obs))
    }

    // MARK: M1

    func testTwoMacsFifteenMinutesApartAcrossASlotBoundaryCountOnce() {
        // Mac A issued at 07:50, Mac B at 08:05 (a 3 h UTC boundary between them): one verification.
        let a = pair(issued: -600, valid: 7200, ["blend": SourceValues(t: 14), "ecmwf_ifs025": SourceValues(t: 13)])
        let b = pair(issued: 300, valid: 7200, ["blend": SourceValues(t: 16), "icon_seamless": SourceValues(t: 12)])
        // Build 35: both copies stay on disk; scoring counts them once.
        let merged = AccuracySync.merge([a], [b])
        let m = AccuracySync.collapsedForScoring(merged)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].r.issued, t0.addingTimeInterval(-600), "earliest issuance kept")
        XCTAssertEqual(m[0].r.f["blend"]?.t, 14)
        XCTAssertEqual(m[0].r.f["icon_seamless"]?.t, 12)
        XCTAssertEqual(AccuracySync.merge([b], [a]), merged)
        XCTAssertEqual(AccuracySync.merge(merged, [a, b]), merged, "idempotent")
    }

    func testOneMacsOwnIssuancesNeverMerge() {
        // Same Mac: issuances are >= 3 h apart (the issue interval), each a separate forecast.
        let own = (0..<4).map { pair(issued: TimeInterval($0) * 3 * 3600, valid: 15 * 3600) }
        XCTAssertEqual(AccuracySync.merge(own, []).count, 4)
        // Two Macs 2 h apart are different issuances too (outside 90 min).
        XCTAssertEqual(AccuracySync.merge([pair(issued: 0, valid: 7200)], [pair(issued: 7200 - 1, valid: 7200 * 2)]).count, 2)
        XCTAssertEqual(AccuracySync.merge([pair(issued: 0, valid: 9000)], [pair(issued: 5400, valid: 9000)]).count, 2,
                       "exactly 90 min apart is a separate issuance")
    }

    func testClusteringIsOrderIndependentWithThreeMacs() {
        let recs = [pair(issued: 0, valid: 36000), pair(issued: 3000, valid: 36000, ["nws": SourceValues(t: 1)]),
                    pair(issued: 6000, valid: 36000, ["gfs_seamless": SourceValues(t: 2)])]
        let forward = AccuracySync.collapsedForScoring(AccuracySync.merge(recs, []))
        XCTAssertEqual(AccuracySync.collapsedForScoring(AccuracySync.merge(recs.reversed(), [])), forward)
        XCTAssertEqual(AccuracySync.collapsedForScoring(AccuracySync.merge([recs[2]], [recs[0], recs[1]])), forward)
        XCTAssertEqual(forward.count, 2, "build 42: runs span < 90 min from their first issuance (0+50 | 100)")
    }

    // MARK: M2

    /// M2 is fixed by build 32's move: pairs live only in accuracy.json, which builds 29–31 never read or
    /// write. An old build rewriting sync.json (dropping keys it doesn't know) can't touch them.
    func testOldBuildRewritingSyncJsonCannotWipeAccuracy() throws {
        let acc = AccuracyFile(reset: AccuracyReset(generation: 1, at: t0), pairs: AccuracySync.merge([pair(issued: 0, valid: 3600)], []))
        let accBytes = try acc.encoded()
        // What a build-29/30 Mac writes back: only the keys it knows.
        var doc = SyncDocument(); doc.settings = ["clockStyle": "s:h24"]
        let oldWrite = try doc.encoded()
        XCTAssertNotNil(SyncDocument.decode(oldWrite))
        XCTAssertFalse(String(decoding: try SyncDocument.merge(local: doc, remote: doc).encoded(), as: UTF8.self).contains("accuracy"))
        // accuracy.json is a separate file: unchanged and still readable.
        XCTAssertEqual(AccuracyFile.decode(accBytes), acc)
    }

    // MARK: M3

    func testMalformedPairIsSkippedNotTheWholeFile() throws {
        let good = AccuracyFile(pairs: AccuracySync.merge([pair(issued: 0, valid: 3600), pair(issued: 0, valid: 7200)], []))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try good.encoded()) as? [String: Any])
        var groups = try XCTUnwrap(json["g"] as? [[String: Any]])
        var rows = try XCTUnwrap(groups[0]["r"] as? [Any])
        rows.append(["junk"])              // wrong type
        rows.append([3600, 1])             // too short
        rows.append([3600, 1, 2, 1, 0, 99, 1, 2, 3, 4]) // unknown model index
        groups[0]["r"] = rows
        groups.append(["l": "x"])          // malformed group
        groups.append(["l": 42, "i": 0, "r": [[3600, 1, 2, 1, 0]]]) // unknown location
        json["g"] = groups
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try XCTUnwrap(AccuracyFile.decode(data))
        XCTAssertEqual(back.pairs, good.pairs)
    }

    func testMalformedBuild31AccuracyInSyncJsonKeepsCitiesReadable() throws {
        var doc = SyncDocument()
        doc.settings = ["clockStyle": "s:h24"]
        doc.accuracy = [pair(issued: 0, valid: 3600)]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try doc.encoded()) as? [String: Any])
        var acc = try XCTUnwrap(json["accuracy"] as? [Any])
        acc.append(["r": "broken"])
        json["accuracy"] = acc
        let back = try XCTUnwrap(SyncDocument.decode(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(back.settings, doc.settings)
        XCTAssertEqual(back.accuracy?.count, 1)
        json["accuracy"] = "not an array"
        XCTAssertEqual(SyncDocument.decode(try JSONSerialization.data(withJSONObject: json))?.settings, doc.settings)
    }

    func testNonFiniteValuesAreDroppedAndNeverBreakEncoding() throws {
        let s = SourceValues(t: .nan, pop: .infinity, p: 0.2, w: -.infinity)
        XCTAssertNil(s.t); XCTAssertNil(s.pop); XCTAssertNil(s.w); XCTAssertEqual(s.p, 0.2)
        let o = ObservedHour(t: .nan, w: 3, wet: true, p: .infinity)
        XCTAssertNil(o.t); XCTAssertNil(o.p); XCTAssertEqual(o.w, 3)
        // Even a value set after creation can't break the file encode.
        var r = pair(issued: 0, valid: 3600)
        r.r.f["blend"]?.t = .nan
        r.o.p = .infinity
        let data = try AccuracyFile(pairs: [r]).encoded()
        let back = try XCTUnwrap(AccuracyFile.decode(data))
        XCTAssertNil(back.pairs[0].r.f["blend"]?.t)
        XCTAssertNil(back.pairs[0].o.p)
        XCTAssertEqual(back.pairs[0].o.t, 15)
    }

    // MARK: M4

    /// The retry check SyncCoordinator.pullIfChanged uses: after a failed push `last` is still the file's
    /// document, so local edits show up as unsent and are pushed on the next refresh/activation/wake.
    func testEditsAfterAFailedPushStillShowAsUnsent() {
        let nyc = WeatherLocation(name: "New York", country: "United States",
                                  coordinate: Coordinate(latitude: 40.71, longitude: -74.01), countryCode: "US")
        let bos = WeatherLocation(name: "Boston", country: "United States",
                                  coordinate: Coordinate(latitude: 42.36, longitude: -71.06), countryCode: "US")
        let last = SyncDocument.migrating(locations: [nyc], settings: [:], now: t0)
        // The push of [nyc, bos] failed: `last` unchanged.
        let unsent = !SyncDocument.noting(locations: [nyc, bos], settings: [:], previous: last, now: t0 + 60).sameContent(as: last)
        XCTAssertTrue(unsent)
        // Nothing edited: no retry push.
        XCTAssertTrue(SyncDocument.noting(locations: [nyc], settings: [:], previous: last, now: t0 + 60).sameContent(as: last))
    }
}

/// Build-32 review N-H1 (blocker folded into build 33): build 31 + build 32+ Macs on one iCloud.
final class Build33MixedFleetTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testBuild31FileIsNotRewrittenAndItsPairsCanBeAbsorbed() async throws {
        let p = VerifiedRecord(ForecastRecord(loc: "nyc", issued: t0, valid: t0.addingTimeInterval(3600),
                                              f: ["blend": SourceValues(t: 14)]), ObservedHour(t: 15))
        var build31 = SyncDocument(); build31.settings = ["clockStyle": "s:h24"]; build31.settingStamps = ["clockStyle": t0]; build31.accuracy = [p]
        // A build-33 Mac with the same cities/settings merging that file: same content → SyncFileIO writes nothing.
        var mine = SyncDocument(); mine.settings = ["clockStyle": "s:h24"]; mine.settingStamps = ["clockStyle": t0]
        let merged = SyncDocument.merge(local: mine, remote: build31)
        XCTAssertTrue(merged.sameContent(as: build31))
        XCTAssertEqual(merged.accuracy, [p], "build 31's pairs stay in its file")
        // Build 31 merging the build-33 result back sees its own pairs: no write either (no ping-pong).
        XCTAssertEqual(SyncDocument.merge(local: build31, remote: merged).accuracy, [p])
        // The pairs are folded into this Mac's history (what SyncCoordinator.absorbLegacyAccuracy does).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-b33-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { [t0] in t0.addingTimeInterval(86400) })
        let changed = await v.absorb(AccuracyFile(reset: nil, pairs: merged.accuracy ?? []))
        XCTAssertTrue(changed)
        let n = await v.syncFile().pairs.count
        XCTAssertEqual(n, 1)
    }
}

/// QA SF1 (build 32): the 3 h issuance gate uses the forecast's issue time.
final class Build33IssueGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func rows(issued: Date) -> [ForecastRecord] {
        (1...21).map { ForecastRecord(loc: "nyc", issued: issued, valid: issued.addingTimeInterval(Double($0) * 3600),
                                      f: ["blend": SourceValues(t: Double($0))]) }
    }

    func testDelayedRecordingCannotLandTwoIssuancesMinutesApart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-sf1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(t0)
        let v = ForecastVerifier(directory: dir, client: MockHTTPClient(), now: { clock.now })
        // Issuance A captured at t0 but recorded 3 h 5 min later (delayed task)...
        clock.now = t0.addingTimeInterval(3 * 3600 + 300)
        await v.record(rows(issued: t0), key: "nyc")
        // ...issuance B captured 11 min after A's capture, recorded right away: same forecast, rejected.
        await v.record(rows(issued: t0.addingTimeInterval(660)), key: "nyc")
        // A real next issuance 3 h after A's issue time is accepted.
        await v.record(rows(issued: t0.addingTimeInterval(3 * 3600)), key: "nyc")
        let report = await v.report("nyc")
        XCTAssertEqual(report.pendingForecasts, 42, "two issuances, 3 h apart by issue time")
        // Every recorded pair survives the accuracy merge (none collapse).
        clock.now = t0.addingTimeInterval(30 * 3600)
        let obs = (0...30).map { StationObservation(time: t0.addingTimeInterval(Double($0) * 3600), temperatureC: 15, windKmh: nil, precipLastHourMM: nil, precipitating: false) }
        await v.ingest(observations: obs, key: "nyc")
        let verified = await v.syncFile().pairs.count
        XCTAssertEqual(verified, 42)
    }
}
