import Foundation

/// One line on the model comparison chart (L18): a model's (or NWS's, or the blend's) hourly temperature.
public struct ModelSeries: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var isBlend: Bool
    public var times: [Date]
    /// °C, same length as `times`.
    public var temperatures: [Double]
    public var id: String { name }

    public init(name: String, isBlend: Bool = false, times: [Date], temperatures: [Double]) {
        self.name = name; self.isBlend = isBlend; self.times = times; self.temperatures = temperatures
    }

    /// Spread between the warmest and coolest line at each shared hour (°C).
    public static func spread(_ series: [ModelSeries]) -> [(time: Date, spread: Double)] {
        let models = series.filter { !$0.isBlend }
        guard let first = models.first else { return [] }
        return first.times.indices.compactMap { i in
            let t = first.times[i]
            let values = models.compactMap { s in s.times.firstIndex(of: t).map { s.temperatures[$0] } }
            guard values.count >= 2 else { return nil }
            return (t, values.max()! - values.min()!)
        }
    }
}

extension ForecastBlender {
    /// The next `hours` of each model's temperature, NWS's and the blend's. A best_match that is a copy of
    /// GFS/HRRR is folded into the model it copies (named "GFS = Best Match"), so no line is drawn twice.
    public static func modelSeries(openMeteo om: OpenMeteoResponse, nwsHourly: [NWSPeriod], blended: [HourlyForecast],
                                   now: Date, hours: Int = 48) -> [ModelSeries] {
        let times = om.hourlyTimes
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(Double(hours) * 3600)
        let idx = times.indices.filter { times[$0] > start && times[$0] <= end }
        guard !idx.isEmpty else { return [] }
        var out: [ModelSeries] = []
        let bm = om.hourlyColumn("temperature_2m", model: .bestMatch) ?? []
        let copyOf: ForecastModel? = [ForecastModel.hrrr, .gfs].first { m in
            bestMatchIsCopy(bm, of: [om.hourlyColumn("temperature_2m", model: m) ?? []])
        }
        for m in om.modelsWithData {
            if m == .bestMatch, copyOf != nil { continue }
            guard let col = om.hourlyColumn("temperature_2m", model: m) else { continue }
            var t: [Date] = [], v: [Double] = []
            for i in idx where i < col.count { if let x = col[i] { t.append(times[i]); v.append(x) } }
            guard t.count >= 2 else { continue }
            let name = m == copyOf ? "\(m.displayName) = Best Match" : m.displayName
            out.append(ModelSeries(name: name, times: t, temperatures: v))
        }
        let nws = nwsHourly.filter { $0.startTime > start && $0.startTime <= end }
            .compactMap { p in p.temperatureC.map { (p.startTime, $0) } }
        if nws.count >= 2 {
            out.append(ModelSeries(name: "National Weather Service", times: nws.map(\.0), temperatures: nws.map(\.1)))
        }
        let b = blended.filter { $0.time > start && $0.time <= end }
        if b.count >= 2 {
            out.append(ModelSeries(name: "Skyline blend", isBlend: true, times: b.map(\.time), temperatures: b.map(\.temperature)))
        }
        return out
    }
}
