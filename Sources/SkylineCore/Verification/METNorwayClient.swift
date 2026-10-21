import Foundation

/// Fetches MET Norway Locationforecast 2.0 compact for the forecast benchmark (Accuracy PR 1).
/// Conditional cache via If-Modified-Since / Expires. Never throws into the UI path.
public enum METNorwayClient {
    public static let attribution = "Data: MET Norway, CC BY 4.0"

    public struct FetchOutcome: Sendable {
        public var hours: [MetNorwayHour]
        public var lastModified: String?
        public var expires: Date?
        public var notModified: Bool
        public var deprecated: Bool
        public var body: Data

        public init(hours: [MetNorwayHour], lastModified: String?, expires: Date?, notModified: Bool,
                    deprecated: Bool, body: Data) {
            self.hours = hours; self.lastModified = lastModified; self.expires = expires
            self.notModified = notModified; self.deprecated = deprecated; self.body = body
        }
    }

    /// Parse compact JSON. Malformed → empty hours (never crash).
    public static func decode(_ data: Data) -> [MetNorwayHour] {
        guard !data.isEmpty else { return [] }
        struct Root: Decodable {
            struct Props: Decodable {
                var timeseries: [Series]?
            }
            struct Series: Decodable {
                var time: String
                var data: Payload?
            }
            struct Payload: Decodable {
                var instant: Instant?
                var next_1_hours: Period?
                var next_6_hours: Period?
            }
            struct Instant: Decodable { var details: Details? }
            struct Period: Decodable { var details: Details? }
            struct Details: Decodable {
                var air_temperature: Double?
                var wind_speed: Double?
                var precipitation_amount: Double?
                var air_temperature_max: Double?
                var air_temperature_min: Double?
            }
            var properties: Props?
        }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        return (root.properties?.timeseries ?? []).compactMap { s -> MetNorwayHour? in
            let time = iso.date(from: s.time) ?? isoBasic.date(from: s.time) ?? NWSDate.parse(s.time)
            guard let time else { return nil }
            let instant = s.data?.instant?.details
            let next1 = s.data?.next_1_hours?.details
            let next6 = s.data?.next_6_hours?.details
            // MET Norway wind_speed is m/s → km/h.
            let wind = instant?.wind_speed.map { $0 * 3.6 }
            return MetNorwayHour(time: time, temperatureC: instant?.air_temperature, windKmh: wind,
                                 precipMM: next1?.precipitation_amount,
                                 highC: next6?.air_temperature_max, lowC: next6?.air_temperature_min)
        }
    }

    /// Fetch or reuse cache. Honours Expires (no request before) and If-Modified-Since on 304.
    public static func fetch(coordinate: Coordinate, loc: String, client: HTTPClient,
                             cached: MetNorwayCacheEntry?, now: Date) async -> FetchOutcome? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        if let cached, let exp = cached.expires, now < exp {
            return FetchOutcome(hours: cached.hourly, lastModified: cached.lastModified, expires: cached.expires,
                                notModified: true, deprecated: false, body: cached.body)
        }
        let url = Endpoints.metNorwayCompact(coordinate)
        var headers: [String: String] = ["Accept": "application/json"]
        if let lm = cached?.lastModified {
            headers["If-Modified-Since"] = lm
        }
        do {
            let result = try await client.fetch(url, headers: headers)
            if result.statusCode == 429 || result.statusCode == 503 {
                return nil
            }
            if result.statusCode == 403 || result.statusCode >= 500 {
                return nil
            }
            if result.isNotModified, let cached {
                return FetchOutcome(hours: cached.hourly, lastModified: cached.lastModified,
                                    expires: parseHTTPDate(result.expires) ?? cached.expires,
                                    notModified: true, deprecated: result.isDeprecated, body: cached.body)
            }
            if result.isNoContent { return nil }
            let hours = decode(result.data)
            guard !hours.isEmpty || result.isDeprecated else {
                // Malformed JSON with non-empty body: treat as soft failure.
                if (try? JSONSerialization.jsonObject(with: result.data)) == nil { return nil }
                return FetchOutcome(hours: [], lastModified: result.lastModified,
                                    expires: parseHTTPDate(result.expires), notModified: false,
                                    deprecated: result.isDeprecated, body: result.data)
            }
            return FetchOutcome(hours: hours, lastModified: result.lastModified,
                                expires: parseHTTPDate(result.expires), notModified: false,
                                deprecated: result.isDeprecated, body: result.data)
        } catch {
            return nil
        }
    }

    public static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value)
    }

    /// Daily high/low from MET Norway hours falling on a local calendar day.
    public static func dailyExtremes(hours: [MetNorwayHour], day: Date, timeZone: TimeZone) -> (high: Double, low: Double)? {
        let w = LocalDayAggregator.window(forDay: day, timeZone: timeZone)
        let temps = hours.compactMap { h -> Double? in
            guard h.time >= w.start && h.time < w.end else { return nil }
            return h.temperatureC
        }.filter(\.isFinite)
        // Prefer explicit 6h max/min when present on the day.
        let hi6 = hours.compactMap { h -> Double? in
            guard h.time >= w.start && h.time < w.end else { return nil }
            return h.highC
        }.filter(\.isFinite)
        let lo6 = hours.compactMap { h -> Double? in
            guard h.time >= w.start && h.time < w.end else { return nil }
            return h.lowC
        }.filter(\.isFinite)
        let high = hi6.max() ?? temps.max()
        let low = lo6.min() ?? temps.min()
        guard let high, let low else { return nil }
        return (high, low)
    }
}
