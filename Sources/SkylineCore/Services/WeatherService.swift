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

    /// Pause before the one immediate re-try of a GET that died in flight (`FallbackCause.retriesOnce`).
    private var transientRetryDelay: TimeInterval = 0.5
    func setTransientRetryDelay(_ seconds: TimeInterval) { transientRetryDelay = seconds }

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

    public func report(for location: WeatherLocation, forceRefresh: Bool = false,
                       priority: FetchPriority = .background) async throws -> WeatherReport {
        // The coordinate is part of the key: My Location keeps its id while it moves, and a second fix
        // during a slow load must not get the old place's report (QA #13).
        let key = location.id + "@\(location.coordinate.latitude),\(location.coordinate.longitude)" + (forceRefresh ? "!" : "")
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await self.buildReport(for: location, forceRefresh: forceRefresh, priority: priority) }
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

    // MARK: Assembly

    private func buildReport(for location: WeatherLocation, forceRefresh force: Bool,
                             priority: FetchPriority = .background) async throws -> WeatherReport {
        // "My Location" goes out at ~1 km (the store already coarsens the fix; this is defense in depth).
        let coord = location.isCurrentLocation ? location.coordinate.coarse : location.coordinate.rounded
        // US-only sources (HRRR, NWS) follow the border outlines and the saved city's country (QA 4).
        let models = ForecastModel.models(inCONUS: location.isInCONUS)

        async let omFetch = fetchEntry(Endpoints.openMeteoForecast(coord, models: models), ttl: TTL.forecast,
                                       force: force, maxStale: MaxStale.forecast,
                                       priority: force ? .interactive : priority)
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
        var hourly = ForecastBlender.blendHourly(openMeteo: om, nwsHourly: nws?.hourly ?? [], now: current.time,
                                                 weights: learned, minutely: minutely)
        // Daily is built from the RAW hourly (lock §2); correction applies after.
        var daily = ForecastBlender.blendDaily(openMeteo: om, nwsPeriods: nws?.periods ?? [], timeZone: tz,
                                               weights: learned, hourly: hourly)
        // Accuracy PR 2: one apply point after blendDaily, before headline. Raw series go to measurement.
        let rawHourly = hourly
        let rawDaily = daily
        let issuedNow = now()
        if let verifier {
            if let offsets = await verifier.correctionIfLoaded(key),
               offsets.values.contains(where: { abs($0) > 1e-12 }) {
                BiasCorrection.apply(hourly: &hourly, daily: &daily, current: &current,
                                     issued: issuedNow, timeZone: tz, offsets: offsets)
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
        // The header's "Rain" agrees with the 15-minute nowcast (dropdown review S3).
        // reconcileCurrent sees the corrected temperature (B8 knock-on).
        current.weatherCode = Nowcast.reconcileCurrent(code: current.weatherCode, minutely: minutely, now: now(),
                                                       temperature: current.temperature)

        // "Why the forecast changed": compare with the outlook from ~12 h ago, then save this one.
        // history.record stores what the user saw (corrected).
        var earlier: ForecastSnapshot?
        if let history, !omEntry.isFallback {
            let t = now()
            earlier = await history.earlier(key, now: t)
            await history.record(key, daily: daily, now: t)
        }

        // Verification runs detached at utility priority: never delays the report.
        // Issuance + measurement use RAW (uncorrected) hourly/daily so learning has no feedback loop (B5).
        if let verifier {
            let issued = issuedNow
            let nwsHourly = nws?.hourly ?? []
            let stations = nws?.point.observationStations
            let measureTZ = om.timezone
            let measureDaily = rawDaily
            let measureHourly = rawHourly
            let measureCoord = coord
            let measureIsUS = location.isLikelyInNWSCoverage
            let measureElev = om.elevation
            Task.detached(priority: .utility) {
                if await verifier.wantsIssuance(key) {
                    let records = ForecastSampler.records(location: key, issued: issued, openMeteo: om,
                                                          nwsHourly: nwsHourly, blended: measureHourly)
                    await verifier.record(records, key: key)
                }
                await verifier.verifyIfDue(key: key, stationsURL: stations, near: coord,
                                           cityElevationM: measureElev)
                await verifier.runMeasurement(key: key, coordinate: measureCoord, timeZoneIdentifier: measureTZ,
                                              daily: measureDaily, openMeteo: om, blended: measureHourly,
                                              isUS: measureIsUS, cityElevationM: measureElev)
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
        report.forecastAsOf = omEntry.storedAt
        report.fallbackCause = omEntry.isFallback ? (omEntry.cause ?? .unreachable) : nil
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

    /// How long a forced refresh (banner Retry, toolbar Refresh) may sleep. Longer than this, the
    /// store schedules a retry and leaves Refresh usable instead of pinning the spinner.
    static let forceWaitCap: TimeInterval = 30

    /// Fresh cache → network → stale cache no older than `maxStale` (offline fallback) → error.
    /// The result carries the data's real download time, so a cached copy is never passed off as new.
    func fetchEntry(_ url: URL, ttl: TimeInterval, force: Bool = false, headers: [String: String] = [:],
                    maxStale: TimeInterval = .infinity, priority: FetchPriority = .background) async throws -> Fetched {
        let key = url.absoluteString
        if !force, let hit = await cache.entry(key, maxAge: ttl), now().timeIntervalSince(hit.storedAt) < ttl {
            return Fetched(data: hit.data, storedAt: hit.storedAt, isFallback: false)
        }
        let host = url.host ?? ""
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
                let epoch = throttleEpoch[host, default: 0]
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
                await cache.store(data, for: key)
                return Fetched(data: data, storedAt: now(), isFallback: false)
            } catch {
                if waits, case HTTPError.backingOff = error { throw error }
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
        let gate = host == RefreshBookkeeping.openMeteoHost
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
        backoffUntil[host] = now().addingTimeInterval(delay)
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
