import Foundation

/// Picks which forecasts to keep for verification: a fixed ladder of lead times per issuance, each with
/// the blend's value and every source's raw value, so every source can be scored on equal terms.
public enum ForecastSampler {
    /// Lead times (hours) recorded per issuance: dense early, sparse later (~21 rows per issuance).
    public static let leads: [Int] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 21, 24, 30, 36, 42, 48, 60, 72, 96, 120]

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
    public static func dailyIssues(location key: String, issued: Date, daily: [DailyForecast],
                                   openMeteo om: OpenMeteoResponse, timeZone: TimeZone,
                                   metNorway: [MetNorwayHour] = []) -> [DailyForecastIssue] {
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
            out.append(DailyForecastIssue(loc: key, issued: issued, localDay: localDay,
                                          timeZoneIdentifier: tzID, highs: highs, lows: lows))
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
