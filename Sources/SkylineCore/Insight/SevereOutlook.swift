import Foundation

/// The Storm Prediction Center's categorical convective outlook for a point (L20): "Slight risk of
/// severe storms today" before any watch or warning exists. US lower 48 only; free GeoJSON from SPC.
public struct SevereOutlook: Codable, Hashable, Sendable {
    /// SPC's categories, by their `DN` value.
    public enum Risk: Int, Codable, Comparable, Sendable, CaseIterable {
        case thunder = 2, marginal = 3, slight = 4, enhanced = 5, moderate = 6, high = 8

        public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        /// "Slight risk" (SPC's own names, lower-cased for a sentence).
        public var name: String {
            switch self {
            case .thunder: "General thunderstorms"
            case .marginal: "Marginal risk"
            case .slight: "Slight risk"
            case .enhanced: "Enhanced risk"
            case .moderate: "Moderate risk"
            case .high: "High risk"
            }
        }
        /// SPC's scale position, for "level 2 of 5".
        public var level: Int? {
            switch self {
            case .thunder: nil
            case .marginal: 1
            case .slight: 2
            case .enhanced: 3
            case .moderate: 4
            case .high: 5
            }
        }
    }

    /// 1 = SPC's Day 1 (today / tonight), 2 = Day 2 (tomorrow).
    public var day: Int
    public var risk: Risk
    public var validFrom: Date
    public var validUntil: Date
    public var issued: Date?

    public init(day: Int, risk: Risk, validFrom: Date, validUntil: Date, issued: Date? = nil) {
        self.day = day; self.risk = risk; self.validFrom = validFrom; self.validUntil = validUntil; self.issued = issued
    }

    /// Worth a line on the main screen: marginal or higher (general thunder isn't a severe risk).
    public var isSevere: Bool { risk >= .marginal }

    /// "Slight risk of severe storms today (level 2 of 5)".
    public func sentence(now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let when: String
        if day >= 2 { when = "tomorrow" } else { when = cal.component(.hour, from: now) >= 17 ? "tonight" : "today" }
        let level = risk.level.map { " (level \($0) of 5)" } ?? ""
        return "\(risk.name) of severe storms \(when)\(level)"
    }
}

public enum SPCOutlookParser {
    struct Collection: Decodable {
        struct Feature: Decodable {
            struct Geometry: Decodable {
                var type: String
                var coordinates: Coordinates
            }
            struct Properties: Decodable {
                var DN: Int
                var VALID_ISO: String?
                var EXPIRE_ISO: String?
                var ISSUE_ISO: String?
            }
            var geometry: Geometry?
            var properties: Properties
        }
        var features: [Feature]
    }

    /// Polygon = [ring], ring = [[lon, lat]]; MultiPolygon = [polygon].
    enum Coordinates: Decodable {
        case polygon([[[Double]]])
        case multi([[[[Double]]]])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let m = try? c.decode([[[[Double]]]].self) { self = .multi(m) }
            else { self = .polygon(try c.decode([[[Double]]].self)) }
        }
        var polygons: [[[[Double]]]] {
            switch self { case .polygon(let p): [p]; case .multi(let m): m }
        }
    }

    /// The highest category whose area contains `point` (holes excluded), or nil when none does.
    public static func outlook(_ data: Data, day: Int, point: Coordinate) throws -> SevereOutlook? {
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        let iso = ISO8601DateFormatter()
        var best: SevereOutlook?
        for f in collection.features {
            guard let risk = SevereOutlook.Risk(rawValue: f.properties.DN), let g = f.geometry,
                  best.map({ risk > $0.risk }) ?? true else { continue }
            let inside = g.coordinates.polygons.contains { polygon in
                let rings = polygon.map { ring in ring.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[1], longitude: $0[0]) : nil } }
                guard let outer = rings.first, USCoverage.contains(outer, point) else { return false }
                return !rings.dropFirst().contains { USCoverage.contains($0, point) }
            }
            guard inside,
                  let from = f.properties.VALID_ISO.flatMap(iso.date(from:)),
                  let until = f.properties.EXPIRE_ISO.flatMap(iso.date(from:)) else { continue }
            best = SevereOutlook(day: day, risk: risk, validFrom: from, validUntil: until,
                                 issued: f.properties.ISSUE_ISO.flatMap(iso.date(from:)))
        }
        return best
    }
}
