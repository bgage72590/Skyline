import Foundation

/// Sharing the forecast-vs-NWS accuracy learning between Macs (build 31). The scorecard and the adaptive
/// blend weights are both computed from verified pairs, so the pairs are what travels in sync.json.
///
/// Merge rule: a grow-only set with de-duplication. Records for the same location key (the station's
/// place) and valid hour whose issue times are within `sameIssuance` (90 min) of the earliest one in their
/// run are one verification (build 33, M1: each Mac issues on its own 3 h cadence, so two Macs' copies of
/// the same forecast can sit on either side of any fixed slot boundary; one Mac's own issuances are always
/// >= 3 h apart, so they never merge). Within such a cluster each model is counted once: the earliest
/// issued record's value wins, later ones only fill models it lacks. Clusters are formed from the sorted
/// union, so the result is the same whatever order Macs merge in (commutative, idempotent).
/// A reset ("Reset Accuracy Data") drops records issued before it everywhere.
public enum AccuracySync {
    /// Only the most recent pairs travel (each Mac keeps its own 90-day history locally).
    public static let windowDays = 30.0
    /// Hard cap on synced pairs (~470 bytes each), newest kept.
    public static let maxRecords = 15_000
    /// Issuances this close to the earliest one in a cluster are the same forecast from two Macs (M1).
    /// Half the issue interval, so one Mac's own issuances (>= 3 h apart) never merge.
    public static let sameIssuance: TimeInterval = ForecastVerifier.issueInterval / 2

    struct GroupKey: Hashable {
        let loc: String
        let valid: Date
    }

    static func normalized(_ v: VerifiedRecord) -> VerifiedRecord {
        // sync.json stores whole-second ISO 8601 dates; normalize so a round trip is identical.
        var v = v
        v.r.issued = Date(timeIntervalSince1970: v.r.issued.timeIntervalSince1970.rounded(.down))
        v.r.valid = Date(timeIntervalSince1970: v.r.valid.timeIntervalSince1970.rounded(.down))
        return v
    }

    static func key(_ v: VerifiedRecord) -> GroupKey {
        GroupKey(loc: v.r.loc, valid: v.r.valid)
    }

    /// Deterministic tie-break for records issued in the same second.
    private static func tieKey(_ v: VerifiedRecord) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Union of `a` and `b`, de-duplicated by (location, valid hour, issuance within 90 min, model).
    /// - Parameters:
    ///   - resetAt: drop records issued before this.
    ///   - now: when given, keep only `windowDays` (by valid time) and at most `maxRecords`.
    public static func merge(_ a: [VerifiedRecord], _ b: [VerifiedRecord], resetAt: Date? = nil,
                             now: Date? = nil) -> [VerifiedRecord] {
        let cutoff = now.map { $0.addingTimeInterval(-windowDays * 86400) }
        var groups: [GroupKey: [VerifiedRecord]] = [:]
        for raw in a + b {
            let v = normalized(raw)
            if let resetAt, v.r.issued < resetAt { continue }
            if let cutoff, v.r.valid < cutoff { continue }
            groups[key(v), default: []].append(v)
        }
        var out: [VerifiedRecord] = []
        out.reserveCapacity(groups.count)
        for (_, members) in groups {
            let unique = Array(Set(members))
            let sorted = unique.count == 1 ? unique : unique.sorted {
                $0.r.issued != $1.r.issued ? $0.r.issued < $1.r.issued : tieKey($0) < tieKey($1)
            }
            var i = 0
            while i < sorted.count {
                var first = sorted[i]
                let end = first.r.issued.addingTimeInterval(sameIssuance)
                i += 1
                while i < sorted.count, sorted[i].r.issued < end {
                    for (model, values) in sorted[i].r.f where first.r.f[model] == nil { first.r.f[model] = values }
                    i += 1
                }
                out.append(first)
            }
        }
        out.sort {
            if $0.r.valid != $1.r.valid { return $0.r.valid < $1.r.valid }
            if $0.r.loc != $1.r.loc { return $0.r.loc < $1.r.loc }
            return $0.r.issued < $1.r.issued
        }
        if now != nil, out.count > maxRecords { out = Array(out.suffix(maxRecords)) }
        return out
    }
}

