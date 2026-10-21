import Foundation
import XCTest
@testable import SkylineCore

/// Plan §6 items 1–8, 11–13 (SkylineCore; no AppKit WeatherStore).
final class OpenMeteoQuotaTests: XCTestCase {
    let fixtureTime = Date(timeIntervalSince1970: 1_791_725_400)
    let nyc = WeatherLocation(name: "New York", region: "NY", country: "United States",
                              coordinate: Coordinate(latitude: 40.71, longitude: -74.01))
    let paris = WeatherLocation(name: "Paris", country: "France",
                                coordinate: Coordinate(latitude: 48.85, longitude: 2.35))
    let host = OpenMeteoQuota.forecastHost
    let aqHost = OpenMeteoQuota.airQualityHost

    private func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("skyline-omq-\(name)-\(UUID().uuidString)")
    }

    private func dailyBody() throws -> Data { try Fixture.data("om_daily_limit_429") }

    private func queryValues(_ url: URL, _ name: String) -> [String] {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value ?? ""
        return raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Open-Meteo `calculateQueryWeight`: v = (hourly+minutely+current+daily)×models; weight = max(1, max(v/10, v/10×days/14)).
    private func queryWeight(hourly: Int, minutely: Int, current: Int, daily: Int, models: Int, days: Int = 10) -> Double {
        let v = Double((hourly + minutely + current + daily) * models)
        return max(1, max(v / 10, v / 10 * Double(days) / 14))
    }

    private func omForecastGETCount(_ urls: [URL]) -> Int {
        urls.filter { $0.host?.lowercased() == host }.count
    }

    // MARK: §6.1 classify

    func testClassifyDailyLimitOnExactHosts() throws {
        let body = try dailyBody()
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: host, body: body), .dailyLimit)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: aqHost, body: body), .dailyLimit)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: host.uppercased(), body: body), .dailyLimit)
    }

    func testClassifyRejectsHourlyMinutelyNonJSON503Lookalike() throws {
        let daily = try dailyBody()
        let hourly = Data(#"{"error":true,"reason":"Hourly API request limit exceeded"}"#.utf8)
        let minutely = Data(#"{"error":true,"reason":"Minutely API request limit exceeded"}"#.utf8)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: host, body: hourly), .other)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: host, body: minutely), .other)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: host, body: Data("not-json".utf8)), .other)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 503, host: host, body: daily), .other)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: "api.open-meteo.com.evil", body: daily), .other)
        XCTAssertEqual(OpenMeteoQuota.classify(status: 429, host: nil, body: daily), .other)
    }

    // MARK: §6.2 until / marker / messages

    func testUntilInUTCWindowAtClocksIncludingDST() {
        var rng = SeededGenerator(seed: 42)
        let jitter = OpenMeteoQuota.drawJitter(using: &rng)
        XCTAssertGreaterThanOrEqual(jitter, 0)
        XCTAssertLessThanOrEqual(jitter, 180)

        // 23:59Z → next day 00:02–00:05Z
        let beforeMidnight = Date(timeIntervalSince1970: 1_704_067_140) // 2023-12-31 23:59:00 UTC
        let u1 = OpenMeteoQuota.until(after: beforeMidnight, jitter: jitter)
        assertUntilWindow(u1, after: beforeMidnight, jitter: jitter)

        // 00:00:30Z → same day if 00:02+jitter still ahead, else next day
        let justAfter = Date(timeIntervalSince1970: 1_704_067_230) // 2024-01-01 00:00:30 UTC
        let u2 = OpenMeteoQuota.until(after: justAfter, jitter: 0)
        XCTAssertEqual(u2, Date(timeIntervalSince1970: 1_704_067_320)) // 00:02:00Z

        // Midday
        let noon = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 12:00Z
        let u3 = OpenMeteoQuota.until(after: noon, jitter: 90)
        assertUntilWindow(u3, after: noon, jitter: 90)

        // US DST spring-forward local day (2026-03-08); until is still UTC-based.
        let dst = Date(timeIntervalSince1970: 1_773_057_600) // 2026-03-08 12:00 UTC
        let u4 = OpenMeteoQuota.until(after: dst, jitter: 120)
        assertUntilWindow(u4, after: dst, jitter: 120)
    }

    private func assertUntilWindow(_ until: Date, after now: Date, jitter: TimeInterval) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.startOfDay(for: now)
        let today = start.addingTimeInterval(120 + jitter)
        let expected = today > now ? today : start.addingTimeInterval(86400 + 120 + jitter)
        XCTAssertEqual(until, expected)
        let comps = cal.dateComponents([.hour, .minute, .second], from: until)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertGreaterThanOrEqual(comps.minute ?? 0, 2)
        XCTAssertLessThanOrEqual(comps.minute ?? 0, 5)
    }

    func testJitterSurvivesNewWeatherServiceSameCacheDir() async throws {
        let dir = tempDir("jitter")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: dir, now: { clock.now })
        let s1 = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        await s1.noteDailyLimit(host: host)
        let until1 = await s1.dailyLimit(for: host)
        XCTAssertNotNil(until1)

        let s2 = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: dir, now: { clock.now }),
                                now: { clock.now })
        // Trigger marker load via a limited fetch path.
        await s2.setDailyLimitForTesting(host, until: .distantPast) // will be overwritten by load
        // Clear in-memory and force reload: new service hasn't loaded yet.
        let s3 = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: dir, now: { clock.now }),
                                now: { clock.now })
        do {
            _ = try await s3.report(for: paris, allowNetwork: false)
        } catch {
            // Expected if no Paris cache yet — load still ran for the host on pair path.
        }
        // Re-load: ask for dailyLimit after touching OM via note on s1's marker.
        let entry = await ResponseCache(directory: dir, now: { clock.now })
            .entry(OpenMeteoQuota.markerKey(host: host), maxAge: .infinity)
        let marker = try XCTUnwrap(OpenMeteoQuota.decode(try XCTUnwrap(entry?.data)))
        XCTAssertEqual(marker.until, until1)
        XCTAssertGreaterThanOrEqual(marker.jitter, 0)
        XCTAssertLessThanOrEqual(marker.jitter, 180)

        // Second service on same dir sees the same until after a report that loads the marker.
        let client = MockHTTPClient()
        let s4 = WeatherService(client: client, cache: ResponseCache(directory: dir, now: { clock.now }),
                                now: { clock.now })
        // Prime NYC cache first without limit, then reload limited service.
        let seedCache = ResponseCache(directory: dir, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: seedCache, now: { clock.now })
        await seeder.clearDailyLimit(host: host)
        _ = try await seeder.report(for: nyc)
        await seeder.noteDailyLimit(host: host)
        let untilSeeded = await seeder.dailyLimit(for: host)

        let s5 = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: dir, now: { clock.now }),
                                now: { clock.now })
        _ = try? await s5.report(for: nyc, allowNetwork: false)
        XCTAssertEqual(await s5.dailyLimit(for: host), untilSeeded)
    }

    func testMarkerSanityAndClearOn200() async throws {
        let now = fixtureTime
        let sane = OpenMeteoQuota.Marker(until: now.addingTimeInterval(3600), lastProbeAt: now, jitter: 10)
        XCTAssertTrue(OpenMeteoQuota.isSane(sane, now: now))
        XCTAssertFalse(OpenMeteoQuota.isSane(
            OpenMeteoQuota.Marker(until: now.addingTimeInterval(-1), lastProbeAt: now, jitter: 0), now: now))
        XCTAssertFalse(OpenMeteoQuota.isSane(
            OpenMeteoQuota.Marker(until: now.addingTimeInterval(OpenMeteoQuota.sanityHorizon + 1),
                                  lastProbeAt: now, jitter: 0), now: now))

        let dir = tempDir("sane")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(now)
        let cache = ResponseCache(directory: dir, now: { clock.now })
        // Past until — discarded on load.
        let past = OpenMeteoQuota.Marker(until: now.addingTimeInterval(-60), lastProbeAt: now, jitter: 5)
        await cache.store(try OpenMeteoQuota.encode(past), for: OpenMeteoQuota.markerKey(host: host))
        let s = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await s.report(for: nyc)
        XCTAssertNil(await s.dailyLimit(for: host))

        // Far-future until — discarded.
        let far = OpenMeteoQuota.Marker(until: now.addingTimeInterval(OpenMeteoQuota.sanityHorizon + 120),
                                        lastProbeAt: now, jitter: 5)
        await cache.store(try OpenMeteoQuota.encode(far), for: OpenMeteoQuota.markerKey(host: host))
        let s2 = WeatherService(client: MockHTTPClient(), cache: ResponseCache(directory: dir, now: { clock.now }),
                                now: { clock.now })
        _ = try await s2.report(for: nyc)
        XCTAssertNil(await s2.dailyLimit(for: host))

        // 200 clears an active limit.
        await s2.noteDailyLimit(host: host)
        XCTAssertNotNil(await s2.dailyLimit(for: host))
        // Advance past until so mayProbe allows, then successful GET clears.
        clock.now = (await s2.dailyLimit(for: host))!.addingTimeInterval(1)
        _ = try await s2.report(for: nyc, forceRefresh: true)
        XCTAssertNil(await s2.dailyLimit(for: host))
    }

    func testResumePhraseAmericaNewYorkAndTokyoTomorrow() {
        let ny = TimeZone(identifier: "America/New_York")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let locale = Locale(identifier: "en_US_POSIX")

        // Same local day in NY: evening until while still afternoon.
        let nowNY = Date(timeIntervalSince1970: 1_729_520_400) // 2024-10-21 17:00 EDT
        let untilSameDay = Date(timeIntervalSince1970: 1_729_531_500) // 20:05 EDT same day
        let same = OpenMeteoQuota.resumePhrase(until: untilSameDay, now: nowNY, timeZone: ny, locale: locale)
        XCTAssertFalse(same.lowercased().contains("tomorrow"))
        XCTAssertEqual(same, UserFacingError.clockTime(untilSameDay, timeZone: ny, locale: locale, roundUp: false))

        // Tokyo: late evening now, until is next UTC morning → next local calendar day.
        let nowTokyo = Date(timeIntervalSince1970: 1_729_533_600) // 2024-10-22 06:00 JST
        let untilNext = Date(timeIntervalSince1970: 1_729_585_500) // 2024-10-22 20:25 JST? pick carefully
        // Use until clearly on the next Tokyo day.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tokyo
        let start = cal.startOfDay(for: nowTokyo)
        let untilTomorrow = start.addingTimeInterval(86400 + 5 * 3600) // 05:00 next local day
        let phrase = OpenMeteoQuota.resumePhrase(until: untilTomorrow, now: nowTokyo, timeZone: tokyo, locale: locale)
        XCTAssertTrue(phrase.lowercased().hasPrefix("tomorrow"), phrase)
        let timeOnly = UserFacingError.clockTime(untilTomorrow, timeZone: tokyo, locale: locale, roundUp: false)
        XCTAssertTrue(phrase.contains(timeOnly))

        let msg = OpenMeteoQuota.nwsOnlyMessage(until: untilSameDay, now: nowNY, timeZone: ny, locale: locale)
        XCTAssertTrue(msg.hasPrefix(OpenMeteoQuota.messagePrefix))
        XCTAssertTrue(msg.contains("National Weather Service"))
    }

    // MARK: §6.3 probe / force while limited

    func testWhileLimitedProbeOnlyWhenDueAndForceHitsZeroOM() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let inner = MockHTTPClient()
        // Seed a live pair + NWS so limited paths have fallback / NWS-only material.
        let seeder = WeatherService(client: inner, cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)

        let recording = RecordingHTTPClient { url in try await inner.get(url, headers: [:]) }
        let service = WeatherService(client: recording, cache: cache, now: { clock.now })
        let until = clock.now.addingTimeInterval(6 * 3600)
        await service.setDailyLimitForTesting(host, until: until, lastProbeAt: clock.now, jitter: 0)
        // nextProbeAt = now + 60 min — not due yet.
        recording.resetURLs()
        let limited = try await service.report(for: nyc)
        XCTAssertTrue(limited.isOfflineFallback || limited.fallbackCause == .dailyLimit
                      || limited.forecastMode == .nwsOnly || limited.forecastMode == .blend)
        XCTAssertEqual(omForecastGETCount(recording.urls), 0, "no OM while limited before probe")

        // ⌘R / force while limited → 0 OM GETs (does not consume the probe).
        recording.resetURLs()
        _ = try await service.report(for: nyc, forceRefresh: true)
        XCTAssertEqual(omForecastGETCount(recording.urls), 0)

        // Advance to probe time: one pair attempt is allowed (A then possibly B).
        clock.now = clock.now.addingTimeInterval(OpenMeteoQuota.probeInterval)
        recording.resetURLs()
        _ = try await service.report(for: nyc)
        let probeOM = omForecastGETCount(recording.urls)
        XCTAssertGreaterThan(probeOM, 0, "probe when nextProbeAt due")
        XCTAssertLessThanOrEqual(probeOM, 2, "one A+B pair at most per probe")

        // Sixteen cities while limited and probe not due → still 0 OM (retry owner alone would probe when due).
        clock.now = fixtureTime
        await service.setDailyLimitForTesting(host, until: until, lastProbeAt: clock.now, jitter: 0)
        recording.resetURLs()
        var cities: [WeatherLocation] = [nyc]
        for i in 1..<16 {
            cities.append(WeatherLocation(name: "C\(i)", country: "United States",
                                          coordinate: Coordinate(latitude: 40.0 + Double(i) * 0.05,
                                                                 longitude: -74.0)))
        }
        for c in cities {
            _ = try? await service.report(for: c)
        }
        XCTAssertEqual(omForecastGETCount(recording.urls), 0, "no OM for any city before probe hour")
    }

    // MARK: §6.4 persistQuotaMarker:false

    func testPersistQuotaMarkerFalseWritesNoMarkerAndNewServiceResumes() async throws {
        let dir = tempDir("hook")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: dir, now: { clock.now })
        let body = try dailyBody()
        let recording = RecordingHTTPClient { url in
            if url.host?.lowercased() == OpenMeteoQuota.forecastHost
                || url.host?.lowercased() == OpenMeteoQuota.airQualityHost {
                if OpenMeteoQuota.classify(status: 429, host: url.host, body: body) == .dailyLimit {
                    throw HTTPError.dailyLimit(host: url.host ?? "")
                }
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let limited = WeatherService(client: recording, cache: cache, persistQuotaMarker: false, now: { clock.now })
        await limited.noteDailyLimit(host: host)
        let markerEntry = await cache.entry(OpenMeteoQuota.markerKey(host: host), maxAge: .infinity)
        XCTAssertNil(markerEntry, "hook mode writes no marker")

        let fresh = WeatherService(client: MockHTTPClient(),
                                   cache: ResponseCache(directory: dir, now: { clock.now }),
                                   now: { clock.now })
        XCTAssertNil(await fresh.dailyLimit(for: host))
        let report = try await fresh.report(for: nyc)
        XCTAssertEqual(report.forecastMode, .blend)
        XCTAssertFalse(report.isOfflineFallback)
    }

    // MARK: §6.5 NWS-only US

    func testNWSOnlyUSNoCacheNoHistoryNoCorrection() async throws {
        let clock = TestClock(fixtureTime)
        let body = try dailyBody()
        let recording = RecordingHTTPClient { url in
            let h = url.host?.lowercased() ?? ""
            if OpenMeteoQuota.exactHosts.contains(h) {
                throw HTTPError.dailyLimit(host: h)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let histDir = tempDir("hist-empty")
        defer { try? FileManager.default.removeItem(at: histDir) }
        let history = ForecastHistory(directory: histDir)
        let vDir = tempDir("v-nws")
        defer { try? FileManager.default.removeItem(at: vDir) }
        let verifier = ForecastVerifier(directory: vDir, client: recording, now: { clock.now },
                                        launchArguments: ["Skyline", "-SkylineCorrectionQAOverride", "1.0"])
        XCTAssertTrue(verifier.isQAOverrideActive)

        let service = WeatherService(client: recording, cache: ResponseCache(directory: nil, now: { clock.now }),
                                     verifier: verifier, history: history, now: { clock.now })
        await service.setDailyLimitForTesting(host, until: clock.now.addingTimeInterval(3600), lastProbeAt: clock.now)

        let report = try await service.report(for: nyc)
        XCTAssertEqual(report.forecastMode, .nwsOnly)
        XCTAssertEqual(report.fallbackCause, .dailyLimit)
        XCTAssertFalse(report.isOfflineFallback)
        XCTAssertTrue(report.sources.allSatisfy { $0.hasPrefix("NWS") })
        XCTAssertEqual(await history.count(VerificationKey.key(for: nyc)), 0)

        // Same path without QA override — temperatures match (correction never applied in NWS-only).
        let v2 = ForecastVerifier(directory: tempDir("v-nws2"), client: recording, now: { clock.now },
                                  launchArguments: ["Skyline"])
        let s2 = WeatherService(client: recording, cache: ResponseCache(directory: nil, now: { clock.now }),
                                verifier: v2, now: { clock.now })
        await s2.setDailyLimitForTesting(host, until: clock.now.addingTimeInterval(3600), lastProbeAt: clock.now)
        let r2 = try await s2.report(for: nyc)
        XCTAssertEqual(report.current.temperature, r2.current.temperature, accuracy: 1e-9)
        _ = body
    }

    // MARK: §6.6 Non-US Paris

    func testNonUSParisCachedFallbackAndNoCacheThrows() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let live = try await seeder.report(for: paris)
        XCTAssertEqual(live.forecastMode, .blend)

        let body = try dailyBody()
        let recording = RecordingHTTPClient { url in
            if OpenMeteoQuota.exactHosts.contains(url.host?.lowercased() ?? "") {
                throw HTTPError.dailyLimit(host: url.host ?? "")
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let service = WeatherService(client: recording, cache: cache, now: { clock.now })
        await service.setDailyLimitForTesting(host, until: clock.now.addingTimeInterval(7200), lastProbeAt: clock.now)
        // Age the pair past TTL so the limited path returns fallback (not a fresh hit).
        clock.now = clock.now.addingTimeInterval(WeatherService.TTL.forecast + 60)
        let fallback = try await service.report(for: paris)
        XCTAssertTrue(fallback.isOfflineFallback)
        XCTAssertEqual(fallback.fallbackCause, .dailyLimit)
        XCTAssertFalse(RefreshBookkeeping.isReallyOffline(cause: fallback.fallbackCause, error: nil))
        let until = try XCTUnwrap(await service.dailyLimit(for: host))
        let msg = OpenMeteoQuota.cachedMessage(dataTime: fallback.dataAsOf, until: until, now: clock.now,
                                               timeZone: TimeZone(identifier: "Europe/Paris")!,
                                               locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(msg.hasPrefix(OpenMeteoQuota.messagePrefix))
        XCTAssertTrue(msg.contains("showing data from"))

        // No cache → throws dailyLimit.
        let empty = WeatherService(client: recording, cache: ResponseCache(directory: nil, now: { clock.now }),
                                   now: { clock.now })
        await empty.setDailyLimitForTesting(host, until: clock.now.addingTimeInterval(7200), lastProbeAt: clock.now)
        do {
            _ = try await empty.report(for: paris)
            XCTFail("expected dailyLimit throw")
        } catch let e as HTTPError {
            guard case .dailyLimit = e else { return XCTFail("\(e)") }
            let noData = OpenMeteoQuota.noDataMessage(until: until, now: clock.now,
                                                      timeZone: TimeZone(identifier: "Europe/Paris")!)
            XCTAssertTrue(noData.contains("try again after") || noData.contains("Skyline will try again"))
        }
    }

    // MARK: §6.7 Pair consistency M1

    func testPairConsistencyAPastTTLBFreshRefetchesBoth() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let urlB = Endpoints.openMeteoForecastB(coord)
        let full = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let halves = full.splitPairHalves()
        await cache.store(try OpenMeteoResponse.encode(halves.a), for: urlA.absoluteString)
        clock.now = clock.now.addingTimeInterval(WeatherService.TTL.forecast + 30)
        await cache.store(try OpenMeteoResponse.encode(halves.b), for: urlB.absoluteString)

        let recording = RecordingHTTPClient { url in try await MockHTTPClient().get(url, headers: [:]) }
        let service = WeatherService(client: recording, cache: cache, now: { clock.now })
        _ = try await service.report(for: nyc)
        let om = recording.openMeteoForecastURLs
        XCTAssertTrue(om.contains { $0.absoluteString == urlA.absoluteString })
        XCTAssertTrue(om.contains { $0.absoluteString == urlB.absoluteString })
    }

    func testPairConsistencyA2xxBFailKeepsCachedPairAndDoesNotCacheA() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        _ = try await seeder.report(for: nyc)
        let coord = nyc.coordinate.rounded
        let models = ForecastModel.models(inCONUS: true)
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let urlB = Endpoints.openMeteoForecastB(coord)
        let beforeA = await cache.entry(urlA.absoluteString, maxAge: .infinity)

        clock.now = clock.now.addingTimeInterval(WeatherService.TTL.forecast + 10)
        let recording = RecordingHTTPClient { url in
            let s = url.absoluteString
            if s.contains("minutely_15") || (s.contains("models=best_match") && !s.contains("models=best_match,")) {
                throw URLError(.timedOut)
            }
            return try await MockHTTPClient().get(url, headers: [:])
        }
        let service = WeatherService(client: recording, cache: cache, now: { clock.now })
        let report = try await service.report(for: nyc)
        XCTAssertTrue(report.isOfflineFallback)
        let afterA = await cache.entry(urlA.absoluteString, maxAge: .infinity)
        XCTAssertEqual(afterA?.storedAt, beforeA?.storedAt, "fresh A must not be newly cached when B fails")
    }

    func testPairConsistencyMismatchIsPairMiss() throws {
        let full = try OpenMeteoResponse.decode(Fixture.data("om_nyc"))
        let halves = full.splitPairHalves()
        let t0 = fixtureTime
        XCTAssertTrue(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t0, halves.b, storedAtB: t0))
        XCTAssertFalse(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t0,
                                                         halves.b, storedAtB: t0.addingTimeInterval(121)))
        var badTZ = halves.b
        badTZ.timezone = "Europe/Paris"
        XCTAssertFalse(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t0, badTZ, storedAtB: t0))
        var badOffset = halves.b
        badOffset.utcOffsetSeconds = 0
        XCTAssertFalse(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t0, badOffset, storedAtB: t0))
        var badTime = halves.b
        if var hourly = badTime.hourly, let times = hourly["time"], !times.isEmpty {
            hourly["time"] = times.map { $0.map { $0 + 3600 } }
            badTime.hourly = hourly
        }
        XCTAssertFalse(OpenMeteoResponse.pairConsistent(halves.a, storedAtA: t0, badTime, storedAtB: t0))
    }

    func testPairFallbackFlagsAndHistorySkipped() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let seeder = WeatherService(client: MockHTTPClient(), cache: cache, now: { clock.now })
        let live = try await seeder.report(for: nyc)
        let liveAsOf = live.forecastAsOf

        let histDir = tempDir("hist-fb")
        defer { try? FileManager.default.removeItem(at: histDir) }
        let history = ForecastHistory(directory: histDir)
        clock.now = clock.now.addingTimeInterval(3600)
        let offline = MockHTTPClient()
        offline.offline = true
        let service = WeatherService(client: offline, cache: cache, history: history, now: { clock.now })
        let report = try await service.report(for: nyc)
        XCTAssertTrue(report.isOfflineFallback)
        XCTAssertEqual(report.forecastAsOf, liveAsOf)
        XCTAssertEqual(report.dataAsOf, min(liveAsOf ?? report.dataAsOf, report.dataAsOf))
        // history.record skipped on fallback
        XCTAssertEqual(await history.count(VerificationKey.key(for: nyc)), 0)
    }

    // MARK: §6.8 Merge M2

    func testMergePairTakesGeoFromAWhenBDiffers() throws {
        for name in ["om_nyc", "om_paris", "om_fairfield"] {
            let full = try OpenMeteoResponse.decode(Fixture.data(name))
            let halves = full.splitPairHalves()
            XCTAssertNotEqual(halves.a.latitude, halves.b.latitude)
            let merged = OpenMeteoResponse.mergePair(a: halves.a, b: halves.b)
            XCTAssertEqual(merged.latitude, halves.a.latitude)
            XCTAssertEqual(merged.longitude, halves.a.longitude)
            XCTAssertEqual(merged.elevation, halves.a.elevation)
            XCTAssertEqual(merged.timezone, halves.a.timezone)
            XCTAssertEqual(merged.utcOffsetSeconds, halves.a.utcOffsetSeconds)
            XCTAssertEqual(merged.current?.temperature_2m, halves.b.current?.temperature_2m)
            XCTAssertNotNil(merged.minutely15)
        }
    }

    // MARK: §6.11 Request URLs + weight

    func testRequestURLsAndWeights() {
        let coord = Coordinate(latitude: 40.71, longitude: -74.01)
        let aUS = Endpoints.openMeteoForecastA(coord, models: ForecastModel.models(inCONUS: true))
        let aWorld = Endpoints.openMeteoForecastA(coord, models: ForecastModel.models(inCONUS: false))
        let b = Endpoints.openMeteoForecastB(coord)

        XCTAssertEqual(queryValues(aUS, "hourly").count, 13)
        XCTAssertEqual(queryValues(aUS, "daily").count, 7)
        XCTAssertEqual(queryValues(aUS, "models").count, 5)
        XCTAssertNil(URLComponents(url: aUS, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "current" })
        XCTAssertNil(URLComponents(url: aUS, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "minutely_15" })

        XCTAssertEqual(queryValues(b, "current").count, 14)
        XCTAssertEqual(queryValues(b, "hourly").count, 2)
        XCTAssertEqual(queryValues(b, "daily").count, 5)
        XCTAssertEqual(queryValues(b, "minutely_15"), ["precipitation"])
        XCTAssertEqual(queryValues(b, "models"), ["best_match"])

        let wAUS = queryWeight(hourly: 13, minutely: 0, current: 0, daily: 7, models: 5)
        let wAWorld = queryWeight(hourly: 13, minutely: 0, current: 0, daily: 7, models: 4)
        let wB = queryWeight(hourly: 2, minutely: 1, current: 14, daily: 5, models: 1)
        XCTAssertEqual(wAUS + wB, 12.2, accuracy: 1e-9)
        XCTAssertEqual(wAWorld + wB, 10.2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(wAUS + wB, 12.2)
        XCTAssertLessThanOrEqual(wAWorld + wB, 10.2)
        _ = aWorld
    }

    // MARK: §6.12 Split / merge / golden / best_match nulls

    func testSplitMergeEqualsSingleResponseBlendAndGolden() async throws {
        let nwsPeriods = try NWSPeriod.decodeList(Fixture.data("nws_forecast"))
        let nwsHourly = try NWSPeriod.decodeList(Fixture.data("nws_hourly"))

        for name in ["om_nyc", "om_paris", "om_fairfield"] {
            let full = try OpenMeteoResponse.decode(Fixture.data(name))
            let halves = full.splitPairHalves()
            let merged = OpenMeteoResponse.mergePair(a: halves.a, b: halves.b)

            // best_match B fields: no nulls
            for key in OpenMeteoResponse.pairHourlyFromB {
                let col = try XCTUnwrap(merged.hourlyColumn(key, model: .bestMatch))
                XCTAssertFalse(col.contains { $0 == nil }, "\(name) hourly \(key)")
            }
            for key in OpenMeteoResponse.pairDailyFromB {
                let col = try XCTUnwrap(merged.dailyColumn(key, model: .bestMatch))
                XCTAssertFalse(col.contains { $0 == nil }, "\(name) daily \(key)")
            }

            guard let current = merged.currentConditions() else {
                XCTFail("current"); continue
            }
            let tz = TimeZone(identifier: merged.timezone) ?? .gmt
            let nwsP = name == "om_fairfield" ? try NWSPeriod.decodeList(Fixture.data("nws_fairfield_forecast")) : nwsPeriods
            let hourlyMerged = ForecastBlender.blendHourly(openMeteo: merged, nwsHourly: nwsHourly, now: current.time)
            let dailyMerged = ForecastBlender.blendDaily(openMeteo: merged, nwsPeriods: nwsP, timeZone: tz,
                                                         hourly: hourlyMerged)
            let hourlyFull = ForecastBlender.blendHourly(openMeteo: full, nwsHourly: nwsHourly, now: current.time)
            let dailyFull = ForecastBlender.blendDaily(openMeteo: full, nwsPeriods: nwsP, timeZone: tz,
                                                       hourly: hourlyFull)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try enc.encode(hourlyMerged), try enc.encode(hourlyFull), name)
            XCTAssertEqual(try enc.encode(dailyMerged), try enc.encode(dailyFull), name)

            let seriesM = ForecastBlender.modelSeries(openMeteo: merged, nwsHourly: nwsHourly, blended: hourlyMerged,
                                                      now: current.time)
            let seriesF = ForecastBlender.modelSeries(openMeteo: full, nwsHourly: nwsHourly, blended: hourlyFull,
                                                      now: current.time)
            XCTAssertEqual(try enc.encode(seriesM), try enc.encode(seriesF), name)

            let recM = ForecastSampler.records(location: "k", issued: fixtureTime, openMeteo: merged,
                                               nwsHourly: nwsHourly, blended: hourlyMerged)
            let recF = ForecastSampler.records(location: "k", issued: fixtureTime, openMeteo: full,
                                               nwsHourly: nwsHourly, blended: hourlyFull)
            XCTAssertEqual(try enc.encode(recM), try enc.encode(recF), name)
            let issuesM = ForecastSampler.dailyIssues(location: "k", issued: fixtureTime, daily: dailyMerged,
                                                      openMeteo: merged, timeZone: tz, blendedHourly: hourlyMerged)
            let issuesF = ForecastSampler.dailyIssues(location: "k", issued: fixtureTime, daily: dailyFull,
                                                      openMeteo: full, timeZone: tz, blendedHourly: hourlyFull)
            XCTAssertEqual(try enc.encode(issuesM), try enc.encode(issuesF), name)
        }

        // golden_report_pr1 still matches a live NYC report (no correction applied below gate).
        let clock = TestClock(fixtureTime)
        let dir = tempDir("golden")
        defer { try? FileManager.default.removeItem(at: dir) }
        UserDefaults.standard.set(false, forKey: AccuracyMeasurement.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey) }
        let client = MockHTTPClient()
        let svc = WeatherService(client: client, cache: ResponseCache(directory: nil, now: { clock.now }),
                                 verifier: ForecastVerifier(directory: dir, client: client, now: { clock.now }),
                                 now: { clock.now })
        let report = try await svc.report(for: nyc)
        let w = await svc.verifier!.weights(VerificationKey.key(for: nyc))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        struct Slice: Codable {
            var hourly: Data; var daily: Data; var current: Data; var modelSeries: Data; var weights: Data
        }
        let golden = try JSONDecoder().decode(Slice.self, from: Fixture.data("golden_report_pr1_362a5d4"))
        XCTAssertEqual(try enc.encode(report.hourly), golden.hourly)
        XCTAssertEqual(try enc.encode(report.daily), golden.daily)
        XCTAssertEqual(try enc.encode(report.current), golden.current)
        XCTAssertEqual(try enc.encode(report.modelSeries), golden.modelSeries)
        XCTAssertEqual(try enc.encode(w), golden.weights)
    }

    // MARK: §6.13 Accuracy guard

    func testAccuracyGuardCachedOrFallbackSkipsIssuanceAndEmptyMeasurement() async throws {
        let clock = TestClock(fixtureTime)
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let dirFresh = tempDir("acc-fresh")
        let dirStale = tempDir("acc-stale")
        defer {
            try? FileManager.default.removeItem(at: dirFresh)
            try? FileManager.default.removeItem(at: dirStale)
        }
        UserDefaults.standard.set(true, forKey: AccuracyMeasurement.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AccuracyMeasurement.defaultsKey) }

        let client = MockHTTPClient()
        let vFresh = ForecastVerifier(directory: dirFresh, client: client, now: { clock.now })
        let sFresh = WeatherService(client: client, cache: cache, verifier: vFresh, now: { clock.now })
        _ = try await sFresh.report(for: nyc)
        try await Task.sleep(for: .milliseconds(400))
        let pendingFresh = dirFresh.appendingPathComponent("pending.jsonl")
        // Fresh pair may record issuance when wantsIssuance; either way measurement ran with non-empty daily.
        // Stale fallback path:
        clock.now = clock.now.addingTimeInterval(3600)
        let offline = MockHTTPClient()
        offline.offline = true
        let vStale = ForecastVerifier(directory: dirStale, client: offline, now: { clock.now })
        let sStale = WeatherService(client: offline, cache: cache, verifier: vStale, now: { clock.now })
        XCTAssertTrue(await vStale.wantsIssuance(VerificationKey.key(for: nyc)))
        _ = try await sStale.report(for: nyc)
        try await Task.sleep(for: .milliseconds(400))
        let pendingStale = dirStale.appendingPathComponent("pending.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingStale.path),
                       "fallback pair must not call verifier.record")
        // Indirect: issuanceOK false → empty daily/blended into runMeasurement → no daily-issues stamped "now".
        let bench = BenchmarkStore.directoryAlongside(verification: dirStale)
        let issuesPath = bench.appendingPathComponent("daily-issues.jsonl")
        if FileManager.default.fileExists(atPath: issuesPath.path),
           let data = try? Data(contentsOf: issuesPath), !data.isEmpty {
            // Empty daily → dailyIssues returns []; store may still exist from other writes — prefer empty.
            let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
            XCTAssertTrue(lines.isEmpty, "runMeasurement should get empty daily on fallback")
        }
        _ = pendingFresh
    }
}

/// Deterministic RNG for jitter window tests.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x4d595df4d0f33173 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
