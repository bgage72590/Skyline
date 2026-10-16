import Foundation

/// Fetches, caches and blends weather for a location. Thread-safe (actor); de-duplicates
/// concurrent requests for the same location (e.g. menu bar + main window).
public actor WeatherService {
    /// Cache lifetimes. Forecast data only changes when models run, so ~10 min is plenty.
    public enum TTL {
        public static let forecast: TimeInterval = 10 * 60
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
    }

    private let client: HTTPClient
    private let cache: ResponseCache
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<WeatherReport, Error>] = [:]
    /// Hosts that answered 429/503: no requests to them until this time (Retry-After, else 1 → 2 → 4 … min).
    private var backoffUntil: [String: Date] = [:]
    private var backoffStrikes: [String: Int] = [:]
    /// Bumped each time a host throttles us. A success only clears the back-off if no throttle was noted
    /// while it was in flight: NWS requests run concurrently, and a slower success must not cancel a 503
    /// that arrived meanwhile (QA batch 2).
    private var throttleEpoch: [String: Int] = [:]
    /// The pause a forced refresh uses to wait out Retry-After. Production sleeps; tests that drive
    /// `now` jump their clock by the same interval so the suite doesn't wait on the wall clock.
    private var backoffSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// Forecast verification + adaptive weights (nil = fixed weights, nothing recorded; used by tests).
    public nonisolated let verifier: ForecastVerifier?
    /// Recent daily-forecast snapshots for "why the forecast changed" (nil = none kept; used by tests).
    public nonisolated let history: ForecastHistory?

    public init(client: HTTPClient = URLSessionHTTPClient(),
                cache: ResponseCache = ResponseCache(directory: ResponseCache.defaultDirectory()),
                verifier: ForecastVerifier? = nil,
                history: ForecastHistory? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.cache = cache
        self.verifier = verifier
        self.history = history
        self.now = now
    }

    // MARK: Public API

    public func report(for location: WeatherLocation, forceRefresh: Bool = false) async throws -> WeatherReport {
        // The coordinate is part of the key: My Location keeps its id while it moves, and a second fix
        // during a slow load must not get the old place's report (QA #13).
        let key = location.id + "@\(location.coordinate.latitude),\(location.coordinate.longitude)" + (forceRefresh ? "!" : "")
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await self.buildReport(for: location, forceRefresh: forceRefresh) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    public func search(_ query: String) async throws -> [PlaceSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let data = try await fetch(Endpoints.geocoding(q), ttl: TTL.geocoding)
        return try OpenMeteoGeocodingResponse.decode(data)
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
            let past: [RadarFrame]
            if let site {
                // Window on a 5-minute grid so the cached scan list's URL is stable between scans.
                let end = Date(timeIntervalSince1970: ((now().timeIntervalSince1970 / 300).rounded(.down) + 1) * 300)
                let start = end.addingTimeInterval(-Double(range.totalMinutes * 60 + 900))
                let data = try await fetch(IEMRidge.scanListURL(site: site, start: start, end: end), ttl: TTL.radarIndex, force: forceRefresh)
                let scans = try IEMRidge.decodeScans(data)
                // Stale site (down for maintenance): nothing in the last 30 min means no loop.
                guard let last = scans.last, now().timeIntervalSince(last) < 30 * 60 else { return [] }
                latest = last
                past = IEMRidge.frames(site: site, scans: scans, range: range)
            } else {
                let data = try await fetch(Endpoints.iemLatest, ttl: TTL.radarIndex, force: forceRefresh)
                latest = try IEMNexrad.latestValidTime(data) ?? now()
                past = IEMNexrad.frames(latest: latest, range: range)
            }
            guard future,
                  let run = await optionalFetch(Endpoints.iemHRRRLatest, ttl: TTL.hrrrRun, force: false, maxStale: 6 * 3600),
                  let initTime = try? IEMHRRR.initTime(run) else { return past }
            return past + IEMHRRR.frames(initTime: initTime, after: latest)
        }
    }

    /// Latest NEXRAD storm attributes near `location` (strong moving cells only). Cheap GeoJSON; nil on failure.
    public func stormCells(near location: Coordinate, forceRefresh: Bool = false) async -> [StormCell] {
        guard let data = await optionalFetch(Endpoints.iemNexradAttr, ttl: TTL.stormAttr, force: forceRefresh,
                                             maxStale: 10 * 60),
              let all = try? StormMotion.parse(data) else { return [] }
        return StormMotion.relevant(all, near: location)
    }

    // MARK: Assembly

    private func buildReport(for location: WeatherLocation, forceRefresh force: Bool) async throws -> WeatherReport {
        // "My Location" goes out at ~1 km (the store already coarsens the fix; this is defense in depth).
        let coord = location.isCurrentLocation ? location.coordinate.coarse : location.coordinate.rounded
        // US-only sources (HRRR, NWS) follow the border outlines and the saved city's country (QA 4).
        let models = ForecastModel.models(inCONUS: location.isInCONUS)

        async let omFetch = fetchEntry(Endpoints.openMeteoForecast(coord, models: models), ttl: TTL.forecast,
                                       force: force, maxStale: MaxStale.forecast)
        async let aqData = optionalFetch(Endpoints.openMeteoAirQuality(coord), ttl: TTL.airQuality, force: force,
                                         maxStale: MaxStale.airQuality)
        // A remembered /points 404 skips only the forecast lookup; warnings are asked for regardless (L2).
        let inNWSArea = location.isLikelyInNWSCoverage
        let inNWS = inNWSArea ? !(await nwsKnownMissing(coord)) : false
        async let nwsBundle = inNWS ? fetchNWS(coord, force: force) : nil
        // Warnings don't need the /points lookup: fetched on their own so a /points failure (first
        // launch during an NWS hiccup) can't hide them (L2).
        async let alertsFetch = inNWSArea ? fetchAlerts(coord, force: force) : []
        async let outlooksFetch = location.isInCONUS ? fetchOutlooks(coord) : []

        let omEntry = try await omFetch
        let om = try OpenMeteoResponse.decode(omEntry.data)
        guard var current = om.currentConditions() else { throw HTTPError.invalidResponse }
        let nws = await nwsBundle
        let alerts = await alertsFetch
        let air = await aqData.flatMap { try? OpenMeteoAirQualityResponse.decode($0) }
        let outlooks = await outlooksFetch

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
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nws?.hourly ?? [], now: current.time,
                                                 weights: learned, minutely: minutely)
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws?.periods ?? [], timeZone: tz,
                                               weights: learned, hourly: hourly)
        // The headline temperature is the blend (models + NWS) at the current time, not one model's value.
        // "Feels like" keeps its offset from the air temperature.
        if let blended = ForecastBlender.temperature(at: current.time, hourly: hourly) {
            current.apparentTemperature += blended.temperature - current.temperature
            current.temperature = blended.temperature
        }

        // "Why the forecast changed": compare with the outlook from ~12 h ago, then save this one.
        var earlier: ForecastSnapshot?
        if let history, !omEntry.isFallback {
            let t = now()
            earlier = await history.earlier(key, now: t)
            await history.record(key, daily: daily, now: t)
        }

        // Verification runs detached at utility priority: never delays the report.
        if let verifier {
            let issued = now()
            let nwsHourly = nws?.hourly ?? []
            let stations = nws?.point.observationStations
            Task.detached(priority: .utility) {
                if await verifier.wantsIssuance(key) {
                    let records = ForecastSampler.records(location: key, issued: issued, openMeteo: om,
                                                          nwsHourly: nwsHourly, blended: hourly)
                    await verifier.record(records, key: key)
                }
                await verifier.verifyIfDue(key: key, stationsURL: stations)
            }
        }

        var sources = om.modelsWithData.map(\.displayName)
        if let nws, !(nws.periods.isEmpty && nws.hourly.isEmpty) { sources.append("NWS \(nws.point.gridID)") }
        if air != nil { sources.append("Open-Meteo Air Quality (CAMS)") }

        var loc = location
        if loc.timeZoneIdentifier == nil { loc.timeZoneIdentifier = om.timezone }

        // The data is as old as its oldest forecast input (a cached copy keeps its download time).
        let dataAsOf = ([omEntry.storedAt] + (nws?.forecastStoredAt ?? [])).min() ?? omEntry.storedAt
        var report = WeatherReport(location: loc, fetchedAt: now(), timeZoneIdentifier: om.timezone,
                             current: current, hourly: hourly, daily: daily,
                             minutely: minutely, alerts: alerts,
                             airQuality: air, sources: sources,
                             nwsOffice: nws.map { [$0.point.city, $0.point.state].compactMap { $0 }.joined(separator: ", ") },
                             dataAsOf: dataAsOf, isOfflineFallback: omEntry.isFallback)
        report.nwsGridID = nws?.point.gridID
        report.earlierOutlook = earlier
        report.severeOutlooks = outlooks
        report.modelSeries = ForecastBlender.modelSeries(openMeteo: om, nwsHourly: nws?.hourly ?? [], blended: hourly,
                                                         now: current.time)
        return report
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

    /// Fresh cache → network → stale cache no older than `maxStale` (offline fallback) → error.
    /// The result carries the data's real download time, so a cached copy is never passed off as new.
    func fetchEntry(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:],
                    maxStale: TimeInterval = .infinity) async throws -> Fetched {
        let key = url.absoluteString
        if !force, let hit = await cache.entry(key, maxAge: ttl), now().timeIntervalSince(hit.storedAt) < ttl {
            return Fetched(data: hit.data, storedAt: hit.storedAt, isFallback: false)
        }
        let host = url.host ?? ""
        // Banner Retry / toolbar Refresh waits out the host's back-off, then fetches once. Returning the
        // stale copy here is what left "Offline · showing data from …" stuck after Open-Meteo recovered.
        if force, let until = backoffUntil[host], until > now() {
            try await waitOutBackoff(until)
        }
        do {
            if !force, let until = backoffUntil[host], until > now() {
                throw HTTPError.backingOff(host: host, until: until)
            }
            let epoch = throttleEpoch[host, default: 0]
            let data = try await client.get(url, headers: headers)
            if throttleEpoch[host, default: 0] == epoch {
                backoffUntil[host] = nil
                backoffStrikes[host] = nil
            }
            await cache.store(data, for: key)
            return Fetched(data: data, storedAt: now(), isFallback: false)
        } catch {
            if case HTTPError.throttled(_, _, let retryAfter) = error { noteThrottled(host, retryAfter: retryAfter) }
            if let stale = await cache.entry(key, maxAge: maxStale) {
                return Fetched(data: stale.data, storedAt: stale.storedAt, isFallback: true)
            }
            throw error
        }
    }

    /// Sleeps until `until` on the service clock, then the caller fetches once.
    private func waitOutBackoff(_ until: Date) async throws {
        let delay = until.timeIntervalSince(now())
        guard delay > 0 else { return }
        try Task.checkCancellation()
        try await backoffSleep(delay)
    }

    /// A host said "slow down": honour its Retry-After (5 s – 1 h), else back off 1, 2, 4 … 30 min.
    private func noteThrottled(_ host: String, retryAfter: TimeInterval?) {
        let strikes = backoffStrikes[host, default: 0]
        backoffStrikes[host] = strikes + 1
        throttleEpoch[host, default: 0] += 1
        let delay = retryAfter.map { min(max($0, 5), 3600) } ?? min(60 * pow(2, Double(min(strikes, 5))), 1800)
        backoffUntil[host] = now().addingTimeInterval(delay)
    }

    /// When requests to `host` may resume (nil = not backing off). Lets the store time its retry.
    public func backoff(for host: String) -> Date? {
        guard let until = backoffUntil[host], until > now() else { return nil }
        return until
    }

    /// Replaces the pause a forced refresh uses to wait out Retry-After.
    func setBackoffSleep(_ sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        backoffSleep = sleep
    }

    /// Drops download-cache entries older than `maxAge` (memory and disk). Called once at launch.
    public func pruneCache(olderThan maxAge: TimeInterval = 14 * 86400) async {
        await cache.prune(olderThan: maxAge)
    }

    func fetch(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:],
               maxStale: TimeInterval = .infinity) async throws -> Data {
        try await fetchEntry(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale).data
    }

    func optionalFetch(_ url: URL, ttl: TimeInterval, force: Bool, headers: [String: String] = [:],
                       maxStale: TimeInterval = .infinity) async -> Data? {
        try? await fetch(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale)
    }

    func optionalFetchEntry(_ url: URL, ttl: TimeInterval, force: Bool, headers: [String: String] = [:],
                            maxStale: TimeInterval = .infinity) async -> Fetched? {
        try? await fetchEntry(url, ttl: ttl, force: force, headers: headers, maxStale: maxStale)
    }
}
