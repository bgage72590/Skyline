import Foundation

/// One NEXRAD storm-attribute cell (IEM `geojson/nexrad_attr.py`).
public struct StormCell: Hashable, Sendable, Identifiable {
    public var id: String
    public var radar: String
    public var stormID: String
    public var coordinate: Coordinate
    public var maxDBZ: Int
    public var directionDegrees: Double
    public var speedKnots: Double
    public var valid: Date

    public init(id: String, radar: String, stormID: String, coordinate: Coordinate,
                maxDBZ: Int, directionDegrees: Double, speedKnots: Double, valid: Date) {
        self.id = id; self.radar = radar; self.stormID = stormID; self.coordinate = coordinate
        self.maxDBZ = maxDBZ; self.directionDegrees = directionDegrees; self.speedKnots = speedKnots
        self.valid = valid
    }
}

/// Storm-motion arrows on the radar (radar-features §4): poll IEM attributes, keep strong nearby
/// cells, dedupe across sites, label motion, and optionally show an ETA when the path passes close.
public enum StormMotion {
    public static let pollInterval: TimeInterval = 120
    public static let maxDistanceKm = 150.0
    public static let minDBZ = 45
    /// Below this, treat motion as erratic / unknown and hide the arrow.
    public static let minSpeedKnots = 5.0
    public static let dedupeKm = 15.0
    /// Path must pass within this many miles of the location to show an ETA.
    public static let etaPassMiles = 5.0
    public static let maxETAHours = 3.0
    /// Cap how many arrows we draw (nearest first).
    public static let maxCells = 3

    /// Parse GeoJSON (or CSV with a header) from IEM `nexrad_attr.py`.
    public static func parse(_ data: Data) throws -> [StormCell] {
        if data.first == UInt8(ascii: "{") { return try parseGeoJSON(data) }
        return try parseCSV(data)
    }

    public static func parseGeoJSON(_ data: Data) throws -> [StormCell] {
        struct Root: Decodable { var features: [Feature] }
        struct Feature: Decodable {
            var properties: Props
            var geometry: Geom?
        }
        struct Props: Decodable {
            var nexrad: String
            var storm_id: String
            var max_dbz: Int
            var drct: Double
            var sknt: Double
            var valid: String
        }
        struct Geom: Decodable {
            var coordinates: [Double]
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        return root.features.compactMap { f in
            guard let coords = f.geometry?.coordinates, coords.count >= 2 else { return nil }
            let valid = iso.date(from: f.properties.valid) ?? isoBasic.date(from: f.properties.valid) ?? Date()
            let id = "\(f.properties.nexrad)-\(f.properties.storm_id)-\(f.properties.valid)"
            return StormCell(id: id, radar: f.properties.nexrad, stormID: f.properties.storm_id,
                             coordinate: Coordinate(latitude: coords[1], longitude: coords[0]),
                             maxDBZ: f.properties.max_dbz, directionDegrees: f.properties.drct,
                             speedKnots: f.properties.sknt, valid: valid)
        }
    }

    public static func parseCSV(_ data: Data) throws -> [StormCell] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.lowercased() else { return [] }
        let cols = header.split(separator: ",").map(String.init)
        func idx(_ name: String) -> Int? { cols.firstIndex(of: name) }
        guard let iRadar = idx("nexrad"), let iStorm = idx("storm_id"),
              let iDBZ = idx("max_dbz"), let iDrct = idx("drct"), let iSknt = idx("sknt"),
              let iValid = idx("valid") else { return [] }
        // CSV from IEM has no lat/lon — GeoJSON is preferred. Skip CSV without geometry.
        return []
    }

    /// Keep strong, moving cells within `maxDistanceKm`, dedupe nearby duplicates across radars,
    /// then keep at most `maxCells` nearest to `location`.
    public static func relevant(_ cells: [StormCell], near location: Coordinate) -> [StormCell] {
        let strong = cells.filter { cell in
            cell.maxDBZ >= minDBZ
                && cell.speedKnots >= minSpeedKnots
                && NexradStation.distanceKm(location, cell.coordinate) <= maxDistanceKm
        }
        return Array(dedupe(strong)
            .sorted { NexradStation.distanceKm(location, $0.coordinate) < NexradStation.distanceKm(location, $1.coordinate) }
            .prefix(maxCells))
    }

