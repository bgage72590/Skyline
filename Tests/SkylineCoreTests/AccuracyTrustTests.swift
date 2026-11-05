import Foundation
import XCTest
@testable import SkylineCore

/// H1 + H3 + H2 + M3. Static fixtures, injected clock, stub HTTP. T21 is the bias-file gate.
final class AccuracyTrustTests: XCTestCase {
    /// 2023-11-14 22:00:00 UTC — on the hour (1_700_002_800 % 3600 == 0).
    private let base = Date(timeIntervalSince1970: 1_700_002_800)
    private let london = Coordinate(latitude: 51.5074, longitude: -0.1278)

    // MARK: H1

    func testT1DedupePerFetch() async throws {
        let (store, _, _) = try makeStore()
        let fetched = base
        let series = onHourHours(fetchedAt: fetched, count: 8)
        for minute in stride(from: 0, to: 50, by: 10) {
            await store.recordMetPending(key: "london", issued: fetched.addingTimeInterval(Double(minute) * 60),
                                         hours: series, fetchedAt: fetched)
        }
        let rows = await store.metPendingSamples(for: "london")
        XCTAssertEqual(rows.count, series.count, "five refreshes of one fetch add one set (I1)")
        let hours = Set(rows.map { ForecastSampler.hourBucket($0.valid) })
        XCTAssertEqual(hours.count, rows.count)
    }

    func testT2SecondFetchAddsASet() async throws {
        let (store, _, _) = try makeStore()
        let series = onHourHours(fetchedAt: base, count: 6)
        await store.recordMetPending(key: "london", issued: base, hours: series, fetchedAt: base)
        let later = base.addingTimeInterval(2 * 3600)
        await store.recordMetPending(key: "london", issued: later, hours: series, fetchedAt: later)
        let shared = base.addingTimeInterval(3 * 3600)
        let copies = await store.metPendingSamples(for: "london").filter { $0.valid == shared }
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(Set(copies.compactMap(\.fetchedAt)).count, 2)
    }

