import Foundation
import XCTest
@testable import SkylineCore

/// Offline walk-forward reblend of `verified.jsonl` (M1 pairing). Not a product target.
/// Set `SKYLINE_VERIFIED_JSONL` to the verified file. Prints neutral, tip-eligibility, and
/// USA rate-limited held-out MAE. Does not fail the suite on the A9 bar; the ship gate reads the log.
final class WalkForwardReplayTests: XCTestCase {
    private struct Acc {
        var sum = 0.0
        var n = 0
        mutating func add(forecast: Double, obs: Double) {
            sum += abs(forecast - obs)
            n += 1
        }
        var maeF: Double? { n > 0 ? (sum / Double(n)) * 1.8 : nil }
    }

    private static let fair6Sources: [VerificationSource] = [.blend, .nws, .ecmwf, .icon, .hrrr, .bestMatch]
    private static let fair5Sources: [VerificationSource] = [.blend, .nws, .ecmwf, .icon, .bestMatch]
    private static let modelOrder: [ForecastModel] = [.bestMatch, .hrrr, .ecmwf, .gfs, .icon]

    func testWalkForwardHeldOutOnVerifiedWindow() throws {
        guard let path = ProcessInfo.processInfo.environment["SKYLINE_VERIFIED_JSONL"],
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        let records = try Self.load(path)
        let latest = Self.latestIssued(records)
        let fair6 = latest.filter { Self.hasTemperatures($0, Self.fair6Sources) }
        let fair5 = latest.filter { Self.hasTemperatures($0, Self.fair5Sources) }
        var stored = Acc()
        for rec in fair6 {
            if let b = rec.r.values(.blend)?.t, let o = rec.o.t { stored.add(forecast: b, obs: o) }
        }
        XCTAssertEqual(fair6.count, 3433, "M1 fair6 hour count")
        XCTAssertEqual(stored.maeF ?? -1, 1.962, accuracy: 0.0006, "M1 stored Skyline MAE °F")

        let byLoc = Dictionary(grouping: records, by: { $0.r.loc })
        let days = Array(Set(fair6.map { Self.utcDay($0.r.valid) })).sorted()
        let neutral = Self.score(fair6: fair6, fair5: fair5, weights: { _, _ in .neutral })
        let tip = Self.walk(byLoc: byLoc, days: days, fair6: fair6, fair5: fair5, stricter: false, rateLimit: false)
        let usa = Self.walk(byLoc: byLoc, days: days, fair6: fair6, fair5: fair5, stricter: true, rateLimit: true)
        let report = Self.report(storedFair6: fair6, fair5: fair5, neutral: neutral, tip: tip, usa: usa)
        print(report)
        if let out = ProcessInfo.processInfo.environment["SKYLINE_WALKFORWARD_OUT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Replay

    private struct Scored {
        var overall: [String: Acc] = [:]
        var bucket624: [String: Acc] = [:]
        var city: [String: [String: Acc]] = [:]
        var anchorage: [String: Acc] = [:]
    }

    private static func walk(byLoc: [String: [VerifiedRecord]], days: [Int],
                             fair6: [VerifiedRecord], fair5: [VerifiedRecord],
                             stricter: Bool, rateLimit: Bool) -> Scored {
        var state: [String: [LeadBucket: [VerificationSource: Double]]] = [:]
        var lastDay: [String: String] = [:]
        var weightsByDay: [Int: [String: BlendWeights]] = [:]
        let sortedLocs = byLoc.mapValues { $0.sorted { $0.r.valid < $1.r.valid } }
        for day in days {
            var today: [String: BlendWeights] = [:]
            let now = Date(timeIntervalSince1970: Double(day + 1) * 86400 - 1)
            for (loc, recs) in sortedLocs {
                let hist = recs.prefix { utcDay($0.r.valid) <= day }
                guard !hist.isEmpty else { continue }
                let scores = AccuracyScorer.score(AccuracySync.collapsedForScoring(Array(hist)), now: now, dedupe: false)
                var cfg = AdaptiveWeighting.Config()
                let usa = AppliedTemperatureWeightStore.isUSALocationKey(loc)
                cfg.longLeadStricterGates = stricter && usa
                let proposal = AdaptiveWeighting.weights(from: scores, config: cfg)
                if rateLimit && usa, let coord = AppliedTemperatureWeightStore.coordinate(fromLocationKey: loc) {
                    let tz = AppliedTemperatureWeightStore.inferredTimeZone(for: coord)
                    let stamp = AppliedTemperatureWeightStore.localDayStamp(now, timeZone: tz)
                    let same = lastDay[loc] == stamp
                    let limited = AdaptiveWeighting.rateLimitedTemperatureWeights(
                        proposal: proposal, previous: state[loc], sameLocalDay: same)
                    state[loc] = limited
                    lastDay[loc] = stamp
                    today[loc] = AdaptiveWeighting.blendWeights(temperature: limited)
                } else {
                    today[loc] = proposal
                }
            }
            // Hours on this UTC day were scored with weights trained through the previous day.
            // `today` is the update as-of this day, used starting tomorrow. Stash the prior state
            // by scoring with the weights captured at the beginning of the loop — see `prior`.
            weightsByDay[day] = today
        }
        // Rebuild prior-day weights: day D uses the update computed at the end of D-1.
        var prior: [Int: [String: BlendWeights]] = [:]
        var running: [String: BlendWeights] = [:]
        for day in days {
            prior[day] = running
            running = weightsByDay[day] ?? running
        }
        return score(fair6: fair6, fair5: fair5) { rec, _ in
            prior[utcDay(rec.r.valid)]?[rec.r.loc] ?? .neutral
        }
    }

    private static func score(fair6: [VerifiedRecord], fair5: [VerifiedRecord],
                              weights: (VerifiedRecord, Bool) -> BlendWeights) -> Scored {
        var s = Scored()
        for rec in fair6 {
            add(rec, into: &s, anchorage: false, weights: weights(rec, true))
        }
        let anchorage = "61.2181,-149.9003"
        for rec in fair5 where rec.r.loc == anchorage {
            guard let o = rec.o.t, let blend = reblend(rec, weights(rec, true)) else { continue }
            s.anchorage["Skyline", default: Acc()].add(forecast: blend, obs: o)
            for (src, name) in [("nws", "NWS"), ("ecmwf_ifs025", "ECMWF"), ("icon_seamless", "ICON"),
                                ("best_match", "Best Match")] {
                if let t = rec.r.f[src]?.t { s.anchorage[name, default: Acc()].add(forecast: t, obs: o) }
            }
        }
        return s
    }

    private static func add(_ rec: VerifiedRecord, into s: inout Scored, anchorage: Bool, weights: BlendWeights) {
        guard let o = rec.o.t else { return }
        let names: [(VerificationSource, String)] = [
            (.nws, "NWS"), (.ecmwf, "ECMWF"), (.icon, "ICON"), (.hrrr, "GFS-HRRR"), (.bestMatch, "Best Match"),
        ]
        func put(_ name: String, _ forecast: Double, bucket: Bool) {
            s.overall[name, default: Acc()].add(forecast: forecast, obs: o)
            if bucket { s.bucket624[name, default: Acc()].add(forecast: forecast, obs: o) }
            s.city[rec.r.loc, default: [:]][name, default: Acc()].add(forecast: forecast, obs: o)
        }
        if let blend = reblend(rec, weights) {
            let in624 = rec.r.bucket == .h6to24
            put("Skyline", blend, bucket: in624)
            for (src, name) in names {
                if let t = rec.r.values(src)?.t { put(name, t, bucket: in624) }
            }
        }
    }

    private static func reblend(_ rec: VerifiedRecord, _ weights: BlendWeights) -> Double? {
        let coord = AppliedTemperatureWeightStore.coordinate(fromLocationKey: rec.r.loc)
        let lead = rec.r.leadHours
        let samples: [(model: ForecastModel, value: Double?, weight: Double)] = modelOrder.map { model in
            let src = VerificationSource(model)
            let base = ForecastBlender.weight(.model(model), variable: "temperature_2m",
                                              leadHours: lead, coordinate: coord)
            let m = weights.multiplier(.temperature, src, leadHours: lead)
            return (model, rec.r.values(src)?.t, base * m)
        }
        var merged = ForecastBlender.dedupedFamily(samples, bestMatchIsCopy: coord?.isInCONUS == true)
        if let nws = rec.r.values(.nws)?.t {
            let base = ForecastBlender.weight(.nws, variable: "temperature_2m", leadHours: lead, coordinate: coord)
            merged.append((nws, base * weights.multiplier(.temperature, .nws, leadHours: lead)))
        }
        return ForecastBlender.weightedMean(merged)
    }

    // MARK: Report

    private static let cities: [(loc: String, name: String)] = [
        ("40.7128,-74.0060", "New York"),
        ("37.7749,-122.4194", "San Francisco"),
        ("here@41.2,-73.2", "Bridgeport"),
        ("34.0522,-118.2437", "Los Angeles"),
        ("25.7743,-80.1937", "Miami"),
        ("27.9475,-82.4584", "Tampa"),
        ("26.7153,-80.0534", "Pompano Beach"),
        ("61.2181,-149.9003", "Anchorage"),
        ("64.8378,-147.7164", "Fairbanks"),
    ]

    private static func report(storedFair6: [VerifiedRecord], fair5: [VerifiedRecord],
                               neutral: Scored, tip: Scored, usa: Scored) -> String {
        let eps = 0.05
        var lines: [String] = []
        lines.append("Walk-forward held-out reblend (UTC valid-day, M1 fair6 pairing, MAE °F)")
        lines.append(String(format: "Stored fair6 Skyline %.3f n=%d (M1 1.962 / 3433)",
                            storedMAE(storedFair6).0, storedMAE(storedFair6).1))
        func block(_ title: String, _ s: Scored) {
            lines.append("")
            lines.append("== \(title) ==")
            let order = ["Skyline", "NWS", "ICON", "ECMWF", "Best Match", "GFS-HRRR"]
            for name in order {
                if let acc = s.overall[name], let m = acc.maeF {
                    lines.append(String(format: "  \(name) %.3f n=%d", m, acc.n))
                }
            }
            lines.append(String(format: "  6-24h Skyline %.3f  ICON %.3f  n=%d",
                                s.bucket624["Skyline"]?.maeF ?? -1,
                                s.bucket624["ICON"]?.maeF ?? -1,
                                s.bucket624["Skyline"]?.n ?? 0))
            for city in cities {
                let row = s.city[city.loc] ?? [:]
                let parts = ["Skyline", "NWS", "ECMWF", "ICON"].compactMap { name -> String? in
                    guard let m = row[name]?.maeF else { return nil }
                    return String(format: "\(name) %.3f", m)
                }
                if !parts.isEmpty { lines.append("  \(city.name): " + parts.joined(separator: " | ")) }
            }
            if let a = s.anchorage["Skyline"]?.maeF {
                let nws = s.anchorage["NWS"]?.maeF
                let ecm = s.anchorage["ECMWF"]?.maeF
                lines.append(String(format: "  Anchorage fair5: Skyline %.3f NWS %.3f ECMWF %.3f n=%d",
                                    a, nws ?? -1, ecm ?? -1, s.anchorage["Skyline"]?.n ?? 0))
            }
        }
        block("neutral m=1", neutral)
        block("tip eligibility 20/3 no rate limit", tip)
        block("USA 40/7 + |Δm|≤0.25", usa)

        let nyc = usa.city["40.7128,-74.0060"] ?? [:]
        let sf = usa.city["37.7749,-122.4194"] ?? [:]
        let sky = usa.overall["Skyline"]?.maeF
        let others = ["NWS", "ICON", "ECMWF", "Best Match", "GFS-HRRR"].compactMap { usa.overall[$0]?.maeF }
        let rank1 = sky != nil && others.allSatisfy { sky! <= $0 + 1e-9 }
        func le(_ a: Double?, _ b: Double?) -> Bool {
            guard let a, let b else { return false }
            return a <= b + eps
        }
        lines.append("")
        let nycPass = le(nyc["Skyline"]?.maeF, nyc["NWS"]?.maeF) ? "PASS" : "FAIL"
        let sfPass = le(sf["Skyline"]?.maeF, sf["ECMWF"]?.maeF) ? "PASS" : "FAIL"
        let bPass = le(usa.bucket624["Skyline"]?.maeF, usa.bucket624["ICON"]?.maeF) ? "PASS" : "FAIL"
        let oPass = (sky ?? 99) <= 1.962 + eps ? "PASS" : "FAIL"
        lines.append(String(format: "A9 NYC %.3f <= NWS+e %.3f ? \(nycPass)",
                            nyc["Skyline"]?.maeF ?? -1, (nyc["NWS"]?.maeF ?? -1) + eps))
        lines.append(String(format: "A9 SF %.3f <= ECMWF+e %.3f ? \(sfPass)",
                            sf["Skyline"]?.maeF ?? -1, (sf["ECMWF"]?.maeF ?? -1) + eps))
        lines.append(String(format: "A9 6-24h %.3f <= ICON+e %.3f ? \(bPass)",
                            usa.bucket624["Skyline"]?.maeF ?? -1, (usa.bucket624["ICON"]?.maeF ?? -1) + eps))
        lines.append(String(format: "A9 overall %.3f #1 \(rank1 ? "yes" : "no") <= 2.012 ? \(oPass)",
                            sky ?? -1))

        // Non-target winners: a M1 stored win or tie must not become a clear loss.
        var storedCity: [String: [String: Acc]] = [:]
        for rec in storedFair6 {
            guard let o = rec.o.t, let b = rec.r.values(.blend)?.t else { continue }
            storedCity[rec.r.loc, default: [:]]["Skyline", default: Acc()].add(forecast: b, obs: o)
            for (src, name) in [(VerificationSource.nws, "NWS"), (.ecmwf, "ECMWF"), (.icon, "ICON"),
                                (.hrrr, "GFS-HRRR"), (.bestMatch, "Best Match")] {
                if let t = rec.r.values(src)?.t {
                    storedCity[rec.r.loc, default: [:]][name, default: Acc()].add(forecast: t, obs: o)
                }
            }
        }
        let watch = ["here@41.2,-73.2", "34.0522,-118.2437", "25.7743,-80.1937", "27.9475,-82.4584"]
        var hold = true
        for loc in watch {
            let before = storedCity[loc] ?? [:]
            let after = usa.city[loc] ?? [:]
            guard let base = before["Skyline"]?.maeF else { continue }
            for name in ["NWS", "ECMWF", "ICON", "GFS-HRRR", "Best Match"] {
                guard let other = before[name]?.maeF, let now = after["Skyline"]?.maeF, let otherNow = after[name]?.maeF else { continue }
                if base <= other + eps, now > otherNow + eps {
                    hold = false
                    lines.append("A9 hold FAIL \(loc) vs \(name): stored \(base) now \(now) other \(otherNow)")
                }
            }
        }
        lines.append("A9 non-target fair6 winners hold? \(hold ? "PASS" : "FAIL")")
        let anchorage = "61.2181,-149.9003"
        var anchHold = true
        var storedAnch: [String: Acc] = [:]
        for rec in fair5 where rec.r.loc == anchorage {
            guard let o = rec.o.t, let b = rec.r.values(.blend)?.t else { continue }
            storedAnch["Skyline", default: Acc()].add(forecast: b, obs: o)
            for (src, name) in [("nws", "NWS"), ("ecmwf_ifs025", "ECMWF"), ("icon_seamless", "ICON"),
                                ("best_match", "Best Match")] {
                if let t = rec.r.f[src]?.t { storedAnch[name, default: Acc()].add(forecast: t, obs: o) }
            }
        }
        if let base = storedAnch["Skyline"]?.maeF, let nowSky = usa.anchorage["Skyline"]?.maeF {
            for name in ["NWS", "ECMWF", "ICON", "Best Match"] {
                guard let other = storedAnch[name]?.maeF, let otherNow = usa.anchorage[name]?.maeF else { continue }
                if base <= other + eps, nowSky > otherNow + eps {
                    anchHold = false
                    lines.append("A9 hold FAIL Anchorage vs \(name): stored \(base) now \(nowSky) other \(otherNow)")
                }
            }
            lines.append(String(format: "Anchorage fair5 stored Skyline %.3f reblend %.3f hold \(anchHold ? "PASS" : "FAIL")",
                                base, nowSky))
        }
        let a9 = le(nyc["Skyline"]?.maeF, nyc["NWS"]?.maeF)
            && le(sf["Skyline"]?.maeF, sf["ECMWF"]?.maeF)
            && le(usa.bucket624["Skyline"]?.maeF, usa.bucket624["ICON"]?.maeF)
            && rank1 && (sky ?? 99) <= 1.962 + eps && hold && anchHold
        lines.append("A9 all required? \(a9 ? "PASS" : "FAIL")")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func storedMAE(_ rows: [VerifiedRecord]) -> (Double, Int) {
        var a = Acc()
        for rec in rows {
            if let b = rec.r.values(.blend)?.t, let o = rec.o.t { a.add(forecast: b, obs: o) }
        }
        return (a.maeF ?? -1, a.n)
    }

    // MARK: Load

    private static func load(_ path: String) throws -> [VerifiedRecord] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        var out: [VerifiedRecord] = []
        out.reserveCapacity(40_000)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let rec = try? dec.decode(VerifiedRecord.self, from: Data(line)), rec.o.t != nil else { continue }
            out.append(rec)
        }
        return out
    }

    private static func latestIssued(_ records: [VerifiedRecord]) -> [VerifiedRecord] {
        var best: [String: VerifiedRecord] = [:]
        best.reserveCapacity(records.count / 4)
        for rec in records {
            let key = "\(rec.r.loc)|\(Int(rec.r.valid.timeIntervalSince1970))"
            if let cur = best[key], cur.r.issued >= rec.r.issued { continue }
            best[key] = rec
        }
        return Array(best.values)
    }

    private static func hasTemperatures(_ rec: VerifiedRecord, _ sources: [VerificationSource]) -> Bool {
        guard rec.o.t != nil else { return false }
        return sources.allSatisfy { rec.r.values($0)?.t != nil }
    }

    private static func utcDay(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }
}
