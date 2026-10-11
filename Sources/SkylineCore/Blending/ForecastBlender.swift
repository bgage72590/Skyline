import Foundation

/// Combines several numerical models (via Open-Meteo) and the official NWS forecast into one forecast.
///
/// Strategy ("weighted consensus with a short-range specialist"):
/// * Averaging independent models beats any single model on average (the classic ensemble/consensus
///   result: errors partly cancel). We weight rather than plain-average so better sources count more.
/// * Open-Meteo `best_match` already selects the best regional model per location, so it gets a high base weight.
///   In the US it resolves to the same NOAA numbers as `gfs_seamless` (and `gfs_hrrr` for ~48 h), so identical
///   NOAA-family values are collapsed into one sample before averaging (`dedupedFamily`): one model, one vote.
/// * NOAA HRRR (3 km, hourly-updating, radar-assimilating) dominates the first ~18 h in the US, then fades
///   out by 36 h where its skill drops to global-model level.
/// * The NWS gridded forecast (forecaster-edited National Blend of Models) gets the highest steady weight in
///   the US because it is bias-corrected against local observations.
/// * ECMWF IFS gets more weight than GFS/ICON: it has the best verified global skill in the medium range.
/// Categorical fields (weather code, sunrise...) are not averaged: they come from the best available single
/// source and are then reconciled with the blended precipitation probability so icons and numbers agree.
public enum ForecastBlender {

    public enum Source: Hashable, Sendable {
        case model(ForecastModel)
        case nws
    }

    /// Weight for a source at a given forecast lead time (hours from now).
    public static func weight(_ source: Source, leadHours: Double) -> Double {
        switch source {
        case .nws: return 2.5
        case .model(.bestMatch): return 2.0
        case .model(.ecmwf): return 1.5
        case .model(.gfs): return 1.0
        case .model(.icon): return 1.0
        case .model(.hrrr):
            if leadHours <= 18 { return 3.0 }
            if leadHours >= 36 { return 0.5 }
            return 3.0 - (leadHours - 18) / 18 * 2.5
        }
    }

    /// Base weight for precipitation (probability and amount). In the first hours rain is a nowcasting
    /// problem: HRRR (radar-assimilating, 15-min output) and best_match (which uses HRRR/NBM-type
    /// short-range guidance in the US) get most of the weight and the coarse global models little;
    /// from 3 h to 6 h this fades linearly back to the normal weights.
    /// Note: Open-Meteo's `precipitation_probability_gfs_hrrr` is the GFS-family probability, not an HRRR
    /// product, so HRRR's weight here only ever applies to its precipitation *amount* (see `hrrrHasNoPoP`).
    public static func precipitationWeight(_ source: Source, leadHours: Double) -> Double {
        let normal = weight(source, leadHours: leadHours)
        let short: Double = switch source {
        case .model(.hrrr): 5.0
        case .model(.bestMatch): 2.5
        case .nws: 2.0
        case .model(.ecmwf): 0.75
        case .model(.gfs), .model(.icon): 0.5
        }
        if leadHours <= 3 { return short }
        if leadHours >= 6 { return normal }
        let f = (leadHours - 3) / 3
        return short + (normal - short) * f
    }

    /// Base weight for a variable (precipitation uses the short-range specialist weights).
    public static func weight(_ source: Source, variable: String, leadHours: Double) -> Double {
        switch variable {
        case "precipitation_probability", "precipitation": precipitationWeight(source, leadHours: leadHours)
        default: weight(source, leadHours: leadHours)
        }
    }

    /// How much the 15-minute nowcast counts in an hour's precipitation (amount and probability):
    /// 60 % for the hour now under way, fading to 0 by 3 h.
    public static func nowcastShare(leadHours: Double) -> Double {
        guard leadHours >= 0, leadHours < 3 else { return 0 }
        return 0.6 * (1 - leadHours / 3)
    }

    /// Weighted mean of (value, weight) pairs, ignoring nil values. Nil when nothing is available.
    public static func weightedMean(_ samples: [(value: Double?, weight: Double)]) -> Double? {
        var sum = 0.0, total = 0.0
        for s in samples {
            guard let v = s.value, v.isFinite, s.weight > 0 else { continue }
            sum += v * s.weight
            total += s.weight
        }
        return total > 0 ? sum / total : nil
    }

    // MARK: Hourly

