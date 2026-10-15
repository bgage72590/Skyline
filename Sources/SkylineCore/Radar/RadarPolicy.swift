import Foundation

/// Build 42 radar policy, kept free of AppKit/MapKit so it runs (and is tested) on Linux.
public enum RadarPolicy {
    /// How long a frame with an unresolved tile may hold the previous frame on screen (review L2).
    public static let incompleteTimeout: Double = 1.5

    /// Show the target frame when it's complete, when nothing is on screen yet, or after waiting
    /// `incompleteTimeout` for a tile that never resolves.
    public static func shouldShow(complete: Bool, nothingShown: Bool, waited: Double) -> Bool {
        complete || nothingShown || waited >= incompleteTimeout
    }

    /// Frames loaded first after the shown one while playing (code review build 41 M2).
    public static let aheadFrames = 3

    /// Frames a generation needs, in load order: the shown frame, the next `aheadFrames` the loop will
    /// show, then the rest newest → oldest. Not playing: only the shown frame.
    /// `limitToAhead` (a fresh-scan generation loading while the old one plays): only the first
    /// 1 + `aheadFrames`, the rest after the swap.
    public static func loadOrder(count: Int, shown: Int, holdsLoop: Bool, limitToAhead: Bool = false) -> [Int] {
        guard count > 0 else { return [] }
        let s = min(max(shown, 0), count - 1)
        guard holdsLoop else { return [s] }
        var order = [s]
        if count > 1 { for k in 1...min(aheadFrames, count - 1) { order.append((s + k) % count) } }
        if limitToAhead { return order }
        for i in (0..<count).reversed() where !order.contains(i) { order.append(i) }
        return order
    }

    /// Every needed frame keeps the one-tile edge ring (build 42, review M3: no frame shows an empty
    /// edge while panning).
    public static func ringFrames(count: Int, shown: Int, holdsLoop: Bool, limitToAhead: Bool = false) -> Set<Int> {
        Set(loadOrder(count: count, shown: shown, holdsLoop: holdsLoop, limitToAhead: limitToAhead))
    }

    /// The zoom never depends on playback (quality first): one frame's budget, playing or paused.
    public static func zoom(visible: MapRectValue, viewWidth: Double, maxZ: Int, perFrameBudget: Int) -> Int {
        TileMath.zoom(fitting: visible, viewWidth: viewWidth, maxZ: maxZ, frames: 1, tileBudget: perFrameBudget)
    }

    /// Draw order for one frame: other zooms first (coarser before finer), current zoom last, so a
    /// leftover finer tile after a zoom-out never paints over the current tiles (review L5).
    public static func drawOrder(_ keys: [TileKey], currentZoom: Int) -> [TileKey] {
        keys.sorted { a, b in
            let ac = a.z == currentZoom, bc = b.z == currentZoom
            if ac != bc { return bc }
            if a.z != b.z { return a.z < b.z }
            return (a.x, a.y) < (b.x, b.y)
        }
    }

    /// Tiles a frame is allowed to show for the current view: only the current zoom's tiles, and only
    /// once the frame has every on-screen tile resolved; otherwise nothing new is shown and the
    /// previous frame stays (review M4 / build 42 item 4: never a mix of two frames' tiles).
    public static func isShowable(have: Set<TileKey>, resolved: Set<TileKey>, desired: [TileKey]) -> Bool {
        desired.allSatisfy { have.contains($0) || resolved.contains($0) }
    }
}

/// Decoded-tile memory, for the 350 MB ceiling (review test 7, QA R1).
public enum RadarMemoryBudget {
    /// Bytes per decoded tile as held: RGBA 256² unless packed.
    public static let rgbaTileBytes = 256 * 256 * 4
    /// Packed losslessly (build 42): 8-bit palette indices (index 0 = transparent) + a small palette.
    public static let packedTileBytes = 256 * 256 + 1024

    /// Visible and ring tile counts for a view (points) at the zoom Skyline picks.
    public static func tiles(viewWidth: Double, viewHeight: Double, maxZ: Int = 9, perFrameBudget: Int = 160,
                             centerX: Double = TileMath.worldSize * 0.29, centerY: Double = TileMath.worldSize * 0.375,
                             spanWidth: Double? = nil) -> (z: Int, visible: Int, ring: Int) {
        // Default view: ~10° of longitude per 1000 pt, around the US northeast.
        let width = spanWidth ?? TileMath.worldSize * (10.0 / 360.0) * viewWidth / 1000
        let height = width * viewHeight / viewWidth
        let rect = MapRectValue(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        let z = RadarPolicy.zoom(visible: rect, viewWidth: viewWidth, maxZ: maxZ, perFrameBudget: perFrameBudget)
        return (z, TileMath.tiles(covering: rect, z: z).count, TileMath.tiles(covering: rect, z: z, margin: 1).count)
    }

    /// Peak decoded bytes while playing: every frame with its ring, plus a fresh-scan generation's
    /// shown + ahead frames during a swap.
    public static func peakBytes(ringTiles: Int, frames: Int, bytesPerTile: Int = rgbaTileBytes, swapping: Bool) -> Int {
        let held = frames * ringTiles
        let pending = swapping ? min(frames, 1 + RadarPolicy.aheadFrames) * ringTiles : 0
        return (held + pending) * bytesPerTile
    }
}

/// 0.35 s frame crossfade (restored in build 42). Pure state: the view samples it on a timer.
public struct RadarCrossfade: Equatable, Sendable {
    public static let duration: TimeInterval = 0.35
    public private(set) var from: Int?
    public private(set) var to: Int
    /// Alpha the outgoing frame starts from (1, or less when a new switch lands mid-fade).
    public private(set) var fromStart: Double = 1
    public private(set) var start: TimeInterval = -.infinity

