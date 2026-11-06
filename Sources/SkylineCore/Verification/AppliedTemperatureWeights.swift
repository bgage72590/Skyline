import Foundation

/// Last *applied* temperature multipliers, one file beside `verified.jsonl`.
///
/// `applied-temperature-weights.json` is not `corrections.json`. USA locations (those whose key
/// parses to a coordinate in `isLikelyInNWSCoverage`) persist the rate-limited multipliers and the
/// city-local calendar day they were applied. The same local day keeps that applied set; a new
/// local day steps each multiplier by at most `AdaptiveWeighting.maxDailyMultiplierDelta`.
///
/// Keys that are not in NWS coverage are not stored here. They keep tip eligibility (n≥20,
/// distinct UTC days≥3) and the raw temperature proposal is applied with no rate limit.
public struct AppliedTemperatureWeightStore: Codable, Sendable, Equatable {
    public static let fileName = "applied-temperature-weights.json"

    public struct Entry: Codable, Sendable, Equatable {
        public var localDay: String
        public var timeZoneIdentifier: String?
        public var multipliers: [LeadBucket: [VerificationSource: Double]]

        public init(localDay: String, timeZoneIdentifier: String? = nil,
                    multipliers: [LeadBucket: [VerificationSource: Double]] = [:]) {
            self.localDay = localDay
            self.timeZoneIdentifier = timeZoneIdentifier
            self.multipliers = multipliers
        }
    }

    public var locations: [String: Entry] = [:]

    public init(locations: [String: Entry] = [:]) { self.locations = locations }

    /// `"40.7128,-74.0060"` or `"here@41.2,-73.2"`. Anything else (a test id, a bare name) is nil.
    public static func coordinate(fromLocationKey key: String) -> Coordinate? {
        let body = key.hasPrefix("here@") ? String(key.dropFirst(5)) : key
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// USA gate for this workstream: the same NWS-coverage helper the blender already uses.
    public static func isUSALocationKey(_ key: String) -> Bool {
        coordinate(fromLocationKey: key)?.isLikelyInNWSCoverage == true
    }

    /// Longitude-band fallback when the city's IANA zone has not been seen yet.
    /// Fair-verification cities in the M1 window land in their real zone (Eastern, Pacific, Alaska).
    public static func inferredTimeZone(for coordinate: Coordinate) -> TimeZone {
        let lat = coordinate.latitude, lon = coordinate.longitude
        let id: String
        if lat >= 51, lon >= -170, lon <= -130 {
            id = "America/Anchorage"
        } else if lat >= 18.5, lat <= 22.5, lon >= -160.5, lon <= -154.5 {
            id = "Pacific/Honolulu"
        } else if lat >= 17.5, lat <= 18.6, lon >= -67.5, lon <= -64.5 {
            id = "America/Puerto_Rico"
        } else if lon >= -85 {
            id = "America/New_York"
        } else if lon >= -102 {
            id = "America/Chicago"
        } else if lon >= -115 {
            id = "America/Denver"
        } else {
            id = "America/Los_Angeles"
        }
        return TimeZone(identifier: id) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// `yyyy-MM-dd` in `timeZone`.
    public static func localDayStamp(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Drop non-finite multipliers and values that are exactly neutral.
    public mutating func sanitize() {
        for key in Array(locations.keys) {
            var entry = locations[key]!
            entry.multipliers = AdaptiveWeighting.finiteTemperature(entry.multipliers)
            locations[key] = entry
        }
    }

    public static func load(from directory: URL) -> AppliedTemperatureWeightStore {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(AppliedTemperatureWeightStore.self, from: data) else {
            return AppliedTemperatureWeightStore()
        }
        decoded.sanitize()
        return decoded
    }

    public func save(to directory: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
