import Foundation

/// Fetches and parses aviationweather.gov METARs / station info for non-US verification (Accuracy PR 1).
/// All work is intended for the verifier actor or detached utility tasks — never the main thread.
public enum METARClient {
    public static let maxStationDistanceKm = 50.0
    public static let stationCacheDays = 7.0
    public static let batchInterval: TimeInterval = 3600
    /// Hard ceiling: AWC asks for ≤ 100 requests/min.
    public static let maxRequestsPerMinute = 100

    public struct StationInfo: Hashable, Sendable {
        public var id: String
        public var name: String?
        public var coordinate: Coordinate
        public var elevationM: Double?
        /// AWC `siteType` values such as `METAR` and `TAF`. Nil when the payload omits the field.
        public var siteTypes: [String]?

        public init(id: String, name: String? = nil, coordinate: Coordinate, elevationM: Double? = nil,
                    siteTypes: [String]? = nil) {
            self.id = id; self.name = name; self.coordinate = coordinate; self.elevationM = elevationM
            self.siteTypes = siteTypes
        }
    }

    /// Decode AWC `stationinfo` JSON. Unknown / missing keys are skipped; never throws on partial rows.
    public static func decodeStations(_ data: Data) -> [StationInfo] {
        guard !data.isEmpty else { return [] }
        struct Row: Decodable {
            var icaoId: String?
            var id: String?
            var site: String?
            var name: String?
            var lat: Double?
            var lon: Double?
            var elev: Double?
            // Some payloads encode lat/lon as strings.
            var latString: String?
            var lonString: String?
            var siteType: [String]?

            enum CodingKeys: String, CodingKey {
                case icaoId, id, site, name, lat, lon, elev, siteType
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                icaoId = try c.decodeIfPresent(String.self, forKey: .icaoId)
                id = try c.decodeIfPresent(String.self, forKey: .id)
                site = try c.decodeIfPresent(String.self, forKey: .site)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                if let d = try? c.decodeIfPresent(Double.self, forKey: .lat) { lat = d }
                else if let s = try? c.decodeIfPresent(String.self, forKey: .lat) { lat = Double(s) }
                if let d = try? c.decodeIfPresent(Double.self, forKey: .lon) { lon = d }
                else if let s = try? c.decodeIfPresent(String.self, forKey: .lon) { lon = Double(s) }
                if let d = try? c.decodeIfPresent(Double.self, forKey: .elev) { elev = d }
                else if let i = try? c.decodeIfPresent(Int.self, forKey: .elev) { elev = Double(i) }
                else if let s = try? c.decodeIfPresent(String.self, forKey: .elev) { elev = Double(s) }
                if c.contains(.siteType) {
                    if let one = try? c.decode(String.self, forKey: .siteType) { siteType = [one] }
                    else if let many = try? c.decode([String].self, forKey: .siteType) { siteType = many }
                    else { siteType = nil }
                } else {
                    siteType = nil
                }
            }
        }
        let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
        return rows.compactMap { r in
            let ident = (r.icaoId ?? r.id ?? "").uppercased()
            guard ident.range(of: "^[A-Z][A-Z0-9]{3}$", options: .regularExpression) != nil,
                  let lat = r.lat, let lon = r.lon, lat.isFinite, lon.isFinite else { return nil }
            return StationInfo(id: ident, name: r.site ?? r.name,
                               coordinate: Coordinate(latitude: lat, longitude: lon), elevationM: r.elev,
                               siteTypes: r.siteType)
        }
    }

    /// Stations within 50 km that report METARs (`siteTypes` nil or contains "METAR"), nearest first.
    /// Equal distance prefers a station that also carries a TAF.
    public static func rankCandidates(_ stations: [StationInfo], near point: Coordinate,
                                      maxDistanceKm: Double = maxStationDistanceKm) -> [StationInfo] {
        stations.compactMap { station -> (StationInfo, Double)? in
            let distance = NexradStation.distanceKm(point, station.coordinate)
            guard distance <= maxDistanceKm else { return nil }
            if let types = station.siteTypes, !types.contains("METAR") { return nil }
            return (station, distance)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            let aTAF = a.0.siteTypes?.contains("TAF") == true
            let bTAF = b.0.siteTypes?.contains("TAF") == true
            if aTAF != bTAF { return aTAF }
            return a.0.id < b.0.id
        }
        .map(\.0)
    }

