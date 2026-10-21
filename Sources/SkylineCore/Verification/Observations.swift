import Foundation

/// One NWS station observation (api.weather.gov `/stations/{id}/observations`).
public struct StationObservation: Hashable, Sendable {
    public var time: Date
    public var temperatureC: Double?
    public var windKmh: Double?
    /// Precipitation for the last hour (mm), reported only by some (hourly) METARs.
    public var precipLastHourMM: Double?
    /// True when present weather includes falling precipitation (rain, drizzle, snow, storms, ice…).
    public var precipitating: Bool

    public init(time: Date, temperatureC: Double?, windKmh: Double?, precipLastHourMM: Double?, precipitating: Bool) {
        self.time = time; self.temperatureC = temperatureC; self.windKmh = windKmh
        self.precipLastHourMM = precipLastHourMM; self.precipitating = precipitating
    }
}

public enum NWSObservationParser {
    struct Raw: Decodable {
        struct Value: Decodable { var value: Double?; var unitCode: String? }
        struct Weather: Decodable { var weather: String? }
        struct Props: Decodable {
            var timestamp: String
            var temperature: Value?
            var windSpeed: Value?
            var precipitationLastHour: Value?
            var presentWeather: [Weather]?
        }
        struct Feature: Decodable { var properties: Props }
        var features: [Feature]
    }

    static let precipitationKinds: Set<String> = [
        "rain", "drizzle", "snow", "snow_grains", "ice_crystals", "ice_pellets", "hail", "small_hail",
        "snow_pellets", "thunderstorms", "rain_showers", "snow_showers", "unknown_precipitation", "freezing_rain",
        "freezing_drizzle",
    ]

    /// Oldest first. Wind in m/s or knots is converted to km/h.
    public static func decode(_ data: Data) throws -> [StationObservation] {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return raw.features.compactMap { f -> StationObservation? in
            let p = f.properties
            guard let time = NWSDate.parse(p.timestamp) else { return nil }
            var wind = p.windSpeed?.value
            if let w = wind, let unit = p.windSpeed?.unitCode {
                if unit.hasSuffix("m_s-1") { wind = w * 3.6 } else if unit.hasSuffix("kn") || unit.hasSuffix("knot") { wind = w * 1.852 }
            }
            let precipitating = (p.presentWeather ?? []).contains { w in
                guard let kind = w.weather else { return false }
                return precipitationKinds.contains(kind) || kind.contains("rain") || kind.contains("snow") || kind.contains("drizzle")
            }
            return StationObservation(time: time, temperatureC: p.temperature?.value, windKmh: wind,
                                      precipLastHourMM: p.precipitationLastHour?.value, precipitating: precipitating)
        }
        .sorted { $0.time < $1.time }
    }

    struct GridpointStation {
        var id: String
        var name: String?
        var provider: String?
        var coordinate: Coordinate?
    }

    /// First station id from a gridpoint `/stations` list. Kept for the no-ASOS fallback.
    public static func firstStation(_ data: Data) throws -> (id: String, name: String?)? {
        let list = try gridpointStations(data)
        return list.first.map { ($0.id, $0.name) }
    }

    /// Nearest ASOS airport on the gridpoint list (great-circle to `point`).
    /// An ASOS airport has an ICAO-style METAR id, an NWS provider of `ASOS` / `ASOS-…`, and an airport name.
    /// When none is present, returns the first station — the previous behavior.
    public static func verificationStation(_ data: Data, near point: Coordinate?) throws -> (id: String, name: String?)? {
        let list = try gridpointStations(data)
        guard let first = list.first else { return nil }
        let airports = list.filter { isASOSAirport($0) }
        guard let point, !airports.isEmpty else { return (first.id, first.name) }
        let located = airports.filter { $0.coordinate != nil }
        let pool = located.isEmpty ? airports : located
        let best = pool.min { a, b in
            guard let ac = a.coordinate, let bc = b.coordinate else { return false }
            return NexradStation.distanceKm(point, ac) < NexradStation.distanceKm(point, bc)
        }
        let chosen = best ?? first
        return (chosen.id, chosen.name)
    }

    /// ICAO-style METAR id (`KNYC`, `KLGA`, `K12N`) whose NWS `provider` is ASOS and whose name is an airport.
    /// Central Park (`KNYC`, ASOS, not an airport) and HADS/RAWS ids (`SFOC1`) do not qualify.
    public static func isASOSAirport(id: String, provider: String?, name: String?) -> Bool {
        let ident = id.uppercased()
        guard ident.range(of: "^[A-Z][A-Z0-9]{3}$", options: .regularExpression) != nil else { return false }
        let prov = (provider ?? "").uppercased()
        guard prov == "ASOS" || prov.hasPrefix("ASOS-") || prov.hasPrefix("ASOS ") else { return false }
        return isAirportName(name ?? "")
    }

    static func isASOSAirport(_ station: GridpointStation) -> Bool {
        isASOSAirport(id: station.id, provider: station.provider, name: station.name)
    }

