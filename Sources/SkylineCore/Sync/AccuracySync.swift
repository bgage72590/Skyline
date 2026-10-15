import Foundation

/// Sharing the forecast-vs-NWS accuracy learning between Macs (build 31). The scorecard and the adaptive
/// blend weights are both computed from verified pairs, so the pairs are what travels in sync.json.
///
/// Merge rule (build 35, build-34 review N-M1): a grow-only set keyed by (location, issue time, valid
/// hour). Copies of the same record from two Macs are one record (models filled in, deterministic tie-break);
/// nothing else is combined on disk, so merging is a plain set union: commutative, associative and
/// idempotent, and the Macs converge whatever order they merge in.
/// Cross-Mac duplicates (two Macs issuing the same forecast minutes apart) are collapsed only when
/// scoring, by `collapsedForScoring`, from the full set every time, so the result never depends on merge
/// order either. A reset ("Reset Accuracy Data") drops records issued before it everywhere.
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

    struct RecordKey: Hashable {
        let loc: String
        let valid: Date
        let issued: Date
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

    /// Union of `a` and `b` (same location, valid hour and issue time = one record).
    /// - Parameters:
    ///   - resetAt: drop records issued before this.
    ///   - now: when given, keep only `windowDays` (by valid time) and at most `maxRecords`.
    public static func merge(_ a: [VerifiedRecord], _ b: [VerifiedRecord], resetAt: Date? = nil,
                             now: Date? = nil) -> [VerifiedRecord] {
        let cutoff = now.map { $0.addingTimeInterval(-windowDays * 86400) }
        var groups: [RecordKey: [VerifiedRecord]] = [:]
        for raw in a + b {
            let v = normalized(raw)
            if let resetAt, v.r.issued < resetAt { continue }
            if let cutoff, v.r.valid < cutoff { continue }
            groups[RecordKey(loc: v.r.loc, valid: v.r.valid, issued: v.r.issued), default: []].append(v)
        }
        var out: [VerifiedRecord] = []
        out.reserveCapacity(groups.count)
        for (_, members) in groups {
            let unique = Array(Set(members))
            let sorted = unique.count == 1 ? unique : unique.sorted {
                $0.r.issued != $1.r.issued ? $0.r.issued < $1.r.issued : tieKey($0) < tieKey($1)
            }
            // Same (location, valid, issue time): one record, models filled in from the other copies.
            var first = sorted[0]
            for other in sorted.dropFirst() {
                for (model, values) in other.r.f where first.r.f[model] == nil { first.r.f[model] = values }
            }
            out.append(first)
        }
        out.sort {
            if $0.r.valid != $1.r.valid { return $0.r.valid < $1.r.valid }
            if $0.r.loc != $1.r.loc { return $0.r.loc < $1.r.loc }
            return $0.r.issued < $1.r.issued
        }
        if now != nil, out.count > maxRecords { out = capped(out) }
        return out
    }

    /// Hard ceiling on stored pairs (file size) when two Macs each store their copy (QA S1).
    public static let maxStoredRecords = maxRecords * 2

    /// Newest records kept so the *scored* (cross-Mac collapsed) count is at most `maxRecords`, within
    /// `maxStoredRecords` stored. Build 45 (QA S1): two Macs' copies of one forecast no longer halve
    /// how many days are kept. A function of the sorted set only, so merge order still doesn't matter.
    static func capped(_ sorted: [VerifiedRecord]) -> [VerifiedRecord] {
        var lo = max(0, sorted.count - maxStoredRecords), hi = sorted.count - maxRecords
        // Smallest start index whose suffix scores at most maxRecords (scored count shrinks with the suffix).
        while lo < hi {
            let mid = (lo + hi) / 2
            if collapsedForScoring(Array(sorted[mid...])).count <= maxRecords { hi = mid } else { lo = mid + 1 }
        }
        return Array(sorted[lo...])
    }

    /// Cross-Mac duplicates collapsed for scoring (build 35): per location and valid hour, issuances are
    /// split into runs no wider than `sameIssuance` (90 min) from the run's first issuance; each
    /// run counts once (earliest issue time and its values, later ones only fill missing models). One Mac's
    /// own issuances are >= 3 h apart, so they never collapse. Computed from the whole set every time, so
    /// it doesn't depend on merge order.
    public static func collapsedForScoring(_ records: [VerifiedRecord]) -> [VerifiedRecord] {
        var groups: [GroupKey: [VerifiedRecord]] = [:]
        for v in records { groups[GroupKey(loc: v.r.loc, valid: v.r.valid), default: []].append(v) }
        var out: [VerifiedRecord] = []
        out.reserveCapacity(groups.count)
        for (_, members) in groups {
            if members.count == 1 { out.append(members[0]); continue }
            let sorted = members.sorted {
                $0.r.issued != $1.r.issued ? $0.r.issued < $1.r.issued : tieKey($0) < tieKey($1)
            }
            // Build 42 (review build-41 M5): a run spans less than 90 min from its *first* issuance, so a
            // chain of Macs (0 → 70 → 140 → 180 min) can never fold one Mac's own issuances, 3 h apart,
            // into one. Still a function of the sorted set only, so merge order doesn't matter.
            var run = sorted[0]
            for v in sorted.dropFirst() {
                if v.r.issued.timeIntervalSince(run.r.issued) >= sameIssuance {
                    out.append(run)
                    run = v
                } else {
                    for (model, values) in v.r.f where run.r.f[model] == nil { run.r.f[model] = values }
                }
            }
            out.append(run)
        }
        out.sort {
            if $0.r.valid != $1.r.valid { return $0.r.valid < $1.r.valid }
            if $0.r.loc != $1.r.loc { return $0.r.loc < $1.r.loc }
            return $0.r.issued < $1.r.issued
        }
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
    /// A future `at` is pulled back to when the file carrying it was written (`writtenBound`: the
    /// writer's `writtenAt` when plausible, or the file's modification date), not just to this Mac's
    /// clock, so pairs issued after the real reset but before this Mac read it are kept (build-32
    /// review M2). Without a bound it falls back to `now`.
    public func clamped(now: Date, writtenBound: Date? = nil, writerClock: Date? = nil, fileDate: Date? = nil) -> AccuracyReset {
        var r = self
        // Build 42 (review build-41 L1): when the writer's own `writtenAt` is in the future, its clock is
        // ahead by about that much; take the skew off its stamp first, so a reset written by a fast Mac
        // lands near when it really happened instead of at this Mac's "now".
        // Skew = writer's stamp minus the file's modification date when there is one (both taken at write
        // time), else minus this Mac's now (an under-estimate if the file sat unread).
        if let writerClock, writerClock > now.addingTimeInterval(Self.futureTolerance), r.at > now {
            let reference = fileDate.map { min($0, now) } ?? now
            r.at = r.at.addingTimeInterval(-writerClock.timeIntervalSince(reference))
            if let writtenBound { r.at = min(r.at, writtenBound) }
        }
        if r.at > now.addingTimeInterval(Self.futureTolerance) { r.at = min(now, writtenBound ?? now) }
        r.at = Date(timeIntervalSince1970: r.at.timeIntervalSince1970.rounded(.down))
        return r
    }

    /// The reset that wins: higher generation; same generation, the earlier stamp, deterministically
    /// (keeps more data, same answer on every Mac whatever order they merge in).
    public static func winner(_ a: AccuracyReset?, _ b: AccuracyReset?) -> AccuracyReset? {
        guard let a else { return b }
        guard let b else { return a }
        if a.generation != b.generation { return a.generation > b.generation ? a : b }
        // Same generation: the earlier stamp wins (Brian's decision; keeps more data, deterministic).
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
    /// When the writer wrote the file, by its clock (bounds a future-dated reset, see `clamped`).
    public var writtenAt: Date?

    public init(reset: AccuracyReset? = nil, pairs: [VerifiedRecord] = [], writtenAt: Date? = nil) {
        self.reset = reset; self.pairs = pairs; self.writtenAt = writtenAt
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
    public static func merge(local: AccuracyFile, remote: AccuracyFile?, now: Date,
                             remoteFileDate: Date? = nil) -> (file: AccuracyFile, hasNew: Bool) {
        // Best estimate of when the remote file (and any reset in it) was written: the writer's own stamp
        // when it isn't in the future, else the file's modification date.
        let tolerance = AccuracyReset.futureTolerance
        let plausibleWrite = remote?.writtenAt.flatMap { $0 <= now.addingTimeInterval(tolerance) ? $0 : nil }
        let bound = [plausibleWrite, remoteFileDate].compactMap { $0 }.min()
        let remoteReset = remote?.reset?.clamped(now: now, writtenBound: bound, writerClock: remote?.writtenAt, fileDate: remoteFileDate)
        let reset = AccuracyReset.winner(local.reset?.clamped(now: now), remoteReset)
        let pairs = AccuracySync.merge(local.pairs, remote?.pairs ?? [], resetAt: reset?.at, now: now)
        let out = AccuracyFile(reset: reset, pairs: pairs)
        guard let remote else { return (out, !pairs.isEmpty || reset != nil) }
        // Compare with the file pruned by the same rules (same `now`), so window drops aren't "new".
        let remotePruned = AccuracySync.merge(remote.pairs, [], resetAt: reset?.at, now: now)
        let hasNew = reset != remoteReset || pairs != remotePruned
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
        var w: Int64?
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
            w = try? c.decodeIfPresent(Int64.self, forKey: .w)
            locs = try c.decode([String].self, forKey: .locs)
            models = try c.decode([String].self, forKey: .models)
            g = (try c.decode([Lenient<Group>].self, forKey: .g)).map(\.value)
        }

        init(_ f: AccuracyFile) {
            v = f.format
            reset = f.reset.map { ResetWire(g: $0.generation, at: Int64($0.at.timeIntervalSince1970.rounded(.down))) }
            w = f.writtenAt.map { Int64($0.timeIntervalSince1970.rounded(.down)) }
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
                                pairs: AccuracySync.merge(pairs, []),
                                writtenAt: w.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }
}

private func finite(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }

/// Decodes a `T` or nil instead of failing the surrounding array (M3).
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// One-at-a-time runner state for the accuracy sync (build-32 review M1). A request that arrives while a
/// pass runs is folded into one follow-up pass (its `force` kept), so passes never overlap and a burst of
/// requests costs at most one extra pass. Pure state so it can be unit-tested; the actor holds one.
public struct CoalescingGate: Sendable {
    public private(set) var running = false
    private var rerun = false
    private var rerunForce = false

    public init() {}

    /// Ask to run. True: start a pass now. False: one is running; it will do another pass afterwards.
    public mutating func begin(force: Bool) -> Bool {
        if running { rerun = true; rerunForce = rerunForce || force; return false }
        running = true
        return true
    }

    /// After a pass: the `force` for one more pass, or nil when done (the gate is then free).
    public mutating func next() -> Bool? {
        guard rerun else { running = false; return nil }
        let f = rerunForce
        rerun = false; rerunForce = false
        return f
    }
}
