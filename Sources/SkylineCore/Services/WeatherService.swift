import Foundation

/// Fetches, caches and blends weather for a location. Thread-safe (actor); de-duplicates
/// concurrent requests for the same location (e.g. menu bar + main window).
/// Item 2: who is waiting for an Open-Meteo turn. A city with nothing on screen yet and a forced
/// Retry are interactive; scheduled and background refreshes are not.
public enum FetchPriority: Sendable, Equatable { case interactive, background }

public actor WeatherService {
    /// Cache lifetimes. Forecast data only changes when models run, so ~10 min is plenty.
    public enum TTL {
        public static let forecast: TimeInterval = 10 * 60
        /// Background cities (not viewed / menu-bar / notify): longer OM + AQ cache. Single constant
        /// for AQ background TTL, background stale (+15 min), RefreshPlanner, tests and QA (Decision 2: 3 h).
        public static let background: TimeInterval = 10_800
        /// Decision 2 L: while cached multi-model A is younger than this, background refreshes send B only.
        public static let blendMaxAge: TimeInterval = 43_200
        /// Decision 2 N: while the window is hidden, notify cities reuse the OM pair up to this age.
        public static let notifyReuseHidden: TimeInterval = 1_800
        public static let nwsForecast: TimeInterval = 15 * 60
        public static let alerts: TimeInterval = 5 * 60
        public static let nwsPoint: TimeInterval = 7 * 24 * 3600
        public static let airQuality: TimeInterval = 30 * 60
        public static let geocoding: TimeInterval = 30 * 24 * 3600
        public static let radarIndex: TimeInterval = 2 * 60
        /// The forecast office's discussion list (new ones come out a few times a day).
        public static let afdList: TimeInterval = 30 * 60
        /// A text product never changes once issued.
        public static let product: TimeInterval = 7 * 86400
        /// A point NWS answered 404 for (outside its grids: Canadian border towns, offshore) isn't asked
        /// again for a day. Before, a failure wasn't cached, so it was re-requested on every refresh.
        public static let nwsMissing: TimeInterval = 24 * 3600 // a day: a one-off NWS hiccup heals soon (CR batch 6)
        /// SPC updates its outlooks a handful of times a day; one file serves every US city.
        public static let spcOutlook: TimeInterval = 30 * 60
        public static let hrrrRun: TimeInterval = 10 * 60
        /// Storm-attribute GeoJSON (~2 min poll while radar is visible).
        public static let stormAttr: TimeInterval = 2 * 60
    }

    /// The oldest cached copy that may stand in when the network fails ("offline fallback").
    /// Older than this, the data is too old to show as weather and the request fails instead.
    public enum MaxStale {
        public static let forecast: TimeInterval = 12 * 3600
        public static let nwsForecast: TimeInterval = NWSPeriod.maxForecastAge
        public static let alerts: TimeInterval = 1 * 3600
        public static let airQuality: TimeInterval = 6 * 3600
    }

    /// A response plus when it was actually downloaded, and whether it is an offline fallback.
    struct Fetched: Sendable {
        var data: Data
        var storedAt: Date
        var isFallback: Bool
        /// Why the stale copy was used.
        var cause: FallbackCause? = nil
    }

    /// Merged Open-Meteo A+B pair (CR M1).
    struct OpenMeteoPairResult: Sendable {
        var response: OpenMeteoResponse
        /// Pair age / dataAsOf / forecastAsOf. For a B-only refresh this is B's storedAt (Decision 2).
        var storedAt: Date
        var isFallback: Bool
        var cause: FallbackCause?
        var halfA: Fetched
        var halfB: Fetched
        /// Decision 2 L: B refreshed while A was reused (no issuance / accuracy sample).
        var isBOnly: Bool = false
        /// Decision 2 L fallback: A refetch failed; display is single-model B only.
        var isSingleModelB: Bool = false
    }

    /// Pause before the one immediate re-try of a GET that died in flight (`FallbackCause.retriesOnce`).
    private var transientRetryDelay: TimeInterval = 0.5
    func setTransientRetryDelay(_ seconds: TimeInterval) { transientRetryDelay = seconds }

    private let client: HTTPClient
    private let cache: ResponseCache
    private let now: @Sendable () -> Date
    /// When false (QA hook), never write the `om-daily-limit:<host>` ResponseCache marker.
    private let persistQuotaMarker: Bool
    private var inFlight: [String: Task<WeatherReport, Error>] = [:]
    /// Hosts that answered 429/503: no requests to them until this time (Retry-After, else 1 → 2 → 4 … min).
    private var backoffUntil: [String: Date] = [:]
    private var backoffStrikes: [String: Int] = [:]
    /// Bumped each time a host throttles us. A success only clears the back-off if no throttle was noted
    /// while it was in flight: NWS requests run concurrently, and a slower success must not cancel a 503
    /// that arrived meanwhile (QA batch 2).
    private var throttleEpoch: [String: Int] = [:]
    /// Free-tier daily limit resume time (separate from `backoffUntil`).
    private var dailyLimitUntil: [String: Date] = [:]
    private var nextProbeAt: [String: Date] = [:]
    private var dailyLimitJitter: [String: TimeInterval] = [:]
    private var dailyLimitLoaded: Set<String> = []
    /// The pause a forced refresh uses to wait out a short Retry-After. Production sleeps; tests that
    /// drive `now` jump their clock by the same interval so the suite doesn't wait on the wall clock.
    private var backoffSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// One Open-Meteo forecast GET at a time, so a shared back-off ending doesn't stampede the host.
    private var openMeteoBusy = false
    /// Item 2: interactive turns (a city with nothing on screen yet, a forced Retry) go ahead of
    /// queued background refreshes; FIFO within each class. Still one GET at a time.
    private var openMeteoWaiters: [(priority: FetchPriority, key: String?, cont: CheckedContinuation<Void, Never>)] = []
    /// Follow-up M1: priority of each shared GET, so a new city joining a background one promotes it.
    private var inFlightPriority: [String: FetchPriority] = [:]
    /// Item 2: one network GET per URL; a second caller (add + sync apply + refresh) joins it.
    private var inFlightGets: [String: Task<Fetched, Error>] = [:]
    /// One in-flight OM A+B pair per forecast-A URL key (same coordinate under different city ids joins).
    private var inFlightPairGets: [String: Task<OpenMeteoPairResult, Error>] = [:]
    /// Forecast verification + adaptive weights (nil = fixed weights, nothing recorded; used by tests).
    public nonisolated let verifier: ForecastVerifier?
    /// Recent daily-forecast snapshots for "why the forecast changed" (nil = none kept; used by tests).
    public nonisolated let history: ForecastHistory?

    public init(client: HTTPClient = URLSessionHTTPClient(),
                cache: ResponseCache = ResponseCache(directory: ResponseCache.defaultDirectory()),
                verifier: ForecastVerifier? = nil,
                history: ForecastHistory? = nil,
                persistQuotaMarker: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.cache = cache
        self.verifier = verifier
        self.history = history
        self.persistQuotaMarker = persistQuotaMarker
        self.now = now
    }

    // MARK: Public API

    public func report(for location: WeatherLocation, forceRefresh: Bool = false,
                       priority: FetchPriority = .background,
                       allowNetwork: Bool? = nil,
                       role: RefreshPlanner.Role? = nil,
                       windowVisible: Bool = true,
                       isNotifyCity: Bool = false) async throws -> WeatherReport {
        // The coordinate is part of the key: My Location keeps its id while it moves, and a second fix
        // during a slow load must not get the old place's report (QA #13).
        let netTag: String = {
            switch allowNetwork {
            case .none: return ""
            case .some(true): return "+net"
            case .some(false): return "+cache"
            }
        }()
        let roleTag = role == .background ? "+bg" : ""
        let reuseTag = (!windowVisible && isNotifyCity) ? "+nr" : ""
        let key = location.id + "@\(location.coordinate.latitude),\(location.coordinate.longitude)"
            + (forceRefresh ? "!" : "") + netTag + roleTag + reuseTag
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task {
            try await self.buildReport(for: location, forceRefresh: forceRefresh, priority: priority,
                                       allowNetwork: allowNetwork, role: role,
                                       windowVisible: windowVisible, isNotifyCity: isNotifyCity)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    public func search(_ query: String) async throws -> [PlaceSearchResult] {
        let (name, qualifier) = PlaceSearch.parse(query)
        guard name.count >= 2 else { return [] }
        let url = Endpoints.geocoding(name, count: qualifier == nil ? 8 : 20)
        var entry = try await fetchEntry(url, ttl: TTL.geocoding)
        var results = try OpenMeteoGeocodingResponse.decode(entry.data)
        // An empty answer isn't kept for 30 days: a geocoder hiccup (or a new place) would read as
        // "No places found" for a month.
        if results.isEmpty, now().timeIntervalSince(entry.storedAt) >= PlaceSearch.emptyResultTTL {
            entry = try await fetchEntry(url, ttl: TTL.geocoding, force: true)
            results = try OpenMeteoGeocodingResponse.decode(entry.data)
        }
        let ranked = PlaceSearch.ranked(results, qualifier: qualifier)
        return qualifier == nil ? ranked : Array(ranked.prefix(8))
    }

    /// Key messages from the NWS office's latest Area Forecast Discussion (T17). Two small requests,
    /// cached (list 30 min, product a week); nil when the office has none or NWS is unreachable.
    public func forecasterNotes(office: String) async -> ForecasterNotes? {
        let headers = ["Accept": "application/ld+json"]
        guard let listURL = Endpoints.nwsAFDList(office: office),
              let list = await optionalFetch(listURL, ttl: TTL.afdList, force: false, headers: headers, maxStale: 12 * 3600),
              let id = try? AFDParser.latestID(list), let productURL = Endpoints.nwsProduct(id: id),
              let product = await optionalFetch(productURL, ttl: TTL.product, force: false, headers: headers)
        else { return nil }
        return try? AFDParser.notes(product, office: office.uppercased())
    }

    /// - Parameter future: append HRRR future-radar frames after the newest scan (NEXRAD only, T12). If the
    ///   HRRR run time can't be fetched, the observed loop is returned on its own.
    /// `site` (NEXRAD only): a single WSR-88D site id ("OKX"); nil for the national composite. A site
    /// with no recent scans returns no frames, and the caller falls back to the composite.
    public func radarFrames(_ provider: RadarProvider, range: RadarRange = .oneHour, future: Bool = false,
                            site: String? = nil, forceRefresh: Bool = false) async throws -> [RadarFrame] {
        switch provider {
        case .rainViewer:
            let data = try await fetch(Endpoints.rainViewerMaps, ttl: TTL.radarIndex, force: forceRefresh)
            return try RainViewerParser.decode(data)
        case .nexrad:
            let latest: Date
            var past: [RadarFrame]
            if let site {
                // Window on a 5-minute grid so the cached scan list's URL is stable between scans.
                let end = Date(timeIntervalSince1970: ((now().timeIntervalSince1970 / 300).rounded(.down) + 1) * 300)
                let start = end.addingTimeInterval(-Double(range.totalMinutes * 60 + 900))
                let data = try await fetch(IEMRidge.scanListURL(site: site, start: start, end: end), ttl: TTL.radarIndex, force: forceRefresh)
                let scans = try IEMRidge.decodeScans(data)
                // Stale site (down for maintenance): nothing in the last 30 min means no loop.
                guard let last = scans.last, now().timeIntervalSince(last) < 30 * 60 else { return [] }
                latest = last
                past = await smoothSiteFrames(site: site, scans: scans, range: range, force: forceRefresh)
            } else {
                let data = try await fetch(Endpoints.iemLatest, ttl: TTL.radarIndex, force: forceRefresh)
                latest = try IEMNexrad.latestValidTime(data) ?? now()
                past = IEMNexrad.frames(latest: latest, range: range)
            }
            // False-green fix: mask raw reflectivity with MRMS QC'd echoes. Best effort: no mask, no change.
            if let qc = await optionalFetch(Endpoints.iemLCRefLatest, ttl: TTL.radarIndex, force: forceRefresh, maxStale: 15 * 60),
               let maskLatest = try? RadarQC.latestValid(qc) {
                past = RadarQC.masked(past, latestMask: maskLatest)
            }
            guard future,
                  let run = await optionalFetch(Endpoints.iemHRRRLatest, ttl: TTL.hrrrRun, force: false, maxStale: 6 * 3600),
                  let initTime = try? IEMHRRR.initTime(run) else { return past }
            return past + IEMHRRR.frames(initTime: initTime, after: latest)
        }
    }

    /// True once IEM has archived `time`'s scan raster for `site` (its world file parses). A miss isn't
    /// cached, so callers can poll it.
    public func rasterArchived(site: String, time: Date) async -> Bool {
        guard let url = URL(string: IEMRidge.rasterBase(site: site, time: time) + ".wld") else { return false }
        return await optionalFetch(url, ttl: 24 * 3600, force: false).flatMap { String(data: $0, encoding: .ascii) }
            .flatMap(RidgeRaster.parseWorldFile) != nil
    }

    /// CR #7 (final): the newest scan's raster often trails the scan list by a minute or two. That scan is
    /// shown at once from IEM's tile (blocky) and RadarPlayback swaps it to smooth as soon as the raster is
    /// archived (`IEMRidge.isPendingSmooth`). Every older frame is smooth, so only the newest can differ.
    /// If the previous scan isn't archived either (archive down), the whole loop uses IEM's tiles.
    func smoothSiteFrames(site: String, scans: [Date], range: RadarRange, force: Bool) async -> [RadarFrame] {
        guard let last = scans.last else { return [] }
        if await rasterArchived(site: site, time: last) { return IEMRidge.frames(site: site, scans: scans, range: range) }
        let frames = IEMRidge.frames(site: site, scans: scans, range: range)
        if frames.count > 1, await rasterArchived(site: site, time: frames[frames.count - 2].time) {
            return IEMRidge.newestBlocky(frames, site: site)
        }
        return IEMRidge.frames(site: site, scans: scans, range: range, smooth: false)
    }

    /// Latest NEXRAD storm attributes near `location` (strong moving cells only). Cheap GeoJSON; nil on failure.
    public func stormCells(near location: Coordinate, forceRefresh: Bool = false) async -> [StormCell] {
        guard let data = await optionalFetch(Endpoints.iemNexradAttr, ttl: TTL.stormAttr, force: forceRefresh,
                                             maxStale: 10 * 60),
              let all = try? StormMotion.parse(data) else { return [] }
        return StormMotion.relevant(all, near: location)
    }

    // MARK: Daily limit (Open-Meteo free tier)

    /// When requests to `host` may resume after a daily-limit 429 (nil = not limited).
    public func dailyLimit(for host: String) -> Date? {
        let h = host.lowercased()
        guard let until = dailyLimitUntil[h], until > now() else { return nil }
        return until
    }

    public func isDailyLimited(host: String) -> Bool { dailyLimit(for: host) != nil }

    /// Clears in-memory daily-limit state and deletes the ResponseCache marker.
    public func clearDailyLimit(host: String) async {
        let h = host.lowercased()
        dailyLimitUntil[h] = nil
        nextProbeAt[h] = nil
        dailyLimitJitter[h] = nil
        dailyLimitLoaded.insert(h)
        await cache.remove(OpenMeteoQuota.markerKey(host: h))
    }

    /// Records a daily-limit hit: sets `until` (00:00 UTC + jitter) and persists the marker when allowed.
    public func noteDailyLimit(host: String) async {
        let h = host.lowercased()
        await loadDailyLimitMarkerIfNeeded(h)
        let jitter = dailyLimitJitter[h] ?? OpenMeteoQuota.drawJitter()
        dailyLimitJitter[h] = jitter
        let t = now()
        let until = OpenMeteoQuota.until(after: t, jitter: jitter)
        dailyLimitUntil[h] = until
        nextProbeAt[h] = OpenMeteoQuota.nextProbeAt(lastProbeAt: t)
        SkylineLog.quotaDailyLimit(host: h, until: until)
        guard persistQuotaMarker else { return }
        let marker = OpenMeteoQuota.Marker(until: until, lastProbeAt: t, jitter: jitter)
        if let data = try? OpenMeteoQuota.encode(marker) {
            await cache.store(data, for: OpenMeteoQuota.markerKey(host: h))
        }
    }

    /// Test seam: seed daily-limit state without a network 429.
    func setDailyLimitForTesting(_ host: String, until: Date, lastProbeAt: Date? = nil, jitter: TimeInterval = 0) {
        let h = host.lowercased()
        dailyLimitUntil[h] = until
        dailyLimitJitter[h] = jitter
        nextProbeAt[h] = OpenMeteoQuota.nextProbeAt(lastProbeAt: lastProbeAt ?? now())
        dailyLimitLoaded.insert(h)
    }

    /// When the next probe GET is allowed for `host` (nil = not limited / unknown).
    func nextDailyLimitProbe(for host: String) -> Date? {
        let h = host.lowercased()
        guard dailyLimitUntil[h] != nil else { return nil }
        return nextProbeAt[h]
    }

    private func loadDailyLimitMarkerIfNeeded(_ host: String) async {
        let h = host.lowercased()
        guard !dailyLimitLoaded.contains(h) else { return }
        dailyLimitLoaded.insert(h)
        guard let entry = await cache.entry(OpenMeteoQuota.markerKey(host: h), maxAge: .infinity),
              let marker = OpenMeteoQuota.decode(entry.data),
              OpenMeteoQuota.isSane(marker, now: now()) else { return }
        dailyLimitUntil[h] = marker.until
        dailyLimitJitter[h] = marker.jitter
        nextProbeAt[h] = OpenMeteoQuota.nextProbeAt(lastProbeAt: marker.lastProbeAt)
    }

    /// True when a network probe is allowed despite an active daily limit.
    /// ⌘R / force never hits OM while limited (does not consume the probe). Only the retry-owner's
    /// non-forced load at `nextProbeAt` (or after `until`) may probe.
    private func mayProbeDailyLimit(host: String, force: Bool, allowNetwork: Bool?) -> Bool {
        let h = host.lowercased()
        guard let until = dailyLimitUntil[h], until > now() else { return true }
        if force { return false }
        if let probe = nextProbeAt[h], now() >= probe { return true }
        // Stagger after a successful clear uses allowNetwork with no active until (handled above).
        _ = allowNetwork
        return false
    }

    // MARK: Assembly

    private func buildReport(for location: WeatherLocation, forceRefresh force: Bool,
                             priority: FetchPriority = .background,
                             allowNetwork: Bool? = nil,
                             role: RefreshPlanner.Role? = nil,
                             windowVisible: Bool = true,
                             isNotifyCity: Bool = false) async throws -> WeatherReport {
        // "My Location" goes out at ~1 km (the store already coarsens the fix; this is defense in depth).
        let coord = location.isCurrentLocation ? location.coordinate.coarse : location.coordinate.rounded
        // US-only sources (HRRR, NWS) follow the border outlines and the saved city's country (QA 4).
        let models = ForecastModel.models(inCONUS: location.isInCONUS)
        // Decision 2 N: hidden notify cities reuse OM up to notifyReuseHidden; alerts keep 5-min TTL.
        let omTTL: TimeInterval = {
            if role == .background { return TTL.background }
            if !windowVisible, isNotifyCity { return TTL.notifyReuseHidden }
            return TTL.forecast
        }()
        let aqTTL = (role == .background) ? TTL.background : TTL.airQuality
        let omPriority = force ? FetchPriority.interactive : priority
        // Decision 2 L: background (non-force) may send B-only while A < blendMaxAge.
        let lightBackground = role == .background && !force

        async let omPairFetch: Result<OpenMeteoPairResult, Error> = {
            do {
                return .success(try await fetchOpenMeteoPair(
                    coord, models: models, ttl: omTTL, force: force, maxStale: MaxStale.forecast,
                    priority: omPriority, allowNetwork: allowNetwork, lightBackground: lightBackground))
            } catch {
                return .failure(error)
            }
        }()
        async let aqData = optionalFetch(Endpoints.openMeteoAirQuality(coord), ttl: aqTTL, force: force,
                                         maxStale: MaxStale.airQuality, allowNetwork: allowNetwork)
        // A remembered /points 404 skips only the forecast lookup; warnings are asked for regardless (L2).
        let inNWSArea = location.isLikelyInNWSCoverage
        let inNWS = inNWSArea ? !(await nwsKnownMissing(coord)) : false
        async let nwsBundle = inNWS ? fetchNWS(coord, force: force) : nil
        // Warnings don't need the /points lookup: fetched on their own so a /points failure (first
        // launch during an NWS hiccup) can't hide them (L2).
        async let alertsFetch = inNWSArea ? fetchAlerts(coord, force: force) : []
        async let outlooksFetch = location.isInCONUS ? fetchOutlooks(coord) : []

        let pairOutcome = await omPairFetch
        let nws = await nwsBundle
        let alerts = await alertsFetch
        let air = await aqData.flatMap { try? OpenMeteoAirQualityResponse.decode($0) }
        let outlooks = await outlooksFetch

        let pair: OpenMeteoPairResult?
        switch pairOutcome {
        case .success(let p): pair = p
        case .failure(let error):
            let limited: Bool = {
                if case HTTPError.dailyLimit = error { return true }
                return isDailyLimited(host: OpenMeteoQuota.forecastHost)
            }()
            if limited {
                return try await buildNWSOnlyOrThrow(location: location, coord: coord, nws: nws,
                                                     alerts: alerts, air: air, outlooks: outlooks,
                                                     error: error)
            }
            throw error
        }

        guard let pair else { throw HTTPError.invalidResponse }
        let om = pair.response
        guard var current = om.currentConditions() else { throw HTTPError.invalidResponse }

        let tz = TimeZone(identifier: om.timezone) ?? location.timeZone
        let key = VerificationKey.key(for: location)
        let learned: BlendWeights
        if let verifier, let w = await verifier.weightsIfLoaded(key) {
            learned = w
        } else {
            learned = .neutral
            if let verifier { Task.detached(priority: .utility) { _ = await verifier.weights(key) } } // load for next time
        }
        let minutely = om.minutelyPrecipitation()
        var hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nws?.hourly ?? [], now: current.time,
                                                 weights: learned, minutely: minutely)
        // Daily is built from the RAW hourly (lock §2); correction applies after.
        var daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws?.periods ?? [], timeZone: tz,
                                               weights: learned, hourly: hourly)
        // Accuracy PR 2: one apply point after blendDaily, before headline. Raw series go to measurement.
        let rawHourly = hourly
        let rawDaily = daily
        let issuedNow = now()
        var corrected = false
        if let verifier {
            if let offsets = await verifier.correctionIfLoaded(key),
               offsets.values.contains(where: { abs($0) > 1e-12 }) {
                BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current,
                                     issued: issuedNow, timeZone: tz, offsets: offsets)
                corrected = true
            } else {
                Task.detached(priority: .utility) {
                    _ = await verifier.corrections(key, timeZoneIdentifier: om.timezone,
                                                   cityElevationM: om.elevation)
                }
            }
        }
        // The headline temperature is the blend (models + NWS) at the current time, not one model's value.
        // "Feels like" keeps its offset from the air temperature. Sees corrected hourly (B8).
        if let blended = ForecastBlender.temperature(at: current.time, hourly: hourly) {
            current.apparentTemperature += blended.temperature - current.temperature
            current.temperature = blended.temperature
        }
        // Dew point never above the corrected headline temperature (B8). Only when corrected: PR 1 bytes unchanged.
        if corrected, let dp = current.dewPoint { current.dewPoint = min(dp, current.temperature) }
        // The header's "Rain" agrees with the 15-minute nowcast (dropdown review S3).
        // reconcileCurrent sees the corrected temperature (B8 knock-on).
        current.weatherCode = Nowcast.reconcileCurrent(code: current.weatherCode, minutely: minutely, now: now(),
                                                       temperature: current.temperature)

        // "Why the forecast changed": compare with the outlook from ~12 h ago, then save this one.
        // history.record stores what the user saw (corrected). Only when OM is live (not fallback).
        var earlier: ForecastSnapshot?
        if let history, !pair.isFallback {
            let t = now()
            earlier = await history.earlier(key, now: t)
            await history.record(key, daily: daily, now: t)
        }

        // Accuracy guard (§4.5): issuance only when neither half is fallback and pair age ≤ TTL.forecast.
        // Decision 2 L: a B-only refresh records no issuance and no accuracy sample.
        // runMeasurement always when OM exists; empty series when not fresh. verifyIfDue ungated.
        let pairAge = now().timeIntervalSince(pair.storedAt)
        let halvesFresh = !pair.halfA.isFallback && !pair.halfB.isFallback
        let issuanceOK = halvesFresh && pairAge <= TTL.forecast && !pair.isBOnly && !pair.isSingleModelB
        let measureFresh = issuanceOK
        if let verifier {
            let issued = issuedNow
            let nwsHourly = nws?.hourly ?? []
            let stations = nws?.point.observationStations
            let measureTZ = om.timezone
            let measureDaily = measureFresh ? rawDaily : []
            let measureHourly = measureFresh ? rawHourly : []
            let measureCoord = coord
            let measureIsUS = location.isLikelyInNWSCoverage
            let measureElev = om.elevation
            let omForVerify = om
            Task.detached(priority: .utility) {
                if issuanceOK, await verifier.wantsIssuance(key) {
                    let records = ForecastSampler.records(location: key, issued: issued, openMeteo: omForVerify,
                                                          nwsHourly: nwsHourly, blended: rawHourly)
                    await verifier.record(records, key: key)
                }
                await verifier.verifyIfDue(key: key, stationsURL: stations, near: coord,
                                           cityElevationM: measureElev)
                await verifier.runMeasurement(key: key, coordinate: measureCoord, timeZoneIdentifier: measureTZ,
                                              daily: measureDaily, openMeteo: omForVerify, blended: measureHourly,
                                              isUS: measureIsUS, cityElevationM: measureElev)
            }
        }

        var sources = om.modelsWithData.map(\.displayName)
        if let nws, !(nws.periods.isEmpty && nws.hourly.isEmpty) { sources.append("NWS \(nws.point.gridID)") }
        if air != nil { sources.append("Open-Meteo Air Quality (CAMS)") }

        var loc = location
        if loc.timeZoneIdentifier == nil { loc.timeZoneIdentifier = om.timezone }

        // The data is as old as its oldest forecast input (a cached copy keeps its download time).
        let dataAsOf = ([pair.storedAt] + (nws?.forecastStoredAt ?? [])).min() ?? pair.storedAt
        var report = WeatherReport(location: loc, fetchedAt: now(), timeZoneIdentifier: om.timezone,
                             current: current, hourly: hourly, daily: daily,
                             minutely: minutely, alerts: alerts,
                             airQuality: air, sources: sources,
                             nwsOffice: nws.map { [$0.point.city, $0.point.state].compactMap { $0 }.joined(separator: ", ") },
                             dataAsOf: dataAsOf, isOfflineFallback: pair.isFallback)
        report.nwsGridID = nws?.point.gridID
        report.forecastAsOf = pair.storedAt
        report.fallbackCause = pair.isFallback ? (pair.cause ?? .unreachable) : nil
        report.earlierOutlook = earlier
        report.severeOutlooks = outlooks
        report.modelSeries = ForecastBlender.modelSeries(openMeteo: om, nwsHourly: nws?.hourly ?? [], blended: hourly,
                                                         now: current.time)
        report.forecastMode = .blend
        return report
    }

    /// NWS-only (or throw) when OM is unavailable due to daily limit / pair miss while limited.
    private func buildNWSOnlyOrThrow(location: WeatherLocation, coord: Coordinate, nws: NWSBundle?,
                                     alerts: [WeatherAlert], air: AirQuality?, outlooks: [SevereOutlook],
                                     error: Error) async throws -> WeatherReport {
        let until = dailyLimit(for: OpenMeteoQuota.forecastHost)
            ?? OpenMeteoQuota.until(after: now(), jitter: dailyLimitJitter[OpenMeteoQuota.forecastHost] ?? 0)
        if location.isLikelyInNWSCoverage,
           let nws, !(nws.periods.isEmpty && nws.hourly.isEmpty),
           let parts = NWSOnlyForecast.build(periods: nws.periods, hourlyPeriods: nws.hourly,
                                             coordinate: coord, timeZone: location.timeZone, now: now()) {
            let tzID = location.timeZoneIdentifier ?? location.timeZone.identifier
            let dataAsOf = (nws.forecastStoredAt.min() ?? now())
            var report = WeatherReport(location: location, fetchedAt: now(), timeZoneIdentifier: tzID,
                                       current: parts.current, hourly: parts.hourly, daily: parts.daily,
                                       minutely: [], alerts: alerts, airQuality: air,
                                       sources: ["NWS \(nws.point.gridID)"],
                                       nwsOffice: [nws.point.city, nws.point.state].compactMap { $0 }.joined(separator: ", "),
                                       dataAsOf: dataAsOf, isOfflineFallback: false)
            report.nwsGridID = nws.point.gridID
            report.forecastAsOf = nil
            report.fallbackCause = .dailyLimit
            report.severeOutlooks = outlooks
            report.forecastMode = .nwsOnly
            // verifyIfDue still runs; no issuance / measurement / history / BiasCorrection (no OM).
            if let verifier {
                let key = VerificationKey.key(for: location)
                let stations = nws.point.observationStations
                Task.detached(priority: .utility) {
                    await verifier.verifyIfDue(key: key, stationsURL: stations, near: coord,
                                               cityElevationM: nil)
                }
            }
            _ = until // store builds OpenMeteoQuota.nwsOnlyMessage from dailyLimit(for:)
            return report
        }
        // Non-US (or empty NWS): no usable forecast.
        if case HTTPError.dailyLimit = error { throw error }
        throw HTTPError.dailyLimit(host: OpenMeteoQuota.forecastHost)
    }

    // MARK: Open-Meteo A+B pair (CR M1)

    /// Fetches (or reads) the A+B forecast pair as one unit inside a single Open-Meteo turn.
    /// Decision 2 L: when `lightBackground` and cached A age < blendMaxAge, only B is fetched.
    func fetchOpenMeteoPair(_ coord: Coordinate, models: [ForecastModel], ttl: TimeInterval,
                            force: Bool, maxStale: TimeInterval, priority: FetchPriority,
                            allowNetwork: Bool?, lightBackground: Bool = false) async throws -> OpenMeteoPairResult {
        let urlA = Endpoints.openMeteoForecastA(coord, models: models)
        let urlB = Endpoints.openMeteoForecastB(coord)
        let keyA = urlA.absoluteString
        let keyB = urlB.absoluteString
        let host = OpenMeteoQuota.forecastHost
        await loadDailyLimitMarkerIfNeeded(host)

        let bypassFreshness = allowNetwork == true
        if !force, !bypassFreshness, allowNetwork != false,
           let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: ttl) {
            return cached
        }

        // Cache-only: never hit the network.
        if allowNetwork == false {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                let age = now().timeIntervalSince(cached.storedAt)
                if age >= ttl {
                    return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                               isFallback: true, cause: isDailyLimited(host: host) ? .dailyLimit : .unreachable,
                                               halfA: cached.halfA, halfB: cached.halfB)
                }
                return cached
            }
            if isDailyLimited(host: host) { throw HTTPError.dailyLimit(host: host) }
            throw HTTPError.invalidResponse
        }

        // Daily-limited: prefer stale pair; probe only when due / forced / allowNetwork.
        if isDailyLimited(host: host), !mayProbeDailyLimit(host: host, force: force, allowNetwork: allowNetwork) {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .dailyLimit,
                                           halfA: fallbackHalf(cached.halfA, .dailyLimit),
                                           halfB: fallbackHalf(cached.halfB, .dailyLimit))
            }
            throw HTTPError.dailyLimit(host: host)
        }

        // Short back-off: interactive / force waits it out (same as fetchEntry); otherwise stale or throw.
        var waits = force
        if !force, let until = backoffUntil[host], until > now() {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .busy,
                                           halfA: fallbackHalf(cached.halfA, .busy),
                                           halfB: fallbackHalf(cached.halfB, .busy))
            }
            guard priority == .interactive else { throw HTTPError.backingOff(host: host, until: until) }
            waits = true
        }
        if waits { try await prepareForceFetch(host) }

        let pairKey = "om-pair:" + keyA + (lightBackground ? "+L" : "")
        // Same coordinate already fetching: join (add + sync under another id).
        if !force, let shared = inFlightPairGets[pairKey] {
            joinedGets += 1
            if priority == .interactive { promote(pairKey) }
            return try await shared.value
        }

        func attempt() async throws -> OpenMeteoPairResult {
            do {
                return try await withOpenMeteoTurn(host, priority: force ? priority : (inFlightPriority[pairKey] ?? priority),
                                                   key: pairKey) {
                    try await self.loadOpenMeteoPairNetwork(urlA: urlA, urlB: urlB, keyA: keyA, keyB: keyB,
                                                            host: host, force: force, maxStale: maxStale,
                                                            allowNetwork: allowNetwork,
                                                            lightBackground: lightBackground)
                }
            } catch let error as HTTPError {
                guard waits, case .backingOff = error else { throw error }
                try await prepareForceFetch(host)
                return try await withOpenMeteoTurn(host, priority: priority, key: pairKey) {
                    try await self.loadOpenMeteoPairNetwork(urlA: urlA, urlB: urlB, keyA: keyA, keyB: keyB,
                                                            host: host, force: force, maxStale: maxStale,
                                                            allowNetwork: allowNetwork,
                                                            lightBackground: lightBackground)
                }
            }
        }

        if force { return try await attempt() }
        let task = Task { try await attempt() }
        inFlightPairGets[pairKey] = task
        inFlightPriority[pairKey] = priority
        defer { inFlightPairGets[pairKey] = nil; inFlightPriority[pairKey] = nil }
        return try await task.value
    }

    /// Network half of the pair fetch; caller holds the Open-Meteo turn.
    private func loadOpenMeteoPairNetwork(urlA: URL, urlB: URL, keyA: String, keyB: String,
                                          host: String, force: Bool, maxStale: TimeInterval,
                                          allowNetwork: Bool?,
                                          lightBackground: Bool = false) async throws -> OpenMeteoPairResult {
        if isDailyLimited(host: host), !mayProbeDailyLimit(host: host, force: force, allowNetwork: allowNetwork) {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .dailyLimit,
                                           halfA: fallbackHalf(cached.halfA, .dailyLimit),
                                           halfB: fallbackHalf(cached.halfB, .dailyLimit))
            }
            throw HTTPError.dailyLimit(host: host)
        }
        if let until = backoffUntil[host], until > now() {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .busy,
                                           halfA: fallbackHalf(cached.halfA, .busy),
                                           halfB: fallbackHalf(cached.halfB, .busy))
            }
            throw HTTPError.backingOff(host: host, until: until)
        }

        let wasLimited = isDailyLimited(host: host)

        // Decision 2 L: B-only while cached A is younger than blendMaxAge.
        if lightBackground,
           let cachedA = await cache.entry(keyA, maxAge: TTL.blendMaxAge),
           now().timeIntervalSince(cachedA.storedAt) < TTL.blendMaxAge,
           let decodedA = try? OpenMeteoResponse.decode(cachedA.data) {
            if let bOnly = try await loadBOnly(cachedA: cachedA, decodedA: decodedA, urlB: urlB, keyB: keyB,
                                               host: host, wasLimited: wasLimited) {
                return bOnly
            }
            // Content mismatch → fall through to full A+B.
        }

        // Full A+B (or A refetch when A age ≥ blendMaxAge).
        let dataA: Data
        do {
            dataA = try await rawGet(urlA)
        } catch HTTPError.dailyLimit(let h) {
            await noteDailyLimit(host: h)
            // Decision 2 L: if A fails at/after blendMaxAge but B succeeds, show single-model B.
            if lightBackground, let single = try? await fetchSingleModelB(urlB: urlB, keyB: keyB, host: host) {
                return single
            }
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .dailyLimit,
                                           halfA: fallbackHalf(cached.halfA, .dailyLimit),
                                           halfB: fallbackHalf(cached.halfB, .dailyLimit))
            }
            throw HTTPError.dailyLimit(host: h)
        } catch {
            if case HTTPError.throttled(_, _, let retryAfter) = error {
                noteThrottled(host, retryAfter: retryAfter)
            }
            if lightBackground, let single = try? await fetchSingleModelB(urlB: urlB, keyB: keyB, host: host) {
                return single
            }
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: FallbackCause(error),
                                           halfA: fallbackHalf(cached.halfA, FallbackCause(error)),
                                           halfB: fallbackHalf(cached.halfB, FallbackCause(error)))
            }
            throw error
        }

        // A succeeded — only then fetch B. Do not cache A until B is also 2xx.
        let dataB: Data
        do {
            dataB = try await rawGet(urlB)
        } catch HTTPError.dailyLimit(let h) {
            await noteDailyLimit(host: h)
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .dailyLimit,
                                           halfA: fallbackHalf(cached.halfA, .dailyLimit),
                                           halfB: fallbackHalf(cached.halfB, .dailyLimit))
            }
            throw HTTPError.dailyLimit(host: h)
        } catch {
            if case HTTPError.throttled(_, _, let retryAfter) = error {
                noteThrottled(host, retryAfter: retryAfter)
            }
            // Discard fresh A (do not cache). Fall back to cached pair if consistent.
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: FallbackCause(error),
                                           halfA: fallbackHalf(cached.halfA, FallbackCause(error)),
                                           halfB: fallbackHalf(cached.halfB, FallbackCause(error)))
            }
            throw error
        }

        let stored = now()
        // M1: both halves must decode and agree (time axes / tz / offset) before either is cached;
        // a fetch straddling local midnight is a pair miss, never a skewed merge or accuracy sample.
        guard let decodedA = try? OpenMeteoResponse.decode(dataA),
              let decodedB = try? OpenMeteoResponse.decode(dataB),
              OpenMeteoResponse.pairConsistent(decodedA, storedAtA: stored, decodedB, storedAtB: stored) else {
            if let cached = await readCachedPair(keyA: keyA, keyB: keyB, maxAge: maxStale) {
                return OpenMeteoPairResult(response: cached.response, storedAt: cached.storedAt,
                                           isFallback: true, cause: .unreachable,
                                           halfA: fallbackHalf(cached.halfA, .unreachable),
                                           halfB: fallbackHalf(cached.halfB, .unreachable))
            }
            throw HTTPError.invalidResponse
        }
        await cache.store(dataA, for: keyA)
        await cache.store(dataB, for: keyB)
        if wasLimited { await clearDailyLimit(host: host) }
        backoffUntil[host] = nil
        backoffStrikes[host] = nil
        let halfA = Fetched(data: dataA, storedAt: stored, isFallback: false)
        let halfB = Fetched(data: dataB, storedAt: stored, isFallback: false)
        let merged = OpenMeteoResponse.mergePair(a: decodedA, b: decodedB)
        return OpenMeteoPairResult(response: merged, storedAt: stored, isFallback: false, cause: nil,
                                   halfA: halfA, halfB: halfB)
    }

    /// Decision 2 L: fetch B and merge with cached A. Returns nil on content mismatch (caller does A+B).
    private func loadBOnly(cachedA: ResponseCache.Entry, decodedA: OpenMeteoResponse,
                           urlB: URL, keyB: String, host: String, wasLimited: Bool) async throws -> OpenMeteoPairResult? {
        do {
            let dataB = try await rawGet(urlB)
            let storedB = now()
            guard let decodedB = try? OpenMeteoResponse.decode(dataB),
                  OpenMeteoResponse.pairConsistent(decodedA, storedAtA: storedB,
                                                   decodedB, storedAtB: storedB) else {
                return nil
            }
            await cache.store(dataB, for: keyB)
            if wasLimited { await clearDailyLimit(host: host) }
            backoffUntil[host] = nil
            backoffStrikes[host] = nil
            let halfA = Fetched(data: cachedA.data, storedAt: cachedA.storedAt, isFallback: false)
            let halfB = Fetched(data: dataB, storedAt: storedB, isFallback: false)
            let merged = OpenMeteoResponse.mergePair(a: decodedA, b: decodedB)
            return OpenMeteoPairResult(response: merged, storedAt: storedB, isFallback: false, cause: nil,
                                       halfA: halfA, halfB: halfB, isBOnly: true)
        } catch HTTPError.dailyLimit(let h) {
            await noteDailyLimit(host: h)
            throw HTTPError.dailyLimit(host: h)
        } catch {
            if case HTTPError.throttled(_, _, let retryAfter) = error {
                noteThrottled(host, retryAfter: retryAfter)
            }
            throw error
        }
    }

    /// Decision 2 L fallback: A refetch failed/limited → fetch B and show single-model B.
    private func fetchSingleModelB(urlB: URL, keyB: String, host: String) async throws -> OpenMeteoPairResult {
        let dataB = try await rawGet(urlB)
        let stored = now()
        guard let decodedB = try? OpenMeteoResponse.decode(dataB) else { throw HTTPError.invalidResponse }
        await cache.store(dataB, for: keyB)
        backoffUntil[host] = nil
        backoffStrikes[host] = nil
        let halfB = Fetched(data: dataB, storedAt: stored, isFallback: false)
        return OpenMeteoPairResult(response: decodedB, storedAt: stored, isFallback: false, cause: nil,
                                   halfA: halfB, halfB: halfB, isBOnly: true, isSingleModelB: true)
    }

    private func fallbackHalf(_ h: Fetched, _ cause: FallbackCause) -> Fetched {
        Fetched(data: h.data, storedAt: h.storedAt, isFallback: true, cause: cause)
    }

    /// Reads both halves from cache; returns nil when either is missing or pairConsistent fails.
    private func readCachedPair(keyA: String, keyB: String, maxAge: TimeInterval) async -> OpenMeteoPairResult? {
        guard let eA = await cache.entry(keyA, maxAge: maxAge),
              let eB = await cache.entry(keyB, maxAge: maxAge),
              let a = try? OpenMeteoResponse.decode(eA.data),
              let b = try? OpenMeteoResponse.decode(eB.data),
              OpenMeteoResponse.pairConsistent(a, storedAtA: eA.storedAt, b, storedAtB: eB.storedAt)
        else { return nil }
        let older = min(eA.storedAt, eB.storedAt)
        let age = now().timeIntervalSince(older)
        // Caller decides fallback vs fresh via ttl; here we only assemble.
        let halfA = Fetched(data: eA.data, storedAt: eA.storedAt, isFallback: false)
        let halfB = Fetched(data: eB.data, storedAt: eB.storedAt, isFallback: false)
        _ = age
        return OpenMeteoPairResult(response: OpenMeteoResponse.mergePair(a: a, b: b), storedAt: older,
                                   isFallback: false, cause: nil, halfA: halfA, halfB: halfB)
    }

    /// Direct GET with one transient retry; no cache, no Open-Meteo turn (caller holds the turn).
    private func rawGet(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        do {
            return try await client.get(url, headers: headers)
        } catch let error where FallbackCause.retriesOnce(error) {
            try await Task.sleep(for: .seconds(transientRetryDelay))
            return try await client.get(url, headers: headers)
        }
    }

    struct NWSBundle: Sendable {
        var point: NWSPoint
        var periods: [NWSPeriod]
        var hourly: [NWSPeriod]
        /// Download times of the NWS forecasts that were used.
        var forecastStoredAt: [Date] = []
    }

    /// Everything NWS for a point; nil when the point is outside NWS coverage or the API is down.
    private func fetchNWS(_ c: Coordinate, force: Bool) async -> NWSBundle? {
        let pointURL = Endpoints.nwsPoint(c)
        let pointData: Data
        do {
            pointData = try await fetch(pointURL, ttl: TTL.nwsPoint, force: false)
        } catch HTTPError.status(404, _) {
            // Not an NWS point: remember it (on disk) so we stop asking on every refresh.
            await cache.store(Data("404".utf8), for: Self.nwsMissingKey(pointURL))
            return nil
        } catch {
            return nil
        }
        guard let point = try? NWSPoint.decode(pointData) else { return nil }
        let headers = ["Accept": "application/geo+json"]
        async let f = optionalFetchEntry(point.forecastURL, ttl: TTL.nwsForecast, force: force, headers: headers,
                                         maxStale: MaxStale.nwsForecast)
        async let h = optionalFetchEntry(point.forecastHourlyURL, ttl: TTL.nwsForecast, force: force, headers: headers,
                                         maxStale: MaxStale.nwsForecast)
        let t = now()
        // Out-of-date NWS forecasts (old cached copies, or a "stuck" NWS grid) are ignored, not blended.
        func recentPeriods(_ e: Fetched?) -> [NWSPeriod]? {
            guard let e, NWSPeriod.isRecent(NWSPeriod.issuance(e.data), downloadedAt: e.storedAt, now: t) else { return nil }
            return try? NWSPeriod.decodeList(e.data)
        }
        let fEntry = await f, hEntry = await h
        let periods = recentPeriods(fEntry) ?? []
        let hourly = recentPeriods(hEntry) ?? []
        var storedAt: [Date] = []
        if !periods.isEmpty, let fEntry { storedAt.append(fEntry.storedAt) }
        if !hourly.isEmpty, let hEntry { storedAt.append(hEntry.storedAt) }
        return NWSBundle(point: point, periods: periods, hourly: hourly, forecastStoredAt: storedAt)
    }

    /// SPC Day 1 and Day 2 outlooks at the point (marginal risk or higher). Failures just mean no line.
    private func fetchOutlooks(_ c: Coordinate) async -> [SevereOutlook] {
        var out: [SevereOutlook] = []
        for day in 1...2 {
            guard let data = await optionalFetch(Endpoints.spcOutlook(day: day), ttl: TTL.spcOutlook, force: false,
                                                 maxStale: 6 * 3600),
                  let o = try? SPCOutlookParser.outlook(data, day: day, point: c), o.isSevere, o.validUntil > now()
            else { continue }
            out.append(o)
        }
        return out
    }

    static func nwsMissingKey(_ pointURL: URL) -> String { "nws-404:" + pointURL.absoluteString }

    /// True when NWS said 404 for this point within the last week.
    func nwsKnownMissing(_ c: Coordinate) async -> Bool {
        await cache.entry(Self.nwsMissingKey(Endpoints.nwsPoint(c)), maxAge: TTL.nwsMissing) != nil
    }

    /// Active NWS warnings for a point (with zone outlines for zone-based ones). Independent of `/points`.
    private func fetchAlerts(_ c: Coordinate, force: Bool) async -> [WeatherAlert] {
        let data = await optionalFetch(Endpoints.nwsAlerts(c), ttl: TTL.alerts, force: force,
                                       headers: ["Accept": "application/geo+json"], maxStale: MaxStale.alerts)
        let alerts = data.flatMap { try? NWSAlertParser.decode($0, now: now()) } ?? []
        return await withZoneOutlines(alerts)
    }

    /// Zone-based alerts (no polygon of their own) get their forecast zones' outlines, so the map can
    /// draw them. Zone shapes rarely change, so they're cached for a week; at most 8 zones per refresh.
    private func withZoneOutlines(_ alerts: [WeatherAlert]) async -> [WeatherAlert] {
        let zones = Array(Set(alerts.filter { $0.polygons.isEmpty }.flatMap { $0.affectedZones.prefix(4) }).prefix(8))
        guard !zones.isEmpty else { return alerts }
        var outlines: [URL: [[Coordinate]]] = [:]
        await withTaskGroup(of: (URL, [[Coordinate]]).self) { group in
            for zone in zones {
                guard let url = Endpoints.nwsZone(zone) else { continue }
                group.addTask {
                    let data = await self.optionalFetch(url, ttl: 7 * 24 * 3600, force: false,
                                                        headers: ["Accept": "application/geo+json"])
                    return (zone, data.flatMap { try? NWSZoneParser.decode($0) } ?? [])
                }
            }
            for await (zone, rings) in group { outlines[zone] = rings }
        }
        return alerts.map { alert in
            guard alert.polygons.isEmpty else { return alert }
            var a = alert
            a.polygons = alert.affectedZones.flatMap { outlines[$0] ?? [] }
            a.outlineIsZone = !a.polygons.isEmpty
            return a
        }
    }

    // MARK: Fetch with cache

    /// How long a forced refresh (banner Retry, toolbar Refresh) may sleep. Longer than this, the
    /// store schedules a retry and leaves Refresh usable instead of pinning the spinner.
    static let forceWaitCap: TimeInterval = 30

    /// Fresh cache → network → stale cache no older than `maxStale` (offline fallback) → error.
    /// The result carries the data's real download time, so a cached copy is never passed off as new.
    func fetchEntry(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:],
                    maxStale: TimeInterval = .infinity, priority: FetchPriority = .background,
                    allowNetwork: Bool? = nil) async throws -> Fetched {
        let key = url.absoluteString
        let host = (url.host ?? "").lowercased()
        let isQuotaHost = OpenMeteoQuota.exactHosts.contains(host)
        if isQuotaHost { await loadDailyLimitMarkerIfNeeded(host) }

        let bypassFreshness = allowNetwork == true
        if !force, !bypassFreshness, let hit = await cache.entry(key, maxAge: ttl), now().timeIntervalSince(hit.storedAt) < ttl {
            return Fetched(data: hit.data, storedAt: hit.storedAt, isFallback: false)
        }

        if allowNetwork == false {
            if let stale = await cache.entry(key, maxAge: maxStale) {
                let age = now().timeIntervalSince(stale.storedAt)
                if age < ttl {
                    return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: false)
                }
                return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true,
                               cause: isDailyLimited(host: host) ? .dailyLimit : .unreachable)
            }
            if isQuotaHost, isDailyLimited(host: host) { throw HTTPError.dailyLimit(host: host) }
            throw HTTPError.invalidResponse
        }

        // Daily-limited quota host: prefer stale; only probe when due (AQ never probes).
        if isQuotaHost, isDailyLimited(host: host) {
            let canProbe = host == OpenMeteoQuota.forecastHost
                && mayProbeDailyLimit(host: host, force: force, allowNetwork: allowNetwork)
            if !canProbe {
                if let stale = await cache.entry(key, maxAge: maxStale) {
                    return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true, cause: .dailyLimit)
                }
                throw HTTPError.dailyLimit(host: host)
            }
        }

        // Non-force traffic never sleeps through a back-off; the stale copy (or the error) is enough.
        // Item 2: a first fetch (nothing cached to show) waits out a short back-off like Retry does,
        // instead of failing at once with a banner and a retry minutes later.
        var waits = force
        if !force, let until = backoffUntil[host], until > now() {
            if let stale = await cache.entry(key, maxAge: maxStale) {
                return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true, cause: .busy)
            }
            guard priority == .interactive else { throw HTTPError.backingOff(host: host, until: until) }
            waits = true
        }
        // A short window is waited out, then fetched once. A long one throws so the UI can schedule
        // "retrying at h:mm" without holding `loadingIDs` for the rest of Retry-After.
        if waits { try await prepareForceFetch(host) }
        // Same URL already on the wire (not forced): share its answer, no second GET or queue slot.
        if !force, let shared = inFlightGets[key] {
            joinedGets += 1
            if priority == .interactive { promote(key) }
            return try await shared.value
        }

        func network() async throws -> Fetched {
            do {
                // Re-read after the wait and after queueing behind another city. A sibling 429 may
                // have pushed the deadline out; don't hit the network on a stale "clear" decision.
                if let until = backoffUntil[host], until > now() {
                    throw HTTPError.backingOff(host: host, until: until)
                }
                if isQuotaHost, isDailyLimited(host: host),
                   host == OpenMeteoQuota.airQualityHost
                    || !mayProbeDailyLimit(host: host, force: force, allowNetwork: allowNetwork) {
                    throw HTTPError.dailyLimit(host: host)
                }
                let epoch = throttleEpoch[host, default: 0]
                let wasLimited = isDailyLimited(host: host)
                let data: Data
                do {
                    data = try await client.get(url, headers: headers)
                } catch let error where FallbackCause.retriesOnce(error) {
                    // Root cause of the false "Offline" banner after Refresh (QA, build 88): a forced
                    // burst often meets one dropped request (-1005 on a keep-alive connection the server
                    // had closed, or a 502). That fell straight back to the saved copy and the banner
                    // called it "Offline". Try once more, still inside this host's turn.
                    try await Task.sleep(for: .seconds(transientRetryDelay))
                    data = try await client.get(url, headers: headers)
                }
                if throttleEpoch[host, default: 0] == epoch {
                    backoffUntil[host] = nil
                    backoffStrikes[host] = nil
                }
                if wasLimited, isQuotaHost { await clearDailyLimit(host: host) }
                await cache.store(data, for: key)
                return Fetched(data: data, storedAt: now(), isFallback: false)
            } catch {
                if waits, case HTTPError.backingOff = error { throw error }
                if case HTTPError.dailyLimit(let h) = error {
                    await noteDailyLimit(host: h)
                    if let stale = await cache.entry(key, maxAge: maxStale) {
                        return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true, cause: .dailyLimit)
                    }
                    throw error
                }
                if case HTTPError.throttled(_, _, let retryAfter) = error { noteThrottled(host, retryAfter: retryAfter) }
                if let stale = await cache.entry(key, maxAge: maxStale) {
                    return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true, cause: FallbackCause(error))
                }
                throw error
            }
        }

        // A forced fetch runs on its own (not joined), so it keeps its own priority rather than inheriting
        // whatever a background GET for the same key had registered (deferred #5 note).
        func turnPriority() -> FetchPriority { force ? priority : (inFlightPriority[key] ?? priority) }
        func attempt() async throws -> Fetched {
            do {
                return try await withOpenMeteoTurn(host, priority: turnPriority(), key: key, network)
            } catch let error as HTTPError {
                // The city ahead of us in line was throttled. Wait only if the new window still fits.
                guard waits, case .backingOff = error else { throw error }
                try await prepareForceFetch(host)
                return try await withOpenMeteoTurn(host, priority: turnPriority(), key: key, network)
            }
        }
        if force { return try await attempt() }
        let task = Task { try await attempt() }
        inFlightGets[key] = task
        inFlightPriority[key] = priority
        defer { inFlightGets[key] = nil; inFlightPriority[key] = nil }
        return try await task.value
    }

    /// Sleeps out a back-off only while the remaining time fits in `forceWaitCap` (total, across
    /// re-checks). Each sleep is followed by another read of `backoffUntil`.
    private func prepareForceFetch(_ host: String) async throws {
        var budget = Self.forceWaitCap
        while let until = backoffUntil[host], until > now() {
            let remaining = until.timeIntervalSince(now())
            if remaining > budget {
                throw HTTPError.backingOff(host: host, until: until)
            }
            try await waitOutBackoff(until)
            budget -= remaining
        }
    }

    /// Sleeps until `until` on the service clock.
    private func waitOutBackoff(_ until: Date) async throws {
        let delay = until.timeIntervalSince(now())
        guard delay > 0 else { return }
        try Task.checkCancellation()
        try await backoffSleep(delay)
    }

    /// Serializes `api.open-meteo.com` GETs. Other hosts run straight through.
    private func withOpenMeteoTurn<T>(_ host: String, priority: FetchPriority = .background, key: String? = nil,
                                      _ body: () async throws -> T) async throws -> T {
        let gate = host == RefreshBookkeeping.openMeteoHost || host == OpenMeteoQuota.forecastHost
        if gate { await acquireOpenMeteo(priority, key: key) }
        do {
            let value = try await body()
            if gate { releaseOpenMeteo() }
            return value
        } catch {
            if gate { releaseOpenMeteo() }
            throw error
        }
    }

    /// Follow-up M1: an interactive caller joined this shared GET; if it is still queued, move it up.
    private func promote(_ key: String) {
        inFlightPriority[key] = .interactive
        for i in openMeteoWaiters.indices where openMeteoWaiters[i].key == key { openMeteoWaiters[i].priority = .interactive }
    }

    /// Test seam: how many GETs are queued for the Open-Meteo lock (ordering tests wait on this, not sleeps).
    func openMeteoQueueDepth() -> Int { openMeteoWaiters.count }
    /// Tests: how many callers joined an in-flight GET (deterministic instead of a sleep, CR #8 low).
    private(set) var joinedGets = 0
    func joinedGetCount() -> Int { joinedGets }

    private func acquireOpenMeteo(_ priority: FetchPriority, key: String? = nil) async {
        if !openMeteoBusy {
            openMeteoBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            openMeteoWaiters.append((priority, key, cont))
        }
    }

    private func releaseOpenMeteo() {
        if !openMeteoWaiters.isEmpty {
            let i = openMeteoWaiters.firstIndex { $0.priority == .interactive } ?? 0
            openMeteoWaiters.remove(at: i).cont.resume()
        } else {
            openMeteoBusy = false
        }
    }

    /// A host said "slow down": honour its Retry-After (5 s – 1 h), else back off 1, 2, 4 … 30 min.
    private func noteThrottled(_ host: String, retryAfter: TimeInterval?) {
        let strikes = backoffStrikes[host, default: 0]
        backoffStrikes[host] = strikes + 1
        throttleEpoch[host, default: 0] += 1
        let delay = retryAfter.map { min(max($0, 5), 3600) } ?? min(60 * pow(2, Double(min(strikes, 5))), 1800)
        let until = now().addingTimeInterval(delay)
        backoffUntil[host] = until
        SkylineLog.quotaThrottled(host: host, until: until)
    }

    /// When requests to `host` may resume (nil = not backing off). Lets the store time its retry.
    public func backoff(for host: String) -> Date? {
        guard let until = backoffUntil[host], until > now() else { return nil }
        return until
    }

    /// Replaces the pause a forced refresh uses to wait out a short Retry-After.
    func setBackoffSleep(_ sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        backoffSleep = sleep
    }

    /// Test seam: move a host's back-off deadline, including extending it while a wait is in progress.
    func setBackoffForTesting(_ host: String, until: Date) {
        backoffUntil[host] = until
    }

    /// Drops download-cache entries older than `maxAge` (memory and disk). Called once at launch.
    public func pruneCache(olderThan maxAge: TimeInterval = 14 * 86400) async {
        await cache.prune(olderThan: maxAge)
    }

    func fetch(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:],
               maxStale: TimeInterval = .infinity, allowNetwork: Bool? = nil) async throws -> Data {
        try await fetchEntry(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale,
                             allowNetwork: allowNetwork).data
    }

    func optionalFetch(_ url: URL, ttl: TimeInterval, force: Bool, headers: [String: String] = [:],
                       maxStale: TimeInterval = .infinity, allowNetwork: Bool? = nil) async -> Data? {
        try? await fetch(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale,
                         allowNetwork: allowNetwork)
    }

    func optionalFetchEntry(_ url: URL, ttl: TimeInterval, force: Bool, headers: [String: String] = [:],
                            maxStale: TimeInterval = .infinity, allowNetwork: Bool? = nil) async -> Fetched? {
        try? await fetchEntry(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale,
                              allowNetwork: allowNetwork)
    }
}
