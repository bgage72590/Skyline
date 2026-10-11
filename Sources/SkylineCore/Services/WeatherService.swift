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
    /// Forecast verification + adaptive weights (nil = fixed weights, nothing recorded; used by tests).
    public nonisolated let verifier: ForecastVerifier?

    public init(client: HTTPClient = URLSessionHTTPClient(),
                cache: ResponseCache = ResponseCache(directory: ResponseCache.defaultDirectory()),
                verifier: ForecastVerifier? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.cache = cache
        self.verifier = verifier
        self.now = now
    }

    // MARK: Public API

    public func report(for location: WeatherLocation, forceRefresh: Bool = false) async throws -> WeatherReport {
        let key = location.id + (forceRefresh ? "!" : "")
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

    public func radarFrames(_ provider: RadarProvider, range: RadarRange = .oneHour,
                            forceRefresh: Bool = false) async throws -> [RadarFrame] {
        switch provider {
        case .rainViewer:
            let data = try await fetch(Endpoints.rainViewerMaps, ttl: TTL.radarIndex, force: forceRefresh)
            return try RainViewerParser.decode(data)
        case .nexrad:
            let data = try await fetch(Endpoints.iemLatest, ttl: TTL.radarIndex, force: forceRefresh)
            let latest = try IEMNexrad.latestValidTime(data) ?? now()
            return IEMNexrad.frames(latest: latest, range: range)
        }
    }

    // MARK: Assembly

    private func buildReport(for location: WeatherLocation, forceRefresh force: Bool) async throws -> WeatherReport {
        // "My Location" goes out at ~1 km (the store already coarsens the fix; this is defense in depth).
        let coord = location.isCurrentLocation ? location.coordinate.coarse : location.coordinate.rounded
        let models = ForecastModel.models(for: coord)

        async let omFetch = fetchEntry(Endpoints.openMeteoForecast(coord, models: models), ttl: TTL.forecast,
                                       force: force, maxStale: MaxStale.forecast)
        async let aqData = optionalFetch(Endpoints.openMeteoAirQuality(coord), ttl: TTL.airQuality, force: force,
                                         maxStale: MaxStale.airQuality)
        async let nwsBundle = coord.isLikelyInNWSCoverage ? fetchNWS(coord, force: force) : nil

        let omEntry = try await omFetch
        let om = try OpenMeteoResponse.decode(omEntry.data)
        guard var current = om.currentConditions() else { throw HTTPError.invalidResponse }
        let nws = await nwsBundle
        let air = await aqData.flatMap { try? OpenMeteoAirQualityResponse.decode($0) }

        let tz = TimeZone(identifier: om.timezone) ?? location.timeZone
        let key = VerificationKey.key(for: location)
        let learned = await verifier?.weights(key) ?? .neutral
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
        return WeatherReport(location: loc, fetchedAt: now(), timeZoneIdentifier: om.timezone,
                             current: current, hourly: hourly, daily: daily,
                             minutely: minutely, alerts: nws?.alerts ?? [],
                             airQuality: air, sources: sources,
                             nwsOffice: nws.map { [$0.point.city, $0.point.state].compactMap { $0 }.joined(separator: ", ") },
                             dataAsOf: dataAsOf, isOfflineFallback: omEntry.isFallback)
    }

    struct NWSBundle: Sendable {
        var point: NWSPoint
        var periods: [NWSPeriod]
        var hourly: [NWSPeriod]
        var alerts: [WeatherAlert]
        /// Download times of the NWS forecasts that were used.
        var forecastStoredAt: [Date] = []
    }

    /// Everything NWS for a point; nil when the point is outside NWS coverage or the API is down.
    private func fetchNWS(_ c: Coordinate, force: Bool) async -> NWSBundle? {
        guard let pointData = await optionalFetch(Endpoints.nwsPoint(c), ttl: TTL.nwsPoint, force: false),
              let point = try? NWSPoint.decode(pointData) else { return nil }
        let headers = ["Accept": "application/geo+json"]
        async let f = optionalFetchEntry(point.forecastURL, ttl: TTL.nwsForecast, force: force, headers: headers,
                                         maxStale: MaxStale.nwsForecast)
        async let h = optionalFetchEntry(point.forecastHourlyURL, ttl: TTL.nwsForecast, force: force, headers: headers,
                                         maxStale: MaxStale.nwsForecast)
        async let a = optionalFetch(Endpoints.nwsAlerts(c), ttl: TTL.alerts, force: force, headers: headers,
                                    maxStale: MaxStale.alerts)
        let t = now()
        // Out-of-date NWS forecasts (old cached copies, or a "stuck" NWS grid) are ignored, not blended.
        func recentPeriods(_ e: Fetched?) -> [NWSPeriod]? {
            guard let e, NWSPeriod.isRecent(NWSPeriod.issuance(e.data), downloadedAt: e.storedAt, now: t) else { return nil }
            return try? NWSPeriod.decodeList(e.data)
        }
        let fEntry = await f, hEntry = await h
        let periods = recentPeriods(fEntry) ?? []
        let hourly = recentPeriods(hEntry) ?? []
        var alerts = await a.flatMap { try? NWSAlertParser.decode($0, now: t) } ?? []
        alerts = await withZoneOutlines(alerts)
        var storedAt: [Date] = []
        if !periods.isEmpty, let fEntry { storedAt.append(fEntry.storedAt) }
        if !hourly.isEmpty, let hEntry { storedAt.append(hEntry.storedAt) }
        return NWSBundle(point: point, periods: periods, hourly: hourly, alerts: alerts, forecastStoredAt: storedAt)
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
        do {
            if let until = backoffUntil[host], until > now() { throw HTTPError.backingOff(host: host, until: until) }
            let data = try await client.get(url, headers: headers)
            backoffUntil[host] = nil
            backoffStrikes[host] = nil
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

    /// A host said "slow down": honour its Retry-After (5 s – 1 h), else back off 1, 2, 4 … 30 min.
    private func noteThrottled(_ host: String, retryAfter: TimeInterval?) {
        let strikes = backoffStrikes[host, default: 0]
        backoffStrikes[host] = strikes + 1
        let delay = retryAfter.map { min(max($0, 5), 3600) } ?? min(60 * pow(2, Double(min(strikes, 5))), 1800)
        backoffUntil[host] = now().addingTimeInterval(delay)
    }

    /// When requests to `host` may resume (nil = not backing off). Lets the store time its retry.
    public func backoff(for host: String) -> Date? {
        guard let until = backoffUntil[host], until > now() else { return nil }
        return until
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