    func testT3HourAlignment() async throws {
        let (store, _, _) = try makeStore()
        let issued = base.addingTimeInterval(35 * 60)
        var series = onHourHours(fetchedAt: base, count: 4)
        let off = base.addingTimeInterval(2 * 3600 + 35 * 60)
        series.append(MetNorwayHour(time: off, temperatureC: 99))
        await store.recordMetPending(key: "london", issued: issued, hours: series, fetchedAt: base)
        let rows = await store.metPendingSamples(for: "london")
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { Int($0.valid.timeIntervalSince1970) % 3600 == 0 })
        XCTAssertFalse(rows.contains { $0.valid == off })
        XCTAssertFalse(rows.contains { $0.forecastC == 99 })
    }

    func testT4PerCityCap() async throws {
        let dir = try scratch()
        let now = base
        var rows: [MetPendingSample] = []
        for i in 0..<2_000 {
            let valid = now.addingTimeInterval(Double(10 + i) * 3600)
            rows.append(MetPendingSample(loc: "a", issued: now, valid: valid, forecastC: 1, fetchedAt: now))
        }
        let other = (0..<5).map { i in
            MetPendingSample(loc: "b", issued: now, valid: now.addingTimeInterval(Double(10 + i) * 3600),
                             forecastC: 2, fetchedAt: now)
        }
        try writePending(rows + other, dir: dir)
        let store = BenchmarkStore(directory: dir, client: ClosedHTTP(), now: { now })
        let a = await store.metPendingSamples(for: "a")
        let b = await store.metPendingSamples(for: "b")
        XCTAssertLessThanOrEqual(a.count, BenchmarkStore.metPendingPerCityCap)
        XCTAssertEqual(a.count, BenchmarkStore.metPendingPerCityCap)
        XCTAssertEqual(b.count, 5)
        XCTAssertEqual(Set(b.map(\.forecastC)), [2])
    }

    func testT5NearDueProtectedAndEvictionOrder() async throws {
        let now = base
        // Protected copies alone exceed the cap: every one of them survives, far rows do not (I2).
        var crowded: [MetPendingSample] = []
        for copy in 0..<400 {
            let fetched = now.addingTimeInterval(Double(-copy) * 3600)
            for hour in 1...6 {
                let valid = now.addingTimeInterval(Double(hour) * 3600)
                crowded.append(MetPendingSample(loc: "a", issued: fetched, valid: valid,
                                                forecastC: Double(copy), fetchedAt: fetched))
            }
        }
        for i in 0..<40 {
            let valid = now.addingTimeInterval(Double(48 + i) * 3600)
            crowded.append(MetPendingSample(loc: "a", issued: now, valid: valid, forecastC: 0, fetchedAt: now))
        }
        let dir1 = try scratch()
        try writePending(crowded, dir: dir1)
        let over = BenchmarkStore(directory: dir1, client: ClosedHTTP(), now: { now })
        let kept = await over.metPendingSamples(for: "a")
        XCTAssertGreaterThan(kept.count, BenchmarkStore.metPendingPerCityCap)
        XCTAssertTrue(kept.allSatisfy { $0.valid <= now.addingTimeInterval(BenchmarkStore.metPendingProtectHours * 3600) })
        XCTAssertEqual(kept.count, 400 * 6)

        // Under the protected-overflow case: superseded copies go first, then the farthest hours.
        var ordered: [MetPendingSample] = []
        for hour in 1...6 {
            ordered.append(MetPendingSample(loc: "a", issued: now, valid: now.addingTimeInterval(Double(hour) * 3600),
                                            forecastC: 1, fetchedAt: now))
        }
        let near = now.addingTimeInterval(8 * 3600)
        let oldFetch = now.addingTimeInterval(-5 * 3600)
        let newFetch = now.addingTimeInterval(-1 * 3600)
        ordered.append(MetPendingSample(loc: "a", issued: oldFetch, valid: near, forecastC: 1, fetchedAt: oldFetch))
        ordered.append(MetPendingSample(loc: "a", issued: newFetch, valid: near, forecastC: 2, fetchedAt: newFetch))
        for i in 0..<1_800 {
            let valid = now.addingTimeInterval(Double(9 + i) * 3600)
            ordered.append(MetPendingSample(loc: "a", issued: newFetch, valid: valid, forecastC: 3, fetchedAt: newFetch))
        }
        let dir2 = try scratch()
        try writePending(ordered, dir: dir2)
        let store = BenchmarkStore(directory: dir2, client: ClosedHTTP(), now: { now })
        let rows = await store.metPendingSamples(for: "a")
        XCTAssertLessThanOrEqual(rows.count, BenchmarkStore.metPendingPerCityCap)
        let protectUntil = now.addingTimeInterval(6 * 3600)
        XCTAssertEqual(rows.filter { $0.valid <= protectUntil }.count, 6)
        let nearRows = rows.filter { $0.valid == near }
        XCTAssertEqual(nearRows.count, 1)
        XCTAssertEqual(nearRows.first?.fetchedAt, newFetch)
        XCTAssertFalse(rows.contains { $0.valid == now.addingTimeInterval(Double(9 + 1799) * 3600) })
        XCTAssertTrue(rows.contains { $0.valid == now.addingTimeInterval(9 * 3600) })
    }

    func testT6SupersededFirst() async throws {
        let now = base
        let valid = now.addingTimeInterval(24 * 3600)
        let fetches = [-3, -2, -1].map { now.addingTimeInterval(Double($0) * 3600) }
        var rows = fetches.enumerated().map { i, fetched in
            MetPendingSample(loc: "a", issued: fetched, valid: valid, forecastC: Double(i), fetchedAt: fetched)
        }
        let newest = fetches.last!
        for i in 0..<1_600 {
            rows.append(MetPendingSample(loc: "a", issued: newest,
                                         valid: now.addingTimeInterval(Double(25 + i) * 3600),
                                         forecastC: 9, fetchedAt: newest))
        }
        let dir = try scratch()
        try writePending(rows, dir: dir)
        let store = BenchmarkStore(directory: dir, client: ClosedHTTP(), now: { now })
        let kept = await store.metPendingSamples(for: "a").filter { $0.valid == valid }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.fetchedAt, newest)
    }

    func testT7MigrationThenScore() async throws {
        let dir = try scratch()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        struct Legacy: Encodable {
            var loc: String
            var issued: Date
            var valid: Date
            var forecastC: Double
        }
        var data = Data()
        for n in 0..<100 {
            let valid = base.addingTimeInterval(Double(n) * 3600 + 35 * 60)
            let row = Legacy(loc: "london", issued: base, valid: valid, forecastC: Double(n))
            let line = try enc.encode(row)
            for _ in 0..<100 {
                data.append(line)
                data.append(0x0A)
            }
        }
        let onHour = base.addingTimeInterval(48 * 3600)
        for issued in [base, base.addingTimeInterval(60)] {
            let dup = Legacy(loc: "london", issued: issued, valid: onHour, forecastC: 5)
            data.append(try enc.encode(dup))
            data.append(0x0A)
        }
        data.append(try enc.encode(Legacy(loc: "london", issued: base, valid: onHour, forecastC: 6)))
        data.append(0x0A)
        try data.write(to: dir.appendingPathComponent("met-pending.jsonl"))

        let now = base
        let store = BenchmarkStore(directory: dir, client: ClosedHTTP(), now: { now })
        let migrated = await store.metPendingSamples(for: "london")
        XCTAssertTrue(migrated.allSatisfy { ForecastSampler.isOnTheHour($0.valid) })
        XCTAssertFalse(migrated.contains { $0.fetchedAt == nil && !ForecastSampler.isOnTheHour($0.valid) })
        XCTAssertEqual(migrated.count, 2)
        XCTAssertEqual(migrated.filter { $0.forecastC == 5 }.count, 1)

        let series = onHourHours(fetchedAt: base, count: 3)
        await store.recordMetPending(key: "london", issued: base, hours: series, fetchedAt: base)
        let obs = series.map {
            StationObservation(time: $0.time, temperatureC: 0, windKmh: nil, precipLastHourMM: nil, precipitating: false)
        }
        let pairs = await store.scoreMetPending(key: "london", observations: obs,
                                                now: base.addingTimeInterval(3 * 3600 + 21 * 60))
        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(pairs.allSatisfy { $0.issued == self.base && ForecastSampler.isOnTheHour($0.valid) })
    }

    func testT8ScoringUsesFetchedAt() async throws {
        let (store, _, _) = try makeStore()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let series = try dec.decode([MetNorwayHour].self, from: Fixture.data("met-hours-synthetic"))
        await store.recordMetPending(key: "london", issued: base, hours: series, fetchedAt: base)
        let obs = series.map {
            StationObservation(time: $0.time, temperatureC: 0, windKmh: nil, precipLastHourMM: nil, precipitating: false)
        }
        let pairs = await store.scoreMetPending(key: "london", observations: obs,
                                                now: base.addingTimeInterval(3 * 3600))
        XCTAssertFalse(pairs.isEmpty)
        XCTAssertTrue(pairs.allSatisfy {
            $0.issued == self.base && Int($0.valid.timeIntervalSince1970) % 3600 == 0
        })
        XCTAssertEqual(Set(pairs.map(\.valid)), Set(series.map(\.time).filter { $0 < self.base.addingTimeInterval(3 * 3600) }))
    }

    // MARK: H3

    func testT9Intersection() {
        let pairs = intersectionPairs()
        let paired = BenchmarkScorer.pairedHourly(pairs, loc: "L")
        let b = Set(10..<30)
        XCTAssertEqual(paired.n, b.count)
        XCTAssertEqual(Set(paired.kinds.keys), [.skyline, .metNorway, .nws])
    }

    func testT10DedupeOversampling() {
        var pairs: [BenchmarkHourlyPair] = []
        for hour in 0..<20 {
            let valid = base.addingTimeInterval(Double(hour) * 3600)
            pairs.append(pair(.skyline, valid: valid, leadH: 2, forecast: 10, obs: 12))
            for copy in 0..<7 {
                let forecast = copy == 0 ? 13.5 : 0
                pairs.append(pair(.metNorway, valid: valid, leadH: 2 + Double(copy), forecast: forecast, obs: 12))
            }
        }
        let paired = BenchmarkScorer.pairedHourly(pairs, loc: "L")
        XCTAssertEqual(paired.n, 20)
        XCTAssertEqual(paired.kinds[.metNorway] ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(paired.kinds[.skyline] ?? -1, 2, accuracy: 1e-9)
    }

    func testT11HideMetUntilFair() {
        let few = metOverlap(hours: 19)
        XCTAssertNil(few.kinds[.metNorway])
        var hidden = BenchmarkSummary(rows: [.init(kind: .metNorway, tempMAE: 1, n: 100, dailyN: 0)], pairedHourly: few)
        XCTAssertFalse(BenchmarkScorer.showsMetNorwayRow(hidden))
        let enough = metOverlap(hours: 20)
        XCTAssertNotNil(enough.kinds[.metNorway])
        XCTAssertGreaterThanOrEqual(enough.n, 20)
        hidden.pairedHourly = enough
        XCTAssertTrue(BenchmarkScorer.showsMetNorwayRow(hidden))
        let legacy = BenchmarkSummary(rows: [.init(kind: .metNorway, tempMAE: 1, n: 20, dailyN: 0)])
        XCTAssertNil(legacy.pairedHourly)
        XCTAssertTrue(BenchmarkScorer.showsMetNorwayRow(legacy))
    }

    func testT12LegacyOffHourMetExcluded() {
        var pairs: [BenchmarkHourlyPair] = []
        for hour in 0..<25 {
            let valid = base.addingTimeInterval(Double(hour) * 3600)
            pairs.append(pair(.skyline, valid: valid, leadH: 2, forecast: 10, obs: 11))
            pairs.append(pair(.metNorway, valid: valid.addingTimeInterval(35 * 60), leadH: 2, forecast: 0, obs: 11))
        }
        let paired = BenchmarkScorer.pairedHourly(pairs, loc: "L")
        XCTAssertNil(paired.kinds[.metNorway])
        XCTAssertEqual(paired.n, 25)
        XCTAssertNotNil(paired.kinds[.skyline])
    }

    func testT13KindDropKeepsMinimum() {
        var pairs: [BenchmarkHourlyPair] = []
        for hour in 0..<40 {
            let valid = base.addingTimeInterval(Double(hour) * 3600)
            pairs.append(pair(.skyline, valid: valid, leadH: 2, forecast: 10, obs: 11))
            pairs.append(pair(.metNorway, valid: valid, leadH: 2, forecast: 10, obs: 11))
            if hour < 19 {
                pairs.append(pair(.bestMatch, valid: valid, leadH: 2, forecast: 10, obs: 11))
            }
        }
        let paired = BenchmarkScorer.pairedHourly(pairs, loc: "L")
        XCTAssertEqual(Set(paired.kinds.keys), [.skyline, .metNorway])
        XCTAssertNil(paired.kinds[.bestMatch])
        XCTAssertGreaterThanOrEqual(paired.n, 20)
        XCTAssertEqual(paired.n, 40)
    }

    func testT14CodableRollback() throws {
        let json = """
        {"rows":[{"kind":"met_norway","n":20,"dailyN":0}],"metNorwayAttribution":"Data: MET Norway, CC BY 4.0","extraFlag":true}
        """
        let summary = try JSONDecoder().decode(BenchmarkSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.pairedHourly)
        XCTAssertEqual(summary.rows.first?.n, 20)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let oldPending = #"{"loc":"k","issued":1700002800,"valid":1700006400,"forecastC":1,"futureField":1}"#
        let pending = try dec.decode(MetPendingSample.self, from: Data(oldPending.utf8))
        XCTAssertNil(pending.fetchedAt)
        let metaJSON = #"{"london":{}}"#
        let meta = try dec.decode([String: BenchmarkStore.Meta].self, from: Data(metaJSON.utf8))
        XCTAssertNil(meta["london"]?.deadStationIDs)
        XCTAssertNil(meta["london"]?.station)
    }

    // MARK: H2

    func testT15SiteTypeDecode() throws {
        let stations = try METARClient.decodeStations(Fixture.data("awc-stationinfo-london"))
        XCTAssertEqual(stations.first { $0.id == "EGRB" }?.siteTypes, ["METAR"])
        XCTAssertEqual(stations.first { $0.id == "EGLC" }?.siteTypes, ["METAR", "TAF"])
        let ranked = METARClient.rankCandidates(stations, near: london)
        XCTAssertFalse(ranked.contains { $0.id == "EGXX" })
        XCTAssertTrue(ranked.contains { $0.id == "EGRB" })
        XCTAssertNotEqual(METARClient.pickNearest(stations, near: london)?.stationID, "EGXX")
    }

    func testT16LivenessPick() async throws {
        let client = StubHTTP()
        client.stationInfo = try Fixture.data("awc-stationinfo-london")
        client.metar = try Fixture.data("awc-metar-london-live")
        let (store, _, _) = try makeStore(client: client)
        let rawPick = await store.ensureStation(key: "london", near: london, isUS: false)
        let pick = try XCTUnwrap(rawPick)
        XCTAssertNotEqual(pick.stationID, "EGRB")
        XCTAssertEqual(pick.verified, true)
        XCTAssertNil(pick.verifiedRecheckAt)
        let stations = try METARClient.decodeStations(Fixture.data("awc-stationinfo-london"))
        let live: Set<String> = ["EGLC", "EGLL"]
        let expected = stations.filter { live.contains($0.id) }.min {
            NexradStation.distanceKm(london, $0.coordinate) < NexradStation.distanceKm(london, $1.coordinate)
        }
        XCTAssertEqual(pick.stationID, expected?.id)
    }

    func testT17NoneReportingThenRecheck() async throws {
        let client = StubHTTP()
        client.stationInfo = try Fixture.data("awc-stationinfo-london")
        client.metar = Data("[]".utf8)
        let (store, clock, _) = try makeStore(client: client)
        let rawPick = await store.ensureStation(key: "london", near: london, isUS: false)
        let pick = try XCTUnwrap(rawPick)
        XCTAssertEqual(pick.verified, false)
        XCTAssertEqual(pick.verifiedRecheckAt, base.addingTimeInterval(6 * 3600))
        client.resetLog()
        clock.now = base.addingTimeInterval(6 * 3600 - 60)
        _ = await store.ensureStation(key: "london", near: london, isUS: false)
        XCTAssertTrue(client.urls.isEmpty)
        clock.now = base.addingTimeInterval(6 * 3600)
        client.metar = try Fixture.data("awc-metar-london-live")
        let rawAgain = await store.ensureStation(key: "london", near: london, isUS: false)
        let again = try XCTUnwrap(rawAgain)
        XCTAssertFalse(client.urls.isEmpty)
        XCTAssertEqual(again.verified, true)
        XCTAssertNil(again.verifiedRecheckAt)

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let legacyJSON = #"{"stationID":"EGLC","coordinate":{"latitude":51.5,"longitude":0.05},"distanceKm":3,"pickedAt":1700002800}"#
        let legacy = try dec.decode(MetarStationPick.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.verified)
        XCTAssertNil(legacy.verifiedRecheckAt)
        let closed = StubHTTP()
        closed.fail = true
        let now = base
        let seeded = BenchmarkStore(directory: try scratch(), client: closed, now: { now })
        await seeded.seedStation(legacy, key: "lon")
        let kept = await seeded.ensureStation(key: "lon", near: london, isUS: false)
        XCTAssertEqual(kept?.stationID, "EGLC")
        XCTAssertNil(kept?.verified)
        XCTAssertTrue(closed.urls.isEmpty)
    }

    func testT18DeadStationFallback() async throws {
        let client = StubHTTP()
        client.metar = Data("[]".utf8)
        let (store, _, dir) = try makeStore(client: client)
        let stale = MetarStationPick(stationID: "EGRB", name: "London Weather",
                                    coordinate: Coordinate(latitude: 51.521, longitude: -0.11),
                                    distanceKm: 1, pickedAt: base.addingTimeInterval(-2 * 86_400))
        await store.seedStation(stale, key: "london")
        _ = await store.fetchMetarsIfDue(for: "london")
        let cleared = await store.station(for: "london")
        XCTAssertNil(cleared)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let meta = try dec.decode([String: BenchmarkStore.Meta].self,
                                  from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        XCTAssertNotNil(meta["london"]?.deadStationIDs?["EGRB"])
        let global = try dec.decode(BenchmarkStore.GlobalMeta.self,
                                    from: Data(contentsOf: dir.appendingPathComponent("global.json")))
        XCTAssertFalse(global.knownStationIDs.contains("EGRB"))
        client.stationInfo = try Fixture.data("awc-stationinfo-london")
        client.metar = try Fixture.data("awc-metar-london-live")
        let rawNext = await store.ensureStation(key: "london", near: london, isUS: false)
        let next = try XCTUnwrap(rawNext)
        XCTAssertNotEqual(next.stationID, "EGRB")
        XCTAssertEqual(next.verified, true)
    }

    func testT19CacheRespected() async throws {
        let client = StubHTTP()
        client.stationInfo = try Fixture.data("awc-stationinfo-london")
        client.metar = try Fixture.data("awc-metar-london-live")
        let (store, clock, _) = try makeStore(client: client)
        let rawPick = await store.ensureStation(key: "london", near: london, isUS: false)
        let pick = try XCTUnwrap(rawPick)
        await store.seedMetars([
            MetarObservationRecord(loc: "london", stationID: pick.stationID, time: base,
                                   temperatureC: 11, windKmh: nil, wet: false)
        ])
        client.resetLog()
        _ = await store.ensureStation(key: "london", near: london, isUS: false)
        XCTAssertTrue(client.urls.isEmpty)
        clock.now = base.addingTimeInterval(6 * 86_400)
        _ = await store.ensureStation(key: "london", near: london, isUS: false)
        XCTAssertTrue(client.urls.isEmpty)
    }

    // MARK: M3 + regression

    func testT20StationPhrase() {
        XCTAssertTrue(AccuracyStationCopy.stationPhrase(isUS: true).contains("NWS"))
        let abroad = AccuracyStationCopy.stationPhrase(isUS: false)
        XCTAssertTrue(abroad.contains("METAR"))
        XCTAssertFalse(abroad.contains("only available in the US"))
        XCTAssertNil(AccuracyStationCopy.collectingUnavailableLine(isUS: false, benchmarkStationID: "EGLC"))
        let line = AccuracyStationCopy.collectingUnavailableLine(isUS: false, benchmarkStationID: nil)
        XCTAssertEqual(line, "No reporting weather station found near this city yet.")
        XCTAssertFalse(line?.contains("only available in the US") ?? true)
        XCTAssertNil(AccuracyStationCopy.collectingUnavailableLine(isUS: true, benchmarkStationID: nil))
    }

    /// 147 summaries.json has no pairedHourly. Load must fill it from hourly pairs already on disk.
    func testLoadBackfillsPairedHourlyFromExistingPairs() async throws {
        let now = base.addingTimeInterval(30 * 3600)
        let dir = try scratch()
        var pairs: [BenchmarkHourlyPair] = []
        for hour in 0..<24 {
            let valid = base.addingTimeInterval(Double(hour) * 3600)
            let issued = valid.addingTimeInterval(-2 * 3600)
            pairs.append(BenchmarkHourlyPair(loc: "london", issued: issued, valid: valid,
                                              kind: .skyline, forecastC: 10, observedC: 12))
            pairs.append(BenchmarkHourlyPair(loc: "london", issued: issued, valid: valid,
                                              kind: .metNorway, forecastC: 11, observedC: 12))
        }
        try writeJSONL(pairs, name: "hourly.jsonl", dir: dir)
        let legacy = """
        {"london":{"rows":[{"kind":"skyline","tempMAE":9,"n":24,"dailyN":0},{"kind":"met_norway","tempMAE":9,"n":24,"dailyN":0}],"metNorwayAttribution":"Data: MET Norway, CC BY 4.0"}}
        """
        try legacy.write(to: dir.appendingPathComponent("summaries.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(legacy.contains("pairedHourly"))

        let store = BenchmarkStore(directory: dir, client: ClosedHTTP(), now: { now })
        let loaded = await store.summary(for: "london")
        let summary = try XCTUnwrap(loaded)
        let paired = try XCTUnwrap(summary.pairedHourly)
        XCTAssertEqual(paired.n, 24)
        XCTAssertEqual(paired.kinds[.skyline], 2)
        XCTAssertEqual(paired.kinds[.metNorway], 1)
        XCTAssertNil(paired.kinds[.nws])

        let saved = try Data(contentsOf: dir.appendingPathComponent("summaries.json"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let onDisk = try dec.decode([String: BenchmarkSummary].self, from: saved)
        XCTAssertEqual(onDisk["london"]?.pairedHourly?.n, 24)
    }

    /// Trust PR pinned bias files against 5c2663e. The bias-copy plan allows one
    /// status-line edit in BiasCorrection.swift and nothing else in that file.
    func testT21NoBiasFilesInDiff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pin = "5c2663ed177cdf665c3090b4973a1377d5507c99"
        let changed = try git(["diff", "--name-only", pin], at: root)
        let untracked = try git(["ls-files", "--others", "--exclude-standard"], at: root)
        let diff = changed + untracked
        XCTAssertFalse(diff.contains("WeatherService.swift"), diff)
        let bias = try git(["diff", "--unified=0", "--no-color", pin, "--",
                            "Sources/SkylineCore/Verification/BiasCorrection.swift"], at: root)
        // Shallow CI checkouts may not contain the pin; git then prints nothing and the
        // name list stays empty. When the pin is present, only the status-line copy may differ.
        guard !bias.isEmpty || diff.contains("BiasCorrection.swift") else { return }
        let lines = bias.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        XCTAssertEqual(removed, [
            #"-        if let e = entry, e.autoOff { return "off: worse on recent days" }"#
        ])
        XCTAssertEqual(added, [
            #"+    /// Copy only. Mirrors evaluateAutoOff's re-enable rule (≥ autoOffReenableDays new scored days AND ≥ hysteresis better)."#,
            #"+    public static let autoOffLine = "paused: worse recently · rechecks after \(autoOffReenableDays)+ new days""#,
            #"+        if let e = entry, e.autoOff { return autoOffLine }"#
        ])
    }

    // MARK: Helpers

    private func makeStore(client: HTTPClient? = nil) throws -> (BenchmarkStore, Clock, URL) {
        let clock = Clock(base)
        let dir = try scratch()
        let store = BenchmarkStore(directory: dir, client: client ?? ClosedHTTP(), now: { clock.now })
        return (store, clock, dir)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func onHourHours(fetchedAt: Date, count: Int) -> [MetNorwayHour] {
        (1...count).map { i in
            MetNorwayHour(time: fetchedAt.addingTimeInterval(Double(i) * 3600), temperatureC: 10 + Double(i))
        }
    }

    private func writePending(_ rows: [MetPendingSample], dir: URL) throws {
        try writeJSONL(rows, name: "met-pending.jsonl", dir: dir)
    }

    private func writeJSONL<T: Encodable>(_ rows: [T], name: String, dir: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for row in rows {
            data.append(try enc.encode(row))
            data.append(0x0A)
        }
        try data.write(to: dir.appendingPathComponent(name))
    }

    private func pair(_ kind: BenchmarkForecastKind, valid: Date, leadH: Double, forecast: Double, obs: Double) -> BenchmarkHourlyPair {
        BenchmarkHourlyPair(loc: "L", issued: valid.addingTimeInterval(-leadH * 3600), valid: valid,
                            kind: kind, forecastC: forecast, observedC: obs)
    }

    private func intersectionPairs() -> [BenchmarkHourlyPair] {
        var pairs: [BenchmarkHourlyPair] = []
        func add(_ kind: BenchmarkForecastKind, hours: Range<Int>) {
            for hour in hours {
                let valid = base.addingTimeInterval(Double(hour) * 3600)
                pairs.append(pair(kind, valid: valid, leadH: 2, forecast: 10, obs: 12))
            }
        }
        add(.skyline, hours: 0..<30)
        add(.metNorway, hours: 10..<40)
        add(.nws, hours: 0..<30)
        return pairs
    }

    private func metOverlap(hours: Int) -> PairedHourly {
        var pairs: [BenchmarkHourlyPair] = []
        for hour in 0..<30 {
            let valid = base.addingTimeInterval(Double(hour) * 3600)
            pairs.append(pair(.skyline, valid: valid, leadH: 2, forecast: 10, obs: 11))
            if hour >= 30 - hours {
                pairs.append(pair(.metNorway, valid: valid, leadH: 2, forecast: 10, obs: 11))
            }
        }
        return BenchmarkScorer.pairedHourly(pairs, loc: "L")
    }

    private func git(_ args: [String], at root: URL) throws -> String {
        let proc = Process()
        proc.currentDirectoryURL = root
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class ClosedHTTP: HTTPClient, @unchecked Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

private final class StubHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    var stationInfo = Data("[]".utf8)
    var metar = Data("[]".utf8)
    var fail = false
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func resetLog() { lock.lock(); _urls = []; lock.unlock() }

    func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await fetch(url, headers: headers).data
    }

    func fetch(_ url: URL, headers: [String: String]) async throws -> HTTPFetchResult {
        let fail: Bool
        let stationInfo: Data
        let metar: Data
        lock.lock()
        _urls.append(url)
        fail = self.fail
        stationInfo = self.stationInfo
        metar = self.metar
        lock.unlock()
        if fail { throw URLError(.timedOut) }
        let s = url.absoluteString
        if s.contains("stationinfo") { return HTTPFetchResult(statusCode: 200, data: stationInfo) }
        if s.contains("metar") { return HTTPFetchResult(statusCode: 200, data: metar) }
        return HTTPFetchResult(statusCode: 404, data: Data())
    }
}