// MARK: Build 32: separate compact file + generation-counted reset (code review H1, H3)

/// "Reset Accuracy Data" as a generation counter (H3). The highest generation wins, so a later reset
/// always replaces an earlier one, even one stamped by a Mac whose clock was far ahead. `at` drops the
/// pairs issued before the reset; readers clamp a future `at` to their own clock.
public struct AccuracyReset: Codable, Equatable, Sendable {
    public var generation: Int
    public var at: Date

    public init(generation: Int, at: Date) { self.generation = generation; self.at = at }

    /// Clock tolerance between Macs before a reset stamp counts as future-dated.
    public static let futureTolerance: TimeInterval = 10 * 60

    /// `at` no later than `now` + tolerance (a Mac whose clock runs ahead can't block learning).
    public func clamped(now: Date) -> AccuracyReset {
        var r = self
        if r.at > now.addingTimeInterval(Self.futureTolerance) { r.at = now }
        r.at = Date(timeIntervalSince1970: r.at.timeIntervalSince1970.rounded(.down))
        return r
    }

    /// The reset that wins: higher generation; same generation, the earlier stamp (keeps more data,
    /// same answer on every Mac).
    public static func winner(_ a: AccuracyReset?, _ b: AccuracyReset?) -> AccuracyReset? {
        guard let a else { return b }
        guard let b else { return a }
        if a.generation != b.generation { return a.generation > b.generation ? a : b }
        return a.at <= b.at ? a : b
    }
}

/// `iCloud Drive/Skyline/accuracy.json`: the shared verified pairs, kept out of sync.json so city and
/// settings syncs stay ~1 KB and the pairs are only rewritten when new ones exist (H1). Compact
/// encoding: no pretty-printing, epoch-second integers, short keys, one array per model.
public struct AccuracyFile: Equatable, Sendable {
    public static let currentFormat = 1
    public var format = AccuracyFile.currentFormat
    public var reset: AccuracyReset?
    public var pairs: [VerifiedRecord] = []

    public init(reset: AccuracyReset? = nil, pairs: [VerifiedRecord] = []) {
        self.reset = reset; self.pairs = pairs
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(Wire(self))
    }