    /// Wipe arrows as soon as the forecast location changes (before the next poll returns).
    public static func cellsAfterLocationChange(previous: Coordinate?, new: Coordinate,
                                                cells: [StormCell]) -> [StormCell] {
        previous == new ? cells : []
    }

    /// Screen-space tip offset for an arrow of `length` pt in `directionDegrees` (0 = north).
    /// Overlay NSViews here grow **up** (same as MapKit convert into them), so north is +y and a
    /// NE-moving cell (45°) must land in the upper-right quadrant — matching its "moving NE" label.
    public static func arrowTipOffset(directionDegrees: Double, length: Double) -> (dx: Double, dy: Double) {
        let rad = directionDegrees * .pi / 180
        return (sin(rad) * length, cos(rad) * length)
    }

    /// Arrow colour by intensity (max dBZ): yellow → orange → red.
    public static func arrowColorRGB(maxDBZ: Int) -> (r: Double, g: Double, b: Double) {
        switch maxDBZ {
        case ..<50: return (1.0, 0.85, 0.2)
        case ..<55: return (1.0, 0.55, 0.1)
        default: return (1.0, 0.25, 0.15)
        }
    }

    /// Prefer the stronger (higher max dBZ) cell when two are within `dedupeKm`.
    public static func dedupe(_ cells: [StormCell]) -> [StormCell] {
        let ranked = cells.sorted { a, b in
            if a.maxDBZ != b.maxDBZ { return a.maxDBZ > b.maxDBZ }
            return a.speedKnots > b.speedKnots
        }
        var kept: [StormCell] = []
        for cell in ranked {
            let nearExisting = kept.contains {
                NexradStation.distanceKm($0.coordinate, cell.coordinate) < dedupeKm
            }
            if !nearExisting { kept.append(cell) }
        }
        return kept
    }

    /// "moving NE at 25 mph" (speed converted from knots; default mph for US radar).
    public static func motionLabel(directionDegrees: Double, speedKnots: Double,
                                   speedUnit: SpeedUnit = .mph) -> String {
        let kmh = speedKnots * 1.852
        let value: Double
        switch speedUnit {
        case .mph: value = kmh / 1.609344
        case .kmh: value = kmh
        case .metresPerSecond: value = kmh / 3.6
        case .knots: value = speedKnots
        }
        let dir = Compass.abbreviation(directionDegrees)
        return "moving \(dir) at \(Int(value.rounded())) \(speedUnit.label)"
    }

    /// Minutes until closest approach, only when the path passes within `etaPassMiles` of `location`
    /// and the approach is ahead of the cell (not behind it).
    public static func etaMinutes(cell: StormCell, to location: Coordinate) -> Int? {
        let speedMs = cell.speedKnots * 0.514444
        guard speedMs > 0.1 else { return nil }
        let φ = cell.coordinate.latitude * .pi / 180
        let dNorth = (location.latitude - cell.coordinate.latitude) * 111_320
        let dEast = (location.longitude - cell.coordinate.longitude) * 111_320 * cos(φ)
        let bearing = cell.directionDegrees * .pi / 180
        let vNorth = cos(bearing) * speedMs
        let vEast = sin(bearing) * speedMs
        let t = (dNorth * vNorth + dEast * vEast) / (speedMs * speedMs)
        guard t > 60, t < maxETAHours * 3600 else { return nil }
        let closestN = dNorth - vNorth * t
        let closestE = dEast - vEast * t
        let distM = (closestN * closestN + closestE * closestE).squareRoot()
        guard distM <= RangeRings.meters(etaPassMiles) else { return nil }
        return max(1, Int((t / 60).rounded()))
    }

    /// Short callout: motion line, plus "near you in ~20 min" when ETA applies.
    public static func callout(cell: StormCell, location: Coordinate,
                               speedUnit: SpeedUnit = .mph) -> String {
        let motion = motionLabel(directionDegrees: cell.directionDegrees,
                                 speedKnots: cell.speedKnots, speedUnit: speedUnit)
        if let eta = etaMinutes(cell: cell, to: location) {
            return "\(motion) · near you in ~\(eta) min"
        }
        return motion
    }
}
