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

    private let client: HTTPClient
    private let cache: ResponseCache
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<WeatherReport, Error>] = [:]

    public init(client: HTTPClient = URLSessionHTTPClient(),
                cache: ResponseCache = ResponseCache(directory: ResponseCache.defaultDirectory()),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.cache = cache
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
        let coord = location.coordinate.rounded
        let models = ForecastModel.models(for: coord)

        async let omData = fetch(Endpoints.openMeteoForecast(coord, models: models), ttl: TTL.forecast, force: force)
        async let aqData = optionalFetch(Endpoints.openMeteoAirQuality(coord), ttl: TTL.airQuality, force: force)
        async let nwsBundle = coord.isLikelyInNWSCoverage ? fetchNWS(coord, force: force) : nil

        let om = try OpenMeteoResponse.decode(try await omData)
        guard let current = om.currentConditions() else { throw HTTPError.invalidResponse }
        let nws = await nwsBundle
        let air = await aqData.flatMap { try? OpenMeteoAirQualityResponse.decode($0) }

        let tz = TimeZone(identifier: om.timezone) ?? location.timeZone
        let hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nws?.hourly ?? [], now: current.time)
        let daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws?.periods ?? [], timeZone: tz)

        var sources = om.modelsWithData.map(\.displayName)
        if let nws, !(nws.periods.isEmpty && nws.hourly.isEmpty) { sources.append("NWS \(nws.point.gridID)") }
        if air != nil { sources.append("Open-Meteo Air Quality (CAMS)") }

        var loc = location
        if loc.timeZoneIdentifier == nil { loc.timeZoneIdentifier = om.timezone }

        return WeatherReport(location: loc, fetchedAt: now(), timeZoneIdentifier: om.timezone,
                             current: current, hourly: hourly, daily: daily,
                             minutely: om.minutelyPrecipitation(), alerts: nws?.alerts ?? [],
                             airQuality: air, sources: sources,
                             nwsOffice: nws.map { [$0.point.city, $0.point.state].compactMap { $0 }.joined(separator: ", ") })
    }

    struct NWSBundle: Sendable {
        var point: NWSPoint
        var periods: [NWSPeriod]
        var hourly: [NWSPeriod]
        var alerts: [WeatherAlert]
    }

    /// Everything NWS for a point; nil when the point is outside NWS coverage or the API is down.
    private func fetchNWS(_ c: Coordinate, force: Bool) async -> NWSBundle? {
        guard let pointData = await optionalFetch(Endpoints.nwsPoint(c), ttl: TTL.nwsPoint, force: false),
              let point = try? NWSPoint.decode(pointData) else { return nil }
        let headers = ["Accept": "application/geo+json"]
        async let f = optionalFetch(point.forecastURL, ttl: TTL.nwsForecast, force: force, headers: headers)
        async let h = optionalFetch(point.forecastHourlyURL, ttl: TTL.nwsForecast, force: force, headers: headers)
        async let a = optionalFetch(Endpoints.nwsAlerts(c), ttl: TTL.alerts, force: force, headers: headers)
        let periods = await f.flatMap { try? NWSPeriod.decodeList($0) } ?? []
        let hourly = await h.flatMap { try? NWSPeriod.decodeList($0) } ?? []
        var alerts = await a.flatMap { try? NWSAlertParser.decode($0) } ?? []
        alerts = await withZoneOutlines(alerts)
        return NWSBundle(point: point, periods: periods, hourly: hourly, alerts: alerts)
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

    /// Fresh cache → network → stale cache (offline fallback) → error.
    func fetch(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:]) async throws -> Data {
        let key = url.absoluteString
        if !force, let hit = await cache.fresh(key, maxAge: ttl) { return hit }
        do {
            let data = try await client.get(url, headers: headers)
            await cache.store(data, for: key)
            return data
        } catch {
            if let stale = await cache.stale(key) { return stale }
            throw error
        }
    }

    func optionalFetch(_ url: URL, ttl: TimeInterval, force: Bool, headers: [String: String] = [:]) async -> Data? {
        try? await fetch(url, ttl: ttl, force: force, headers: headers)
    }
}
