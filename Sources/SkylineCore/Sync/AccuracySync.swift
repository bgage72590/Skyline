import Foundation

/// Sharing the forecast-vs-NWS accuracy learning between Macs (build 31). The scorecard and the adaptive
/// blend weights are both computed from verified pairs, so the pairs are what travels in sync.json.
///
/// Merge rule: a grow-only set with de-duplication. Two records describe the same verification when they
/// share location key (the station's place), valid hour and issuance slot (3 h, the issue interval, so one
/// Mac never has two records in one slot). Within such a group each model is counted once: the earliest
/// issued record's value wins, other Macs only fill models it lacks. The result is the same whatever order
/// Macs merge in (commutative, idempotent), so both Macs converge.
/// A reset ("Reset Accuracy Data") is a stamp: records issued before the newest reset are dropped everywhere.
public enum AccuracySync {
    /// Only the most recent pairs travel (each Mac keeps its own 90-day history locally).
    public static let windowDays = 30.0
    /// Hard cap on synced pairs (~470 bytes each), newest kept.
    public static let maxRecords = 15_000
    public static let slot: TimeInterval = ForecastVerifier.issueInterval

    struct GroupKey: Hashable {
        let loc: String
        let valid: Date
        let slot: Int64
    }

    static func normalized(_ v: VerifiedRecord) -> VerifiedRecord {
        // sync.json stores whole-second ISO 8601 dates; normalize so a round trip is identical.
        var v = v
        v.r.issued = Date(timeIntervalSince1970: v.r.issued.timeIntervalSince1970.rounded(.down))
        v.r.valid = Date(timeIntervalSince1970: v.r.valid.timeIntervalSince1970.rounded(.down))
        return v
    }

    static func key(_ v: VerifiedRecord) -> GroupKey {
        GroupKey(loc: v.r.loc, valid: v.r.valid, slot: Int64((v.r.issued.timeIntervalSince1970 / slot).rounded(.down)))
    }

    /// Deterministic tie-break for records issued in the same second.
    private static func tieKey(_ v: VerifiedRecord) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Union of `a` and `b`, de-duplicated by (location, valid hour, issuance slot, model).
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
        if now != nil, out.count > maxRecords { out = Array(out.suffix(maxRecords)) }
        return out
    }
}