    /// Nearest station within 50 km (great-circle). None → nil (no verification).
    public static func pickNearest(_ stations: [StationInfo], near point: Coordinate,
                                   cityElevationM: Double? = nil) -> MetarStationPick? {
        guard let best = rankCandidates(stations, near: point).first else { return nil }
        let distance = NexradStation.distanceKm(point, best.coordinate)
        let elevDelta = cityElevationM.flatMap { c in best.elevationM.map { $0 - c } }
        return MetarStationPick(stationID: best.id, name: best.name, coordinate: best.coordinate,
                                elevationM: best.elevationM, distanceKm: distance,
                                elevationDeltaM: elevDelta, pickedAt: Date())
    }

    /// Bounding box (~55 km) around a point for stationinfo search.
    public static func searchBBox(around point: Coordinate, km: Double = 55) -> (Double, Double, Double, Double) {
        let dLat = km / 111.0
        let cosLat = max(0.2, abs(cos(point.latitude * .pi / 180)))
        let dLon = km / (111.0 * cosLat)
        return (point.latitude - dLat, point.longitude - dLon, point.latitude + dLat, point.longitude + dLon)
    }

    /// Decode AWC METAR JSON (array of objects with `rawOb` / `icaoId` / `obsTime` / `temp` / …).
    /// 204 empty body → []. Malformed JSON → []. Never crashes.
    public static func decodeMetars(_ data: Data, loc: String, reference: Date = Date()) -> [MetarObservationRecord] {
        guard !data.isEmpty else { return [] }
        struct Row: Decodable {
            var icaoId: String?
            var rawOb: String?
            var rawMetar: String?
            var obsTime: DualTime?
            var reportTime: String?
            var temp: DualNumber?
            var wspd: DualNumber?
            var wdir: DualNumber?
            var cover: String?
        }
        struct DualTime: Decodable {
            var value: Date?
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Double.self) {
                    // AWC often sends Unix seconds.
                    value = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
                } else if let s = try? c.decode(String.self) {
                    value = NWSDate.parse(s) ?? ISO8601DateFormatter().date(from: s)
                } else { value = nil }
            }
        }
        struct DualNumber: Decodable {
            var value: Double?
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { value = d.isFinite ? d : nil }
                else if let i = try? c.decode(Int.self) { value = Double(i) }
                else if let s = try? c.decode(String.self) { value = Double(s) }
                else { value = nil }
            }
        }
        let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
        var out: [MetarObservationRecord] = []
        var seen: Set<String> = [] // station|minute — keep first of METAR/SPECI duplicates
        for r in rows {
            let raw = r.rawOb ?? r.rawMetar ?? ""
            let parsed = METARParser.parse(raw, reference: reference)
            let station = (r.icaoId ?? parsed.stationID ?? "").uppercased()
            guard !station.isEmpty else { continue }
            let time = r.obsTime?.value ?? parsed.time ?? reference
            let key = "\(station)|\(Int(time.timeIntervalSince1970 / 60))"
            if seen.contains(key) { continue }
            seen.insert(key)
            // Prefer parsed METAR text for wet/wind units; fall back to decoded JSON fields (°C, kt).
            let temp = parsed.temperatureC ?? r.temp?.value
            let wind: Double? = {
                if let w = parsed.windKmh { return w }
                if let kt = r.wspd?.value { return kt * 1.852 }
                return nil
            }()
            out.append(MetarObservationRecord(loc: loc, stationID: station, time: time,
                                              temperatureC: temp, windKmh: wind, wet: parsed.wet, raw: raw.isEmpty ? nil : raw))
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Convert METAR records to `StationObservation` for reuse with `ObservationAggregator` / daily extremes.
    public static func asStationObservations(_ records: [MetarObservationRecord]) -> [StationObservation] {
        records.map {
            StationObservation(time: $0.time, temperatureC: $0.temperatureC, windKmh: $0.windKmh,
                               precipLastHourMM: nil, precipitating: $0.wet ?? false)
        }
    }

    /// Jitter 0…4 minutes from a key so batched requests aren't synchronized on the hour.
    public static func jitter(for key: String) -> TimeInterval {
        let h = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return TimeInterval(h % 240)
    }
}