    /// - Parameters:
    ///   - weights: learned per-location multipliers on the base weights (`.neutral` = fixed weights).
    ///   - minutely: the 15-minute nowcast; blended into precipitation for the next ~3 h.
    public static func blendHourly(openMeteo om: OpenMeteoResponse, nwsHourly: [NWSPeriod],
                                   now: Date, weights learned: BlendWeights = .neutral,
                                   minutely: [MinutelyPrecipitation] = []) -> [HourlyForecast] {
        let times = om.hourlyTimes
        guard !times.isEmpty else { return [] }
        let models = om.modelsWithData
        let nwsByHour = Dictionary(nwsHourly.map { (hourKey($0.startTime), $0) }, uniquingKeysWith: { a, _ in a })
        // Open-Meteo's precipitation fields at time T cover the *preceding* hour (T-1, T]; the NWS hourly
        // period covering that same hour is the one that *ends* at T. Instantaneous values (temperature,
        // wind, humidity) pair with the period starting at T as before.
        let nwsByEndHour = Dictionary(nwsHourly.map { (hourKey($0.endTime), $0) }, uniquingKeysWith: { a, _ in a })

        func col(_ v: String, _ m: ForecastModel) -> [Double?] { om.hourlyColumn(v, model: m) ?? [] }
        func at(_ c: [Double?], _ i: Int) -> Double? { i < c.count ? c[i] : nil }
        func modelValue(_ c: [Double?], _ i: Int, _ m: ForecastModel, _ variable: String) -> Double? {
            ignores(m, variable) ? nil : at(c, i)
        }

        // Pre-extract columns once.
        let variables = ["temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation",
                         "weather_code", "is_day", "uv_index", "wind_speed_10m", "wind_direction_10m",
                         "relative_humidity_2m", "dew_point_2m", "pressure_msl", "visibility", "wind_gusts_10m"]
        var columns: [ForecastModel: [String: [Double?]]] = [:]
        for m in models { columns[m] = Dictionary(uniqueKeysWithValues: variables.map { ($0, col($0, m)) }) }

        var result: [HourlyForecast] = []
        result.reserveCapacity(times.count)

        for (i, time) in times.enumerated() {
            let lead = max(0, time.timeIntervalSince(now) / 3600)
            let nws = nwsByHour[hourKey(time)]
            let nwsPrecip = nwsByEndHour[hourKey(time)]

            func w(_ source: Source, _ variable: String) -> Double {
                weight(source, variable: variable, leadHours: lead)
                    * learned.multiplier(variable: variable, VerificationSource(source), leadHours: lead)
            }
            func samples(_ variable: String, nwsValue: Double? = nil) -> [(value: Double?, weight: Double)] {
                var s = dedupedFamily(models.map { m in
                    (model: m, value: modelValue(columns[m]?[variable] ?? [], i, m, variable), weight: w(.model(m), variable))
                })
                if let nwsValue { s.append((nwsValue, w(.nws, variable))) }
                return s
            }

            let tempSamples = samples("temperature_2m", nwsValue: nws?.temperatureC)
            guard let temp = weightedMean(tempSamples) else { continue }
            let temps = tempSamples.compactMap(\.value)
            let spread = temps.count > 1 ? (temps.max()! - temps.min()!) : nil

            var pop = weightedMean(samples("precipitation_probability", nwsValue: nwsPrecip?.probabilityOfPrecipitation))
            var precip = weightedMean(samples("precipitation"))
            // Short range: lean on the 15-minute nowcast for the hour ending at `time`.
            // `time` ends the hour; the hour under way (start before now) counts as lead 0.
            let share = time > now ? nowcastShare(leadHours: max(0, time.timeIntervalSince(now) / 3600 - 1)) : 0
            if share > 0 {
                let quarter = minutely.filter { $0.time > time.addingTimeInterval(-3600) && $0.time <= time }
                if quarter.count >= 3 {
                    let sum = quarter.map(\.precipitation).reduce(0, +)
                    precip = (precip ?? sum) * (1 - share) + sum * share
                    let wetQuarters = Double(quarter.filter { $0.precipitation >= Nowcast.threshold }.count) / Double(quarter.count)
                    let nowcastPop = sum >= 0.2 ? 70 + 25 * wetQuarters : (sum > 0 ? 35 : 5)
                    pop = (pop ?? nowcastPop) * (1 - share) + nowcastPop * share
                }
            }

            // Categorical: HRRR in its sweet spot, else best_match, else first model with data.
            let codeOrder: [ForecastModel] = lead <= 18 ? [.hrrr, .bestMatch] + models : [.bestMatch] + models
            let rawCode = codeOrder.lazy.compactMap { at(columns[$0]?["weather_code"] ?? [], i) }.first.map(Int.init) ?? 3
            let isDay = (models.lazy.compactMap { at(columns[$0]?["is_day"] ?? [], i) }.first ?? 1) >= 1
            let code = reconcile(code: rawCode, precipitationProbability: pop, precipitation: precip,
                                 temperature: temp)

            result.append(HourlyForecast(
                time: time, temperature: temp,
                apparentTemperature: weightedMean(samples("apparent_temperature")),
                precipitationProbability: pop.map { min(100, max(0, $0)) },
                precipitation: precip,
                weatherCode: code, isDay: isDay,
                uvIndex: weightedMean(samples("uv_index")),
                windSpeed: weightedMean(samples("wind_speed_10m", nwsValue: nws?.windSpeedKmh)),
                windDirection: models.lazy.compactMap { at(columns[$0]?["wind_direction_10m"] ?? [], i) }.first,
                humidity: weightedMean(samples("relative_humidity_2m", nwsValue: nws?.relativeHumidity)),
                temperatureSpread: spread,
                dewPoint: weightedMean(samples("dew_point_2m")),
                pressure: weightedMean(samples("pressure_msl")),
                visibility: weightedMean(samples("visibility")),
                windGust: weightedMean(samples("wind_gusts_10m"))))
        }
        return result
    }