    /// Nil for a file that isn't a readable accuracy file (or a newer format).
    public static func decode(_ data: Data) -> AccuracyFile? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), w.v <= currentFormat else { return nil }
        return w.file
    }

    /// Merge this Mac's pairs with the file's (and any iCloud conflict versions).
    /// - Returns: the merged file, and whether it holds anything the file lacked (only then is it worth
    ///   writing; pairs dropped only because the 30-day window moved don't count).
    public static func merge(local: AccuracyFile, remote: AccuracyFile?, now: Date) -> (file: AccuracyFile, hasNew: Bool) {
        let reset = AccuracyReset.winner(local.reset?.clamped(now: now), remote?.reset?.clamped(now: now))
        let pairs = AccuracySync.merge(local.pairs, remote?.pairs ?? [], resetAt: reset?.at, now: now)
        let out = AccuracyFile(reset: reset, pairs: pairs)
        guard let remote else { return (out, !pairs.isEmpty || reset != nil) }
        // Compare with the file pruned by the same rules (same `now`), so window drops aren't "new".
        let remotePruned = AccuracySync.merge(remote.pairs, [], resetAt: reset?.at, now: now)
        let hasNew = reset != remote.reset?.clamped(now: now) || pairs != remotePruned
        return (out, hasNew)
    }

    // MARK: Wire format

    /// {"v":1,"reset":{"g":gen,"at":epoch},"locs":[...],"models":[...],
    ///  "g":[{"l":locIndex,"i":issuedEpoch,"r":[[validMinusIssued, obsT, obsW, obsWet, obsP,
    ///                                           modelIndex, t, pop, p, w, modelIndex, ...], ...]}]}
    /// Rows are grouped by issuance (one location/issue time shared by ~21 rows); location and model
    /// names are stored once. Values are kept at full precision (scores are unchanged); null = missing.
    private struct Wire: Codable {
        var v: Int
        var reset: ResetWire?
        var locs: [String]
        var models: [String]
        var g: [Group?]

        struct ResetWire: Codable { var g: Int; var at: Int64 }
        /// Lenient (M3): a malformed group or row is skipped, never the whole file.
        struct Group: Codable {
            var l: Int; var i: Int64; var r: [[Double?]]
            init(l: Int, i: Int64, r: [[Double?]]) { self.l = l; self.i = i; self.r = r }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                l = try c.decode(Int.self, forKey: .l)
                i = try c.decode(Int64.self, forKey: .i)
                r = (try c.decode([Lenient<[Double?]>].self, forKey: .r)).compactMap(\.value)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try c.decode(Int.self, forKey: .v)
            reset = try? c.decodeIfPresent(ResetWire.self, forKey: .reset)
            locs = try c.decode([String].self, forKey: .locs)
            models = try c.decode([String].self, forKey: .models)
            g = (try c.decode([Lenient<Group>].self, forKey: .g)).map(\.value)
        }

        init(_ f: AccuracyFile) {
            v = f.format
            reset = f.reset.map { ResetWire(g: $0.generation, at: Int64($0.at.timeIntervalSince1970.rounded(.down))) }
            locs = Array(Set(f.pairs.map(\.r.loc))).sorted()
            models = Array(Set(f.pairs.flatMap(\.r.f.keys))).sorted()
            let locIndex = Dictionary(uniqueKeysWithValues: locs.enumerated().map { ($1, $0) })
            let modelIndex = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($1, $0) })
            struct Key: Hashable { var l: Int; var i: Int64 }
            var groups: [Key: [[Double?]]] = [:]
            var order: [Key] = []
            for p in f.pairs {
                let issued = Int64(p.r.issued.timeIntervalSince1970.rounded(.down))
                let valid = Int64(p.r.valid.timeIntervalSince1970.rounded(.down))
                let key = Key(l: locIndex[p.r.loc]!, i: issued)
                // Non-finite values become null (M3): JSONEncoder throws on NaN/Inf.
                var row: [Double?] = [Double(valid - issued), finite(p.o.t), finite(p.o.w), p.o.wet.map { $0 ? 1 : 0 }, finite(p.o.p)]
                for name in p.r.f.keys.sorted() {
                    let s = p.r.f[name]!
                    row += [Double(modelIndex[name]!), finite(s.t), finite(s.pop), finite(s.p), finite(s.w)]
                }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(row)
            }
            g = order.map { Group(l: $0.l, i: $0.i, r: groups[$0]!) }
        }

        var file: AccuracyFile? {
            var pairs: [VerifiedRecord] = []
            for case let group? in g {
                guard locs.indices.contains(group.l) else { continue }
                let issued = Date(timeIntervalSince1970: TimeInterval(group.i))
                rows: for row in group.r {
                    guard row.count >= 5, (row.count - 5) % 5 == 0, let d = row[0], d.isFinite else { continue }
                    var f: [String: SourceValues] = [:]
                    var k = 5
                    while k < row.count {
                        guard let m = row[k], m >= 0, Int(m) < models.count else { continue rows }
                        f[models[Int(m)]] = SourceValues(t: row[k + 1], pop: row[k + 2], p: row[k + 3], w: row[k + 4])
                        k += 5
                    }
                    pairs.append(VerifiedRecord(
                        ForecastRecord(loc: locs[group.l], issued: issued, valid: issued.addingTimeInterval(d), f: f),
                        ObservedHour(t: row[1], w: row[2], wet: row[3].map { $0 != 0 }, p: row[4])))
                }
            }
            return AccuracyFile(reset: reset.map { AccuracyReset(generation: $0.g, at: Date(timeIntervalSince1970: TimeInterval($0.at))) },
                                pairs: AccuracySync.merge(pairs, []))
        }
    }
}

private func finite(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }

/// Decodes a `T` or nil instead of failing the surrounding array (M3).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
