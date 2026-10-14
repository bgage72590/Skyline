import Foundation

/// Saved cities and the settings worth keeping, shared between Brian's Macs through one JSON file in
/// iCloud Drive (`Skyline/sync.json`). iCloud key-value storage needs an entitlement only a paid
/// developer account can sign, so the file is the transport; the merge below makes it safe for two
/// Macs to write it at different times.
///
/// Merge rules (nothing is lost):
/// * A city is kept if any side has it and it wasn't removed later than it was last added or changed.
/// * The newer copy of a city wins; local order first, then cities only the other Mac has.
/// * Each setting is last-writer-wins by its own timestamp; a stamped key with no value means "reset".
public struct SyncDocument: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public var format: Int = SyncDocument.currentFormat
    public var locations: [WeatherLocation] = []
    /// When each city was last added or changed.
    public var locationStamps: [String: Date] = [:]
    /// When each city was removed (kept so a removal reaches the other Macs; pruned after 180 days).
    public var removed: [String: Date] = [:]
    /// Setting key → encoded value (see `SyncValue`). Missing value with a stamp = reset to default.
    public var settings: [String: String] = [:]
    public var settingStamps: [String: Date] = [:]
    /// When the city order was last changed on purpose (optional so format-1 files still decode).
    public var orderStamp: Date?
    /// Build 31 only: verified pairs were shared here. Build 32 moved them to accuracy.json
    /// (`AccuracyFile`). Still decoded and passed through unchanged so a build-31 Mac on the same iCloud
    /// isn't fought over; build 33 also folds them into the local history (SyncCoordinator).
    public var accuracy: [VerifiedRecord]?
    /// Build 31 only (see `accuracy`).
    public var accuracyResetAt: Date?
    public var writtenBy: String = ""
    public var writtenAt: Date = .distantPast

    public init() {}

    enum CodingKeys: String, CodingKey {
        case format, locations, locationStamps, removed, settings, settingStamps, orderStamp, accuracy, accuracyResetAt,
             writtenBy, writtenAt
    }

    /// Same as the synthesized decoder, except the build-31 `accuracy` pairs are decoded leniently (M3): a
    /// malformed or non-finite pair is skipped and never makes the cities and settings unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        locations = try c.decode([WeatherLocation].self, forKey: .locations)
        locationStamps = try c.decode([String: Date].self, forKey: .locationStamps)
        removed = try c.decode([String: Date].self, forKey: .removed)
        settings = try c.decode([String: String].self, forKey: .settings)
        settingStamps = try c.decode([String: Date].self, forKey: .settingStamps)
        orderStamp = try c.decodeIfPresent(Date.self, forKey: .orderStamp)
        accuracy = (try? c.decodeIfPresent([Lenient<VerifiedRecord>].self, forKey: .accuracy))??.compactMap(\.value)
        accuracyResetAt = try? c.decodeIfPresent(Date.self, forKey: .accuracyResetAt)
        writtenBy = try c.decode(String.self, forKey: .writtenBy)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
    }

    /// The newest stamp this document has seen. New local stamps are kept later than it, so a change made
    /// after seeing another Mac's change wins even when this Mac's clock is behind (hybrid logical clock).
    var latestStamp: Date {
        ([orderStamp].compactMap { $0 } + Array(locationStamps.values) + Array(removed.values) + Array(settingStamps.values))
            .max() ?? .distantPast
    }

    /// Rebuild the local side after the user changed something: stamps what differs from `previous`.
    public static func noting(locations: [WeatherLocation], settings: [String: String],
                              previous: SyncDocument, now wallClock: Date) -> SyncDocument {
        var doc = previous
        let now = max(wallClock, previous.latestStamp.addingTimeInterval(0.001))
        let old = Dictionary(previous.locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Set(locations.map(\.id))
        for l in locations where old[l.id] != l {
            doc.locationStamps[l.id] = now
            doc.removed[l.id] = nil
        }
        for id in old.keys where !new.contains(id) {
            doc.removed[id] = now
            doc.locationStamps[id] = nil
        }
        // A reorder (same cities, different order) is its own change.
        let kept = locations.map(\.id).filter { old[$0] != nil }
        if kept != previous.locations.map(\.id).filter({ new.contains($0) }) { doc.orderStamp = now }
        doc.locations = locations
        for key in Set(settings.keys).union(previous.settings.keys) where settings[key] != previous.settings[key] {
            doc.settingStamps[key] = now
        }
        doc.settings = settings
        return doc
    }

    /// The first time a Mac syncs, everything it already has counts as added now, so a removal made
    /// earlier on another Mac can't delete a city this Mac still has (migration keeps everything).
    public static func migrating(locations: [WeatherLocation], settings: [String: String], now: Date) -> SyncDocument {
        var doc = SyncDocument()
        doc.locations = locations
        for l in locations { doc.locationStamps[l.id] = now }
        doc.settings = settings
        // Settings start older than anything synced, so an existing shared choice wins on a new Mac.
        for key in settings.keys { doc.settingStamps[key] = .distantPast }
        return doc
    }

    public static func merge(local: SyncDocument, remote: SyncDocument, now: Date = Date()) -> SyncDocument {
        var out = SyncDocument()
        out.writtenBy = local.writtenBy
        out.writtenAt = max(local.writtenAt, remote.writtenAt)
        let localByID = Dictionary(local.locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Order from the side that reordered last; equal stamps pick the same side on every Mac.
        let lo = local.orderStamp ?? .distantPast, ro = remote.orderStamp ?? .distantPast
        let lIDs = local.locations.map(\.id), rIDs = remote.locations.map(\.id)
        let remoteFirst = ro > lo || (ro == lo && rIDs.joined(separator: "\n") < lIDs.joined(separator: "\n"))
        out.orderStamp = max(lo, ro) == .distantPast ? nil : max(lo, ro)
        var order: [String] = []
        for id in (remoteFirst ? rIDs + lIDs : lIDs + rIDs) where !order.contains(id) { order.append(id) }
        let allRemovedIDs = Set(local.removed.keys).union(remote.removed.keys)
        for id in allRemovedIDs {
            let r = [local.removed[id], remote.removed[id]].compactMap { $0 }.max()
            if let r, now.timeIntervalSince(r) < 180 * 86400 { out.removed[id] = r }
        }
        for id in order {
            let ls = localByID[id] != nil ? (local.locationStamps[id] ?? .distantPast) : nil
            let rs = remoteByID[id] != nil ? (remote.locationStamps[id] ?? .distantPast) : nil
            let live = [ls, rs].compactMap { $0 }.max() ?? .distantPast
            let removedAt = [local.removed[id], remote.removed[id]].compactMap { $0 }.max()
            if let removedAt, removedAt >= live { continue }
            let pick: WeatherLocation? = {
                switch (localByID[id], remoteByID[id]) {
                case let (l?, r?): return (rs ?? .distantPast) > (ls ?? .distantPast) ? r : l
                case let (l?, nil): return l
                case let (nil, r?): return r
                default: return nil
                }
            }()
            guard let pick else { continue }
            out.locations.append(pick)
            out.locationStamps[id] = live
            out.removed[id] = nil
        }
        for key in Set(local.settingStamps.keys).union(remote.settingStamps.keys)
            .union(local.settings.keys).union(remote.settings.keys) {
            let l = local.settingStamps[key] ?? .distantPast, r = remote.settingStamps[key] ?? .distantPast
            // Ties: a key this Mac never heard of comes from the other; otherwise the same value wins on
            // both Macs (larger encoded value), so two Macs never keep rewriting each other's choice.
            let useRemote = r > l || (r == l && ((local.settings[key] == nil && local.settingStamps[key] == nil)
                || (remote.settings[key] ?? "") > (local.settings[key] ?? "")))
            out.settingStamps[key] = max(l, r)
            out.settings[key] = useRemote ? remote.settings[key] : local.settings[key]
        }
        // Accuracy pairs live in accuracy.json since build 32. The build-31 fields are passed through as the
        // file has them (never merged, never a reason to write; build-32 review N-H1): stripping them made a
        // build-31 and a build-32 Mac rewrite sync.json back and forth on every refresh.
        // Build 35 (QA build-34 SF-B): only what the file itself has is passed through (never re-added from
        // this Mac's copy), and it ages out once its newest pair is older than the 30-day window, so a
        // leftover build-31 blob disappears from sync.json after the last build-31 Mac stops writing it.
        let legacy = Self.liveLegacyAccuracy(remote, now: now)
        out.accuracy = legacy.accuracy
        out.accuracyResetAt = legacy.resetAt
        return out
    }

    /// The build-31 accuracy fields of `doc`, or nil once stale (newest pair, or the reset when there are no
    /// pairs, older than `AccuracySync.windowDays`).
    static func liveLegacyAccuracy(_ doc: SyncDocument, now: Date) -> (accuracy: [VerifiedRecord]?, resetAt: Date?) {
        let cutoff = now.addingTimeInterval(-AccuracySync.windowDays * 86400)
        let newest = [doc.accuracy?.map(\.r.valid).max(), doc.accuracy?.isEmpty == false ? nil : doc.accuracyResetAt]
            .compactMap { $0 }.max()
        guard let newest, newest >= cutoff else { return (nil, nil) }
        return (doc.accuracy, doc.accuracyResetAt)
    }

    /// Local edits made while a background merge was in flight (between `snapshot`, the local document
    /// handed to the merge, and now) are re-noted on top of the merge result, so applying that result
    /// never reverts them. Returns `merged` unchanged when nothing changed locally in the meantime.
    public static func rebasing(locations: [WeatherLocation], settings: [String: String],
                                snapshot: SyncDocument, onto merged: SyncDocument, now: Date) -> SyncDocument {
        let edits = noting(locations: locations, settings: settings, previous: snapshot, now: now)
        guard !edits.sameContent(as: snapshot) else { return merged }
        var out = merge(local: edits, remote: merged, now: now)
        out.writtenBy = merged.writtenBy
        return out
    }

    /// Same content (ignores who wrote it and when, and the build-31 accuracy fields, see `merge`).
    public func sameContent(as other: SyncDocument) -> Bool {
        locations == other.locations && orderStamp == other.orderStamp && settings == other.settings && removed == other.removed
            && locationStamps == other.locationStamps && settingStamps == other.settingStamps

    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public enum ReadOutcome: Equatable, Sendable {
        case document(SyncDocument)
        /// Written by a newer Skyline: leave it alone and tell the user to update.
        case newerFormat(Int)
        /// Not a Skyline sync file (corrupt or truncated): move it aside and rewrite from this Mac.
        case unreadable
    }

    public static func read(_ data: Data) -> ReadOutcome {
        struct Header: Decodable { var format: Int? }
        if let f = (try? JSONDecoder().decode(Header.self, from: data))?.format, f > currentFormat { return .newerFormat(f) }
        return decode(data).map(ReadOutcome.document) ?? .unreadable
    }

    /// Nil for a file that isn't a Skyline sync file, or is from a newer format this build can't read.
    public static func decode(_ data: Data) -> SyncDocument? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let doc = try? d.decode(SyncDocument.self, from: data), doc.format <= currentFormat else { return nil }
        return doc
    }
}

/// UserDefaults values as strings for the sync file: "s:" string, "i:" integer, "b:" bool,
/// "d:" base64 data, "a:" JSON string array.
public enum SyncValue {
    public static func encode(_ value: Any?) -> String? {
        switch value {
        case let s as String: return "s:" + s
        case let d as Data: return "d:" + d.base64EncodedString()
        case let a as [String]:
            return (try? JSONEncoder().encode(a)).flatMap { String(data: $0, encoding: .utf8) }.map { "a:" + $0 }
        case let n as NSNumber:
            if String(cString: n.objCType) == "c" { return "b:" + (n.boolValue ? "1" : "0") }
            return "i:\(n.intValue)"
        default: return nil
        }
    }

    public static func decode(_ string: String) -> Any? {
        let kind = string.prefix(2), body = String(string.dropFirst(2))
        switch kind {
        case "s:": return body
        case "d:": return Data(base64Encoded: body)
        case "i:": return Int(body)
        case "b:": return body == "1"
        case "a:": return try? JSONDecoder().decode([String].self, from: Data(body.utf8))
        default: return nil
        }
    }
}

/// Cheap identity of a sync.json's build-31 accuracy fields, to absorb them only when they change.
public struct LegacyAccuracyFingerprint: Equatable, Sendable {
    let count: Int
    let newestValid: Date?
    let newestIssued: Date?
    let resetAt: Date?

    public init(_ doc: SyncDocument) {
        let a = doc.accuracy ?? []
        count = a.count
        newestValid = a.map(\.r.valid).max()
        newestIssued = a.map(\.r.issued).max()
        resetAt = doc.accuracyResetAt
    }
}