    /// Makes the categorical icon agree with the blended numbers.
    /// * precip icon but consensus says it's unlikely and dry → cloudy
    /// * dry icon but consensus says likely and wet → rain / snow
    /// * snow icon but the temperature is above ~37 °F → the matching rain icon
    public static func reconcile(code: Int, precipitationProbability pop: Double?, precipitation: Double?,
                                 temperature: Double) -> Int {
        let condition = WeatherCondition(wmoCode: code)
        let p = pop ?? 0, amount = precipitation ?? 0
        if condition.isPrecipitation, p < 25, amount < 0.05 { return 3 }
        if !condition.isPrecipitation, condition.category != .fog, p >= 60, amount >= 0.2 {
            if temperature <= 0 { return amount >= 1 ? 73 : 71 }
            return amount >= 4 ? 65 : (amount >= 1 ? 63 : 61)
        }
        return rainIfWarm(code, temperature: temperature)
    }

    /// Above this (°C, ~37 °F) snow is shown as rain: it can't plausibly be snowing at the surface.
    public static let snowToRainAbove = 2.8
    /// Below this blended daily rain chance (%) the daily icon never shows precipitation.
    public static let dailyPrecipitationIconMinPoP = 30.0

    /// Maps snow codes to the equivalent rain code when it's too warm for snow.
    public static func rainIfWarm(_ code: Int, temperature: Double) -> Int {
        guard temperature > snowToRainAbove else { return code }
        switch code {
        case 71, 77: return 61
        case 73: return 63
        case 75: return 65
        case 85: return 80
        case 86: return 81
        default: return code
        }
    }

    /// Final daily icon: the candidate code (from NWS wording, the blended hours or a model), reconciled with
    /// the blended numbers; precipitation needs at least `dailyPrecipitationIconMinPoP` blended rain chance,
    /// otherwise `dryFallback` (the sky part of the NWS wording, else Partly Cloudy) is shown.
    public static func dailyIcon(code: Int, dryFallback: Int?, precipitationProbability pop: Double?,
                                 precipitation: Double?, temperature: Double) -> Int {
        var c = reconcile(code: code, precipitationProbability: pop, precipitation: precipitation, temperature: temperature)
        if WeatherCondition(wmoCode: c).isPrecipitation, (pop ?? 0) < dailyPrecipitationIconMinPoP {
            c = dryFallback ?? 2
        }
        return rainIfWarm(c, temperature: temperature)
    }