    public init(shown: Int) { to = shown }

    /// Ease-in-out progress 0…1.
    public func progress(at t: TimeInterval) -> Double {
        let x = min(max((t - start) / Self.duration, 0), 1)
        return x * x * (3 - 2 * x)
    }

    public func isActive(at t: TimeInterval) -> Bool { from != nil && t - start < Self.duration }

    /// (frame, alpha) pairs to draw, outgoing first.
    public func layers(at t: TimeInterval) -> [(frame: Int, alpha: Double)] {
        guard let from, isActive(at: t) else { return [(to, 1)] }
        let p = progress(at: t)
        return [(from, fromStart * (1 - p)), (to, p)]
    }

    /// Switch to `frame`. Animated: fades from what is on screen now; a switch mid-fade starts from the
    /// blended state (the incoming frame becomes the outgoing one at its current alpha).
    public mutating func show(_ frame: Int, at t: TimeInterval, animated: Bool) {
        guard frame != to else { return }
        if animated {
            let p = isActive(at: t) ? progress(at: t) : 1
            fromStart = isActive(at: t) ? max(p, fromStart * (1 - p)) : 1
            from = to
        } else {
            from = nil
            fromStart = 1
        }
        to = frame
        start = t
    }

    /// Moves the start of a running fade (the view waits a moment for the hidden slot to draw).
    public mutating func restart(at t: TimeInterval) { if from != nil { start = t } }

    public mutating func finish() { from = nil; fromStart = 1; start = -.infinity }
}

/// Accepts CoreLocation fixes only when they are plausible (QA build 41 G1, "Sint Maarten").
public struct LocationFixFilter: Sendable {
    public static let maxAccuracy: Double = 5_000        // metres
    public static let maxAge: TimeInterval = 5 * 60
    public static let bigJump: Double = 500_000          // metres
    public static let confirmRadius: Double = 50_000     // later fixes within this of the jump confirm it
    /// Build 45 (QA build-44 G1-a): a jump is confirmed only by fixes spanning at least this long, so one
    /// mislocated Wi-Fi answer repeated 20 s later isn't enough.
    public static let confirmSpan: TimeInterval = 120
    /// A fix dated this far in the future is invalid.
    public static let futureSkew: TimeInterval = 60
    /// No saved fix yet: a first fix whose solar time is this far from the Mac's time zone is held
    /// for confirmation like a big jump.
    public static let maxZoneMismatchHours: Double = 3.5

    public struct Fix: Equatable, Sendable {
        public let latitude: Double, longitude: Double, accuracy: Double, timestamp: Date
        public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
            self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.timestamp = timestamp
        }
    }

    public enum Verdict: Equatable, Sendable { case accept, rejectInaccurate, rejectStale, rejectInvalid, holdForConfirmation }

    public private(set) var last: Coordinate?
    /// The first fix of an unconfirmed jump.
    private var anchor: Fix?
    private let zoneOffsetSeconds: Int?

    /// - Parameter timeZoneOffset: the Mac's UTC offset in seconds (checks a first fix with no seed).
    public init(last: Coordinate? = nil, timeZoneOffset: Int? = nil) {
        self.last = last
        zoneOffsetSeconds = timeZoneOffset
    }

    /// True when `longitude`'s solar offset is far from the Mac's time zone.
    static func zoneMismatch(longitude: Double, offsetSeconds: Int) -> Bool {
        var diff = abs(longitude / 15 - Double(offsetSeconds) / 3600)
        if diff > 12 { diff = 24 - diff }
        return diff > maxZoneMismatchHours
    }

    public mutating func evaluate(_ f: Fix, now: Date) -> Verdict {
        guard f.latitude.isFinite, f.longitude.isFinite, abs(f.latitude) <= 90, abs(f.longitude) <= 180,
              !(f.latitude == 0 && f.longitude == 0) else { return .rejectInvalid }
        guard f.timestamp.timeIntervalSince(now) <= Self.futureSkew else { return .rejectInvalid }
        guard f.accuracy >= 0, f.accuracy <= Self.maxAccuracy else { return .rejectInaccurate }
        guard now.timeIntervalSince(f.timestamp) <= Self.maxAge else { return .rejectStale }
        let here = Coordinate(latitude: f.latitude, longitude: f.longitude)
        let suspicious: Bool
        if let last { suspicious = Self.distance(last, here) > Self.bigJump }
        else if let z = zoneOffsetSeconds { suspicious = Self.zoneMismatch(longitude: f.longitude, offsetSeconds: z) }
        else { suspicious = false }
        if suspicious {
            if let a = anchor, Self.distance(Coordinate(latitude: a.latitude, longitude: a.longitude), here) <= Self.confirmRadius {
                if f.timestamp.timeIntervalSince(a.timestamp) >= Self.confirmSpan {
                    anchor = nil
                    self.last = here
                    return .accept
                }
                return .holdForConfirmation
            }
            anchor = f
            return .holdForConfirmation
        }
        anchor = nil
        self.last = here
        return .accept
    }

    /// Haversine metres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6_371_000.0, toRad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * toRad, dLon = (b.longitude - a.longitude) * toRad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * toRad) * cos(b.latitude * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