    /// Airport wording used by api.weather.gov station names (plus naval air stations and airparks).
    static func isAirportName(_ name: String) -> Bool {
        let n = name.lowercased()
        let phrases = ["airport", "airpark", "airfield", "air field", "air force", "air station", "airbase", "air base", "flight"]
        if phrases.contains(where: { n.contains($0) }) { return true }
        let words = n.split { !$0.isLetter }.map(String.init)
        return words.contains("field") || words.contains("afb") || words.contains("aaf")
    }

    static func gridpointStations(_ data: Data) throws -> [GridpointStation] {
        struct List: Decodable {
            struct Geom: Decodable { var coordinates: [Double]? }
            struct F: Decodable {
                struct P: Decodable {
                    var stationIdentifier: String?
                    var name: String?
                    var provider: String?
                }
                var properties: P
                var geometry: Geom?
            }
            var features: [F]
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.features.compactMap { f in
            guard let id = f.properties.stationIdentifier, !id.isEmpty else { return nil }
            var coordinate: Coordinate?
            if let c = f.geometry?.coordinates, c.count >= 2 {
                coordinate = Coordinate(latitude: c[1], longitude: c[0])
            }
            return GridpointStation(id: id, name: f.properties.name, provider: f.properties.provider, coordinate: coordinate)
        }
    }
}

/// Turns raw station observations into one `ObservedHour` per forecast valid hour.
public enum ObservationAggregator {
    /// Window used for instantaneous values (temperature, wind) around the valid time.
    public static let instantTolerance: TimeInterval = 20 * 60

    /// - Returns: nil when there are no usable observations near this hour.
    public static func observe(_ obs: [StationObservation], validTime v: Date) -> ObservedHour? {
        func nearest(_ value: (StationObservation) -> Double?) -> Double? {
            obs.filter { abs($0.time.timeIntervalSince(v)) <= instantTolerance && value($0) != nil }
                .min { abs($0.time.timeIntervalSince(v)) < abs($1.time.timeIntervalSince(v)) }
                .flatMap(value)
        }
        let t = nearest(\.temperatureC)
        let w = nearest(\.windKmh)
        // Precipitation for the hour ending at v (Open-Meteo convention).
        let hour = obs.filter { $0.time > v.addingTimeInterval(-3600) && $0.time <= v.addingTimeInterval(10 * 60) }
        let amount = obs.filter { abs($0.time.timeIntervalSince(v)) <= 15 * 60 }.compactMap(\.precipLastHourMM).max()
        var wet: Bool?
        if hour.count >= 3 || amount != nil {
            let fraction = hour.isEmpty ? 0 : Double(hour.filter(\.precipitating).count) / Double(hour.count)
            wet = (amount ?? 0) >= 0.2 || fraction >= 0.25
        }
        guard t != nil || w != nil || wet != nil else { return nil }
        return ObservedHour(t: t, w: w, wet: wet, p: amount)
    }
}

// MARK: Accuracy PR 1 — METAR text + local-day high/low (feeds the isolated benchmark store only)

/// Parses METAR / SPECI raw text into fields used by the benchmark store. Never crashes on garbage.
public enum METARParser {
    /// Wet present-weather tokens (intensity prefix optional). Vicinity (`VC`), recent (`RE`) and `NSW` are not wet.
    public static let wetTokens: Set<String> = [
        "RA", "DZ", "SN", "SG", "PL", "GR", "GS", "SH", "TS", "FZ",
    ]

    public struct Parsed: Hashable, Sendable {
        public var temperatureC: Double?
        public var windKmh: Double?
        public var wet: Bool?
        public var stationID: String?
        public var time: Date?
    }

    /// Parse one raw METAR/SPECI string. Missing / `////` / garbled fields → nil; record may still be kept.
    public static func parse(_ raw: String, reference: Date = Date()) -> Parsed {
        var out = Parsed()
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return out }
        var tokens = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.first == "METAR" || tokens.first == "SPECI" { tokens.removeFirst() }
        if tokens.first == "COR" { tokens.removeFirst() }
        if let id = tokens.first, id.range(of: "^[A-Z][A-Z0-9]{3}$", options: .regularExpression) != nil {
            out.stationID = id
            tokens.removeFirst()
        }
        if let t = tokens.first, t.count >= 6, t.hasSuffix("Z"), let day = Int(t.prefix(2)),
           let hour = Int(t.dropFirst(2).prefix(2)), let minute = Int(t.dropFirst(4).prefix(2)),
           (0...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) {
            out.time = metarTime(day: day, hour: hour, minute: minute, reference: reference)
            tokens.removeFirst()
        }
        if tokens.first == "AUTO" { tokens.removeFirst() }

        for tok in tokens {
            if out.windKmh == nil, let w = parseWind(tok) { out.windKmh = w }
            if out.temperatureC == nil, let t = parseTempDew(tok) { out.temperatureC = t }
            if tok == "CAVOK" { if out.wet == nil { out.wet = false } }
            if tok == "NSW" { out.wet = false; continue }
            if tok.hasPrefix("RE") { // recent weather: not wet for verification
                if out.wet == nil { out.wet = false }
                continue
            }
            if tok.hasPrefix("VC") { // vicinity: not wet at the station
                if out.wet == nil { out.wet = false }
                continue
            }
            if isWetToken(tok) { out.wet = true }
        }
        return out
    }