    /// Representative code for a day from its blended daytime hours (7 AM–7 PM local): the most common
    /// precipitation code when at least 3 daytime hours are wet, else the most common dry code.
    public static func dominantCode(_ hours: [HourlyForecast], timeZone: TimeZone) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let daytime = hours.filter { (7...19).contains(cal.component(.hour, from: $0.time)) }
        guard !daytime.isEmpty else { return nil }
        func mode(_ codes: [Int]) -> Int? {
            let counts = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key
        }
        let wet = daytime.map(\.weatherCode).filter { WeatherCondition(wmoCode: $0).isPrecipitation }
        if wet.count >= 3 { return mode(wet) }
        return mode(daytime.map(\.weatherCode).filter { !WeatherCondition(wmoCode: $0).isPrecipitation })
    }

    // MARK: Daily

    /// - Parameter hourly: the blended hourly forecast; for US days without an NWS daytime period it
    ///   provides the daily icon (`dominantCode`).
    public static func blendDaily(openMeteo om: OpenMeteoResponse, nwsPeriods: [NWSPeriod],
                                  timeZone: TimeZone, weights learned: BlendWeights = .neutral,
                                  hourly: [HourlyForecast] = []) -> [DailyForecast] {
        let days = om.dailyTimes
        guard !days.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let models = om.modelsWithData

        // NWS: daytime period starting on day D → high(D); night period *ending* on D → low(D).
        // A night's low happens near its end (early morning), so "Tonight" (6 PM D-1 → 6 AM D) and the
        // "Overnight" period NWS issues after midnight (≈ 2–6 AM D) both belong to D.
        // Evening periods starting on D ("Tonight") are kept separately for D's rain chance when D has no
        // daytime period left (forecast issued in the evening).
        var nwsHigh: [Date: NWSPeriod] = [:], nwsNight: [Date: NWSPeriod] = [:], nwsEvening: [Date: NWSPeriod] = [:]
        for p in nwsPeriods {
            if p.isDaytime {
                let d = calendar.startOfDay(for: p.startTime)
                nwsHigh[d] = nwsHigh[d] ?? p
            } else {
                let d = calendar.startOfDay(for: p.endTime.addingTimeInterval(-1))
                nwsNight[d] = nwsNight[d] ?? p
                if calendar.component(.hour, from: p.startTime) >= 12 {
                    let start = calendar.startOfDay(for: p.startTime)
                    nwsEvening[start] = nwsEvening[start] ?? p
                }
            }
        }
        let isUS = !nwsPeriods.isEmpty

        func col(_ v: String, _ m: ForecastModel) -> [Double?] { om.dailyColumn(v, model: m) ?? [] }
        func at(_ c: [Double?], _ i: Int) -> Double? { i < c.count ? c[i] : nil }
        func modelValue(_ v: String, _ m: ForecastModel, _ i: Int) -> Double? { ignores(m, v) ? nil : at(col(v, m), i) }
        // Model rain chance for D from the hourly data for 6 AM → midnight: Open-Meteo's daily maximum
        // also covers midnight → 6 AM, i.e. the tail of the *previous* evening's rain (the same leak as
        // NWS night periods). Falls back to the daily maximum where hourly data doesn't cover the day.
        let hourTimes = om.hourlyTimes
        func daytimePoP(_ m: ForecastModel, _ day: Date) -> Double? {
            guard !ignores(m, "precipitation_probability"),
                  let column = om.hourlyColumn("precipitation_probability", model: m) else { return nil }
            let start = day.addingTimeInterval(6 * 3600)
            guard let end = calendar.date(byAdding: .day, value: 1, to: day),
                  let first = hourTimes.firstIndex(where: { $0 > start }), hourTimes.last.map({ $0 >= end }) == true
            else { return nil }
            var best: Double?
            for k in first..<min(hourTimes.count, column.count) where hourTimes[k] <= end {
                if let v = column[k] { best = max(best ?? v, v) }
            }
            return best
        }
        func baseDailyWeight(_ m: ForecastModel, _ dayIndex: Int) -> Double {
            if m == .hrrr { return dayIndex == 0 ? 3.0 : (dayIndex == 1 ? 1.0 : 0) } // later days are truncated
            return weight(.model(m), leadHours: Double(dayIndex) * 24 + 12)
        }
        // Day 0 is scored like the 6–24 h bucket, day 1 like day 2, later days like day 3+.
        func learnedLead(_ dayIndex: Int) -> Double { dayIndex == 0 ? 12 : Double(dayIndex) * 24 + 12 }
        func dailyWeight(_ m: ForecastModel, _ dayIndex: Int, _ kind: BlendWeights.Kind = .temperature) -> Double {
            baseDailyWeight(m, dayIndex) * learned.multiplier(kind, VerificationSource(m), leadHours: learnedLead(dayIndex))
        }
        func firstValue(_ v: String, _ i: Int) -> Double? {
            ([.bestMatch] + models).lazy.compactMap { at(col(v, $0), i) }.first
        }

        var result: [DailyForecast] = []
        for (i, rawDay) in days.enumerated() {
            let day = calendar.startOfDay(for: rawDay)
            let highP = nwsHigh[day]
            let lowP = nwsNight[day]
            let nwsW = weight(.nws, leadHours: Double(i) * 24) * learned.multiplier(.temperature, .nws, leadHours: learnedLead(i))
            let nwsRainW = weight(.nws, leadHours: Double(i) * 24) * learned.multiplier(.rain, .nws, leadHours: learnedLead(i))

            func modelSamples(_ v: String, _ kind: BlendWeights.Kind = .temperature) -> [(value: Double?, weight: Double)] {
                dedupedFamily(models.map { (model: $0, value: modelValue(v, $0, i), weight: dailyWeight($0, i, kind)) })
            }
            var highs = modelSamples("temperature_2m_max")
            if let h = highP?.temperatureC { highs.append((h, nwsW)) }
            var lows = modelSamples("temperature_2m_min")
            if let l = lowP?.temperatureC { lows.append((l, nwsW)) }
            var pops = dedupedFamily(models.map { m in
                (model: m, value: daytimePoP(m, day) ?? modelValue("precipitation_probability_max", m, i),
                 weight: dailyWeight(m, i, .rain))
            })
            // NWS rain chance for D: the daytime period's. The night that *ended* on D (mostly the evening
            // before) must not leak into D. With no daytime period left, use tonight's (starting on D).
            let nwsPop = highP?.probabilityOfPrecipitation ?? (highP == nil ? nwsEvening[day]?.probabilityOfPrecipitation : nil)
            if let nwsPop { pops.append((nwsPop, nwsRainW)) }
            // HRRR's daily sum covers only part of the day (its run ends at ~48 h), so it's left out.
            let sums = dedupedFamily(models.filter { $0 != .hrrr }
                .map { (model: $0, value: at(col("precipitation_sum", $0), i), weight: dailyWeight($0, i, .rain)) })

            guard var high = weightedMean(highs), var low = weightedMean(lows) else { continue }
            if low > high { swap(&low, &high) }
            let highValues = highs.compactMap(\.value)
            let pop = weightedMean(pops)
            let sum = weightedMean(sums)
            // Icon: US days use the NWS daytime wording, else the blended daytime hours; elsewhere (and as a
            // last resort) the model's worst-hour code. Then precipitation needs ≥ 30 % and snow needs cold.
            let rawCode = Int(firstValue("weather_code", i) ?? 3)
            var candidate = rawCode, dryFallback: Int?
            let nwsText = highP.flatMap { WeatherCondition.nwsCodes($0.shortForecast) }
            if let nwsText, let c = nwsText.precipitation ?? nwsText.sky {
                candidate = c
                dryFallback = nwsText.sky
            } else if isUS, highP == nil,
                      let c = dominantCode(DailyForecast(date: day, weatherCode: rawCode, high: 0, low: 0)
                                            .hours(from: hourly, timeZone: timeZone), timeZone: timeZone) {
                candidate = c
            }
            let code = dailyIcon(code: candidate, dryFallback: dryFallback, precipitationProbability: pop,
                                 precipitation: sum, temperature: (high + low) / 2)

            // One row per distinct NOAA-family forecast (identical columns are the same model).
            var readings: [SourceReading] = []
            var noaaRows: Set<Int> = []
            for m in models {
                let w = dailyWeight(m, i)
                let h = at(col("temperature_2m_max", m), i), l = at(col("temperature_2m_min", m), i)
                guard w > 0, h != nil || l != nil else { continue }
                if noaaFamily.contains(m),
                   let j = noaaRows.sorted().first(where: { readings[$0].high == h && readings[$0].low == l }) {
                    // The member with the largest weight is named first (it's the weight the blend uses).
                    readings[j].name = w > readings[j].weight ? "\(m.displayName) = \(readings[j].name)"
                                                              : "\(readings[j].name) = \(m.displayName)"
                    readings[j].weight = max(readings[j].weight, w)
                    continue
                }
                if noaaFamily.contains(m) { noaaRows.insert(readings.count) }
                readings.append(SourceReading(name: m.displayName, high: h, low: l, weight: w))
            }
            if highP != nil || lowP != nil {
                readings.append(SourceReading(name: "National Weather Service", high: highP?.temperatureC,
                                              low: lowP?.temperatureC, weight: nwsW))
            }

            var forecast = DailyForecast(
                date: day, weatherCode: code, high: high, low: low,
                precipitationProbability: pop.map { min(100, max(0, $0)) },
                precipitationSum: sum,
                sunrise: firstValue("sunrise", i).map { Date(timeIntervalSince1970: $0) },
                sunset: firstValue("sunset", i).map { Date(timeIntervalSince1970: $0) },
                uvIndexMax: firstValue("uv_index_max", i),
                windSpeedMax: weightedMean(models.map { (value: at(col("wind_speed_10m_max", $0), i), weight: dailyWeight($0, i, .wind)) }),
                windGustMax: weightedMean(models.map { (value: at(col("wind_gusts_10m_max", $0), i), weight: dailyWeight($0, i, .wind)) }),
                windDirectionDominant: firstValue("wind_direction_10m_dominant", i),
                summary: (highP ?? lowP).map { $0.detailedForecast.isEmpty ? $0.shortForecast : $0.detailedForecast },
                highSpread: highValues.count > 1 ? highValues.max()! - highValues.min()! : nil)
            forecast.sources = readings.sorted { $0.weight > $1.weight }
            result.append(forecast)
        }
        return result
    }

    // MARK: Duplicate NOAA columns

    /// Open-Meteo's `best_match` and `gfs_seamless` are HRRR+GFS in the US, so for an hour they often return the
    /// very same number as `gfs_hrrr`. Count one NOAA value once (with the largest of their weights).
    public static let noaaFamily: Set<ForecastModel> = [.hrrr, .bestMatch, .gfs]

    public static func dedupedFamily(_ s: [(model: ForecastModel, value: Double?, weight: Double)]) -> [(value: Double?, weight: Double)] {
        var out: [(value: Double?, weight: Double)] = []
        var familyIndex: [Double: Int] = [:]
        for x in s {
            if noaaFamily.contains(x.model), let v = x.value {
                if let j = familyIndex[v] { out[j].weight = max(out[j].weight, x.weight); continue }
                familyIndex[v] = out.count
            }
            out.append((x.value, x.weight))
        }
        return out
    }

    /// Open-Meteo's `precipitation_probability_gfs_hrrr` (hourly and daily) is the GFS-family probability
    /// (identical in every hour), not an HRRR product: never use it as an HRRR signal.
    static func ignores(_ m: ForecastModel, _ variable: String) -> Bool {
        m == .hrrr && variable.hasPrefix("precipitation_probability")
    }

    static func hourKey(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 3600) }

    /// The blended temperature at `date`, linearly interpolated between the surrounding blended hours,
    /// with the matching apparent temperature. Used for the headline "now" temperature so it benefits from
    /// the blend and NWS instead of being one model's (Open-Meteo best_match) current value.
    public static func temperature(at date: Date, hourly: [HourlyForecast]) -> (temperature: Double, apparent: Double?)? {
        guard let next = hourly.firstIndex(where: { $0.time >= date }) else { return nil }
        let b = hourly[next]
        if b.time == date || next == 0 {
            guard abs(b.time.timeIntervalSince(date)) <= 3600 else { return nil }
            return (b.temperature, b.apparentTemperature)
        }
        let a = hourly[next - 1]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0, span <= 2 * 3600 else { return nil }
        let f = date.timeIntervalSince(a.time) / span
        let apparent = a.apparentTemperature.flatMap { x in b.apparentTemperature.map { x + (($0 - x) * f) } }
        return (a.temperature + (b.temperature - a.temperature) * f, apparent)
    }
}

public enum Nowcast {
    /// mm per 15 minutes considered "precipitating".
    public static let threshold = 0.1

    public static func summary(_ minutely: [MinutelyPrecipitation], now: Date, temperature: Double) -> String? {
        let upcoming = minutely.filter { $0.time >= now.addingTimeInterval(-15 * 60) }
        guard let first = upcoming.first else { return nil }
        let kind = temperature <= 0 ? "Snow" : "Rain"
        func minutes(_ m: MinutelyPrecipitation) -> Int {
            max(15, Int((m.time.timeIntervalSince(now) / 60 / 5).rounded()) * 5)
        }
        if first.precipitation >= threshold {
            if let stop = upcoming.first(where: { $0.precipitation < threshold }) {
                return "\(kind) stopping in about \(minutes(stop)) min"
            }
            return "\(kind) continuing for the next 2 hours"
        }
        if let start = upcoming.first(where: { $0.precipitation >= threshold }) {
            return "\(kind) starting in about \(minutes(start)) min"
        }
        return nil
    }
}
