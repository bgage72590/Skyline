import Foundation

/// Picks which forecasts to keep for verification: a fixed ladder of lead times per issuance, each with
/// the blend's value and every source's raw value, so every source can be scored on equal terms.
public enum ForecastSampler {
    /// Lead times (hours) recorded per issuance: dense early, sparse later (~21 rows per issuance).
    public static let leads: [Int] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 21, 24, 30, 36, 42, 48, 60, 72, 96, 120]

    // MARK: DST daily-date accuracy compat (plan-dst / CR-signed)

    /// Issuances on or after this instant used corrected `dailyTimes`; never drop them for DST skew.
    /// 2026-11-01 06:00:00 UTC (America/New_York fall-back instant) — at/after install since this
    /// ships before then; named so scrub rules carry no bare date literals.
    public static let dstFixShipDate = Date(timeIntervalSince1970: 1_793_512_800)

    /// Open-Meteo `forecast_days` window: only groups issued inside this many days before a fall-back
    /// transition are eligible for the window scrub rule.
    public static let dstCompatLookbackDays = 10

    /// `(loc, localDay)` pairs removed from pre-ship daily issues (and matching daily training rows).
    public struct DSTDroppedDay: Hashable, Sendable {
        public var loc: String
        public var localDay: Date
        public init(loc: String, localDay: Date) { self.loc = loc; self.localDay = localDay }
    }

    private struct IssueGroupKey: Hashable {
        var loc: String
        var issued: Date
    }

    /// Drop pre-`dstFixShipDate` daily-issue rows skewed by the Open-Meteo fixed-offset DST bug.
    /// Duplicate rule: if a (loc, issued) group has a duplicate `localDay`, drop days on/after the first
    /// duplicated day. Window rule: fall-back only (offset decreases); if issued is within
    /// `dstCompatLookbackDays` before the change, drop days on/after the transition's local day.
    /// Post-ship groups are never modified.
    public static func scrubDSTSkewedDailyIssues(_ issues: [DailyForecastIssue])
        -> (kept: [DailyForecastIssue], dropped: Set<DSTDroppedDay>) {
        var kept: [DailyForecastIssue] = []
        var dropped = Set<DSTDroppedDay>()
        for (_, rows) in Dictionary(grouping: issues, by: { IssueGroupKey(loc: $0.loc, issued: $0.issued) }) {
            let part = scrubDSTSkewedIssueGroup(rows)
            kept.append(contentsOf: part.kept)
            dropped.formUnion(part.dropped)
        }
        return (kept, dropped)
    }

    /// Drop dailyHigh/dailyLow training rows whose `(loc, localDay)` was scrubbed from daily issues.
    public static func scrubDSTSkewedTraining(_ rows: [TrainingRow], dropped: Set<DSTDroppedDay>) -> [TrainingRow] {
        guard !dropped.isEmpty else { return rows }
        return rows.filter { row in
            guard row.target.isDaily else { return true }
            return !dropped.contains(DSTDroppedDay(loc: row.loc, localDay: row.localDay))
        }
    }

    private static func scrubDSTSkewedIssueGroup(_ rows: [DailyForecastIssue])
        -> (kept: [DailyForecastIssue], dropped: Set<DSTDroppedDay>) {
        guard let sample = rows.first else { return ([], []) }
        if sample.issued >= dstFixShipDate {
            return (rows, [])
        }
        var thresholds: [Date] = []
        if let dup = firstDuplicatedLocalDay(in: rows) {
            thresholds.append(dup)
        }
        if let tz = TimeZone(identifier: sample.timeZoneIdentifier),
           let fall = firstFallBackLocalDay(after: sample.issued, timeZone: tz,
                                            withinDays: dstCompatLookbackDays) {
            thresholds.append(fall)
        }
        guard let cut = thresholds.min() else { return (rows, []) }
        var kept: [DailyForecastIssue] = []
        var dropped = Set<DSTDroppedDay>()
        for row in rows {
            if row.localDay >= cut {
                dropped.insert(DSTDroppedDay(loc: row.loc, localDay: row.localDay))
            } else {
                kept.append(row)
            }
        }
        return (kept, dropped)
    }

    /// Earliest `localDay` that appears more than once in the group (calendar order).
    private static func firstDuplicatedLocalDay(in rows: [DailyForecastIssue]) -> Date? {
        var counts: [TimeInterval: Int] = [:]
        for day in rows.map(\.localDay) {
            counts[day.timeIntervalSince1970, default: 0] += 1
        }
        let dups = rows.map(\.localDay).filter { counts[$0.timeIntervalSince1970, default: 0] > 1 }
        return dups.min()
    }

    /// Local start-of-day of the next fall-back (offset decreases) in `(issued, issued+withinDays]`.
    private static func firstFallBackLocalDay(after issued: Date, timeZone tz: TimeZone,
                                              withinDays: Int) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let limit = cal.date(byAdding: .day, value: withinDays, to: issued) else { return nil }
        var cursor = issued
        while let next = tz.nextDaylightSavingTimeTransition(after: cursor), next <= limit {
            let before = tz.secondsFromGMT(for: next.addingTimeInterval(-1))
            let after = tz.secondsFromGMT(for: next.addingTimeInterval(1))
            if after < before {
                return cal.startOfDay(for: next)
            }
            cursor = next
        }
        return nil
    }

    public static func records(location key: String, issued: Date, openMeteo om: OpenMeteoResponse,
                               nwsHourly: [NWSPeriod], blended: [HourlyForecast]) -> [ForecastRecord] {
        let times = om.hourlyTimes
        let models = om.modelsWithData
        let leadSet = Set(leads)
        let nwsByHour = Dictionary(nwsHourly.map { (Int($0.startTime.timeIntervalSince1970 / 3600), $0) },
                                   uniquingKeysWith: { a, _ in a })
        // Rain chance pairs with the NWS period that ends at the valid time (the observed "wet" hour and
        // Open-Meteo's precipitation fields cover the hour *ending* then).
        let nwsByEndHour = Dictionary(nwsHourly.map { (Int($0.endTime.timeIntervalSince1970 / 3600), $0) },
                                      uniquingKeysWith: { a, _ in a })
        let blendByHour = Dictionary(blended.map { (Int($0.time.timeIntervalSince1970 / 3600), $0) },
                                     uniquingKeysWith: { a, _ in a })
        var columns: [ForecastModel: [String: [Double?]]] = [:]
        for m in models {
            columns[m] = Dictionary(uniqueKeysWithValues: ["temperature_2m", "precipitation_probability", "precipitation", "wind_speed_10m"]
                .map { ($0, om.hourlyColumn($0, model: m) ?? []) })
        }
        func at(_ m: ForecastModel, _ v: String, _ i: Int) -> Double? {
            guard let c = columns[m]?[v], i < c.count else { return nil }
            return c[i]
        }

        var out: [ForecastRecord] = []
        for (i, time) in times.enumerated() {
            let lead = time.timeIntervalSince(issued) / 3600
            guard lead > 0.5, leadSet.contains(Int(lead.rounded())), abs(lead - lead.rounded()) < 0.5 else { continue }
            var f: [String: SourceValues] = [:]
            for m in models {
                let v = SourceValues(t: at(m, "temperature_2m", i), pop: at(m, "precipitation_probability", i),
                                     p: at(m, "precipitation", i), w: at(m, "wind_speed_10m", i))
                if !v.isEmpty { f[VerificationSource(m).rawValue] = v }
            }
            let hourKey = Int(time.timeIntervalSince1970 / 3600)
            let n = nwsByHour[hourKey], np = nwsByEndHour[hourKey]
            let nv = SourceValues(t: n?.temperatureC, pop: np?.probabilityOfPrecipitation, w: n?.windSpeedKmh)
            if !nv.isEmpty { f[VerificationSource.nws.rawValue] = nv }
            if let b = blendByHour[hourKey] {
                f[VerificationSource.blend.rawValue] = SourceValues(t: b.temperature, pop: b.precipitationProbability,
                                                                    p: b.precipitation, w: b.windSpeed)
            }
            let record = ForecastRecord(loc: key, issued: issued, valid: time, f: f).dedupingNOAAFamily(dropDuplicates: false)
            if record.f.count > 1 { out.append(record) }
        }
        return out
    }

    // MARK: Accuracy PR 1 — additive benchmark / daily emitters (existing `records` unchanged)

    /// Daily high/low forecasts for local-day verification (isolated store). Includes Skyline blend,
    /// NWS and Best Match when present, and MET Norway when supplied.
    /// `blendedHourly` is the RAW (uncorrected) blend — used only for `rawHourlyMaxC` / `rawHourlyMinC`.
    public static func dailyIssues(location key: String, issued: Date, daily: [DailyForecast],
                                   openMeteo om: OpenMeteoResponse, timeZone: TimeZone,
                                   metNorway: [MetNorwayHour] = [],
                                   blendedHourly: [HourlyForecast] = []) -> [DailyForecastIssue] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let tzID = timeZone.identifier
        var out: [DailyForecastIssue] = []
        for day in daily {
            let localDay = cal.startOfDay(for: day.date)
            var highs: [String: Double] = [BenchmarkForecastKind.skyline.rawValue: day.high]
            var lows: [String: Double] = [BenchmarkForecastKind.skyline.rawValue: day.low]
            if let nws = day.sources.first(where: { $0.name.hasPrefix("NWS") }) {
                if let h = nws.high { highs[BenchmarkForecastKind.nws.rawValue] = h }
                if let l = nws.low { lows[BenchmarkForecastKind.nws.rawValue] = l }
            }
            // Best Match daily columns from Open-Meteo.
            let times = om.dailyTimes
            if let idx = times.firstIndex(where: { abs($0.timeIntervalSince(localDay)) < 12 * 3600 }) {
                let hi = om.dailyColumn("temperature_2m_max", model: .bestMatch)
                let lo = om.dailyColumn("temperature_2m_min", model: .bestMatch)
                if let hi, idx < hi.count, let v = hi[idx] { highs[BenchmarkForecastKind.bestMatch.rawValue] = v }
                if let lo, idx < lo.count, let v = lo[idx] { lows[BenchmarkForecastKind.bestMatch.rawValue] = v }
            }
            if let ext = METNorwayClient.dailyExtremes(hours: metNorway, day: localDay, timeZone: timeZone) {
                highs[BenchmarkForecastKind.metNorway.rawValue] = ext.high
                lows[BenchmarkForecastKind.metNorway.rawValue] = ext.low
            }
            let dayHours = blendedHourly.filter {
                $0.time >= localDay && cal.isDate($0.time, inSameDayAs: localDay)
            }.map(\.temperature)
            let rawMax = dayHours.max()
            let rawMin = dayHours.min()
            out.append(DailyForecastIssue(loc: key, issued: issued, localDay: localDay,
                                          timeZoneIdentifier: tzID, highs: highs, lows: lows,
                                          rawHourlyMaxC: rawMax, rawHourlyMinC: rawMin))
        }
        return out
    }

    /// Hourly MET Norway values on the same lead ladder as `records` (benchmark store only).
    public static func metNorwayLeadValues(location key: String, issued: Date,
                                           hours: [MetNorwayHour]) -> [(valid: Date, t: Double)] {
        let leadSet = Set(leads)
        let byHour = Dictionary(hours.compactMap { h -> (Int, MetNorwayHour)? in
            guard h.temperatureC != nil else { return nil }
            return (Int(h.time.timeIntervalSince1970 / 3600), h)
        }, uniquingKeysWith: { a, _ in a })
        var out: [(Date, Double)] = []
        for lead in leads {
            let valid = issued.addingTimeInterval(TimeInterval(lead) * 3600)
            let hourKey = Int(valid.timeIntervalSince1970 / 3600)
            guard leadSet.contains(lead), let h = byHour[hourKey], let t = h.temperatureC else { continue }
            out.append((valid, t))
        }
        return out
    }
}