    public static func isWetToken(_ tok: String) -> Bool {
        var t = tok
        if t.hasPrefix("+") || t.hasPrefix("-") { t = String(t.dropFirst()) }
        if t.hasPrefix("VC") || t.hasPrefix("RE") { return false }
        if t == "NSW" { return false }
        // Match any wet descriptor present in the group (TSRA, SHRA, FZDZ, +SN, …).
        for i in wetTokens {
            if t.contains(i) { return true }
        }
        return false
    }

    /// Wind group → mean speed in km/h. Gusts ignored. `00000KT` = 0; `VRB` direction accepted.
    public static func parseWind(_ tok: String) -> Double? {
        let u = tok.uppercased()
        let unit: Double
        let body: String
        if u.hasSuffix("KT") { unit = 1.852; body = String(u.dropLast(2)) }
        else if u.hasSuffix("MPS") { unit = 3.6; body = String(u.dropLast(3)) }
        else if u.hasSuffix("KMH") { unit = 1.0; body = String(u.dropLast(3)) }
        else { return nil }
        // dddss or VRBss, optional Ggg gust (ignored for the mean).
        let core = body.split(separator: "G", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? body
        guard core.count >= 5 else { return nil }
        let dir = String(core.prefix(3))
        let spd = String(core.dropFirst(3))
        guard dir == "VRB" || (Int(dir) != nil) else { return nil }
        guard let speed = Double(spd), speed.isFinite else { return nil }
        return speed * unit
    }

    /// `tt/dd` with `M` for negatives; `////` → nil.
    public static func parseTempDew(_ tok: String) -> Double? {
        let parts = tok.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return parseTempToken(parts[0])
    }

    public static func parseTempToken(_ s: String) -> Double? {
        if s.isEmpty || s.contains("/") || s.allSatisfy({ $0 == "/" }) { return nil }
        var t = s
        var sign = 1.0
        if t.hasPrefix("M") { sign = -1; t = String(t.dropFirst()) }
        guard let v = Double(t), v.isFinite else { return nil }
        return sign * v
    }

    static func metarTime(day: Int, hour: Int, minute: Int, reference: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = cal.dateComponents([.year, .month, .day], from: reference)
        c.day = day; c.hour = hour; c.minute = minute; c.second = 0
        guard var d = cal.date(from: c) else { return nil }
        // METAR day-of-month can wrap relative to reference month.
        if d > reference.addingTimeInterval(2 * 86400) { d = cal.date(byAdding: .month, value: -1, to: d) ?? d }
        if d < reference.addingTimeInterval(-40 * 86400) { d = cal.date(byAdding: .month, value: 1, to: d) ?? d }
        return d
    }
}

/// Aggregates observations into a city's local-calendar-day high/low (Accuracy PR 1).
public enum LocalDayAggregator {
    /// Minimum distinct local hours with a temperature before a day can be scored.
    public static let minDistinctHours = 20
    /// Extra margin after local midnight before scoring the finished day.
    public static let endMargin: TimeInterval = 30 * 60

    public struct Window: Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var localDay: Date
    }

    /// Local midnight … next local midnight for `day` in `timeZone`. Handles 23 h / 25 h DST days.
    public static func window(forDay day: Date, timeZone: TimeZone) -> Window {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return Window(start: start, end: end, localDay: start)
    }

    /// True when the local day has fully ended (plus margin) relative to `now`.
    public static func isComplete(_ window: Window, now: Date) -> Bool {
        now >= window.end.addingTimeInterval(endMargin)
    }

    /// Distinct local hours that have at least one temperature sample (5-minute NWS / half-hourly METAR
    /// cannot inflate the count).
    public static func distinctHours(temps: [(Date, Double)], window: Window, timeZone: TimeZone) -> Set<Int> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var hours: Set<Int> = []
        for (t, _) in temps where t >= window.start && t < window.end {
            let h = cal.component(.hour, from: t)
            hours.insert(h)
        }
        return hours
    }

    /// High/low from temperatures in the local day window. Requires ≥ `minDistinctHours` distinct hours.
    public static func extremes(temps: [(Date, Double)], day: Date, timeZone: TimeZone,
                                now: Date) -> (high: Double, low: Double, hours: Int)? {
        let w = window(forDay: day, timeZone: timeZone)
        guard isComplete(w, now: now) else { return nil }
        let inDay = temps.filter { $0.0 >= w.start && $0.0 < w.end }
        let hours = distinctHours(temps: inDay, window: w, timeZone: timeZone)
        guard hours.count >= minDistinctHours else { return nil }
        let values = inDay.map(\.1).filter(\.isFinite)
        guard let hi = values.max(), let lo = values.min() else { return nil }
        return (hi, lo, hours.count)
    }
}
