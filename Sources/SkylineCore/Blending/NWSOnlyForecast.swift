import Foundation

/// Builds a usable forecast from NWS periods alone when Open-Meteo is unavailable (daily limit /
/// pair miss with no cached pair). Does not touch `ForecastBlender`.
public enum NWSOnlyForecast {
    public struct Parts: Sendable {
        public var current: CurrentConditions
        public var hourly: [HourlyForecast]
        public var daily: [DailyForecast]
    }

    /// - Parameters:
    ///   - periods: NWS 12-h day/night forecast periods.
    ///   - hourlyPeriods: NWS hourly forecast periods.
    ///   - coordinate / timeZone: for Astronomy sun times and day boundaries.
    ///   - now: assembly time (current period lookup).
    public static func build(periods: [NWSPeriod], hourlyPeriods: [NWSPeriod],
                             coordinate: Coordinate, timeZone: TimeZone,
                             now: Date = Date()) -> Parts? {
        let hourly = hourlyForecasts(from: hourlyPeriods, now: now)
        guard let current = currentConditions(from: hourlyPeriods, now: now) else { return nil }
        let daily = dailyForecasts(periods: periods, hourly: hourly, coordinate: coordinate,
                                   timeZone: timeZone, now: now)
        guard !daily.isEmpty || !hourly.isEmpty else { return nil }
        return Parts(current: current, hourly: hourly, daily: daily)
    }

    // MARK: Current

    public static func currentConditions(from hourlyPeriods: [NWSPeriod], now: Date) -> CurrentConditions? {
        guard let p = hourlyPeriods.first(where: { $0.startTime <= now && now < $0.endTime })
                ?? hourlyPeriods.first(where: { $0.startTime >= now })
                ?? hourlyPeriods.last,
              let temp = p.temperatureC else { return nil }
        let codes = WeatherCondition.nwsCodes(p.shortForecast)
        let code = codes?.precipitation ?? codes?.sky ?? 3
        let isDay = p.isDaytime
        return CurrentConditions(
            time: max(p.startTime, min(now, p.endTime.addingTimeInterval(-1))),
            temperature: temp,
            apparentTemperature: temp,
            humidity: p.relativeHumidity ?? 0,
            dewPoint: nil,
            weatherCode: code,
            isDay: isDay,
            precipitation: 0,
            cloudCover: nil,
            pressure: nil,
            windSpeed: p.windSpeedKmh ?? 0,
            windDirection: p.windDirection,
            windGust: nil,
            visibility: nil,
            uvIndex: nil)
    }

    // MARK: Hourly

    public static func hourlyForecasts(from periods: [NWSPeriod], now: Date) -> [HourlyForecast] {
        let start = now.addingTimeInterval(-3600)
        return periods.compactMap { p -> HourlyForecast? in
            guard p.startTime > start || (p.startTime <= now && now < p.endTime),
                  let temp = p.temperatureC else { return nil }
            let codes = WeatherCondition.nwsCodes(p.shortForecast)
            let code = codes?.precipitation ?? codes?.sky ?? 3
            return HourlyForecast(
                time: p.startTime,
                temperature: temp,
                apparentTemperature: temp,
                precipitationProbability: p.probabilityOfPrecipitation,
                precipitation: nil,
                weatherCode: code,
                isDay: p.isDaytime,
                uvIndex: nil,
                windSpeed: p.windSpeedKmh,
                windDirection: p.windDirection,
                humidity: p.relativeHumidity)
        }
    }

    // MARK: Daily (day/night pairing, same rules as blendDaily's NWS side)

    public static func dailyForecasts(periods: [NWSPeriod], hourly: [HourlyForecast],
                                      coordinate: Coordinate, timeZone: TimeZone,
                                      now: Date) -> [DailyForecast] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var nwsHigh: [Date: NWSPeriod] = [:], nwsNight: [Date: NWSPeriod] = [:], nwsEvening: [Date: NWSPeriod] = [:]
        for p in periods {
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
        let days = Set(nwsHigh.keys).union(nwsNight.keys).sorted()
        var result: [DailyForecast] = []
        for day in days {
            let highP = nwsHigh[day]
            let lowP = nwsNight[day]
            guard let high = highP?.temperatureC ?? lowP?.temperatureC,
                  let low = lowP?.temperatureC ?? highP?.temperatureC else { continue }
            var hi = high, lo = low
            if lo > hi { swap(&lo, &hi) }
            let pop = highP?.probabilityOfPrecipitation
                ?? (highP == nil ? nwsEvening[day]?.probabilityOfPrecipitation : nil)
            let nwsText = highP.flatMap { WeatherCondition.nwsCodes($0.shortForecast) }
            let code = nwsText?.precipitation ?? nwsText?.sky
                ?? dominantDayCode(day: day, hourly: hourly, timeZone: timeZone) ?? 3
            let sun = Astronomy.sunTimes(on: day, coordinate: coordinate, timeZone: timeZone)
            var forecast = DailyForecast(
                date: day, weatherCode: code, high: hi, low: lo,
                precipitationProbability: pop.map { min(100, max(0, $0)) },
                precipitationSum: nil,
                sunrise: sun.sunrise, sunset: sun.sunset,
                summary: (highP ?? lowP).map { $0.detailedForecast.isEmpty ? $0.shortForecast : $0.detailedForecast })
            forecast.sources = [
                SourceReading(name: "National Weather Service", high: highP?.temperatureC,
                              low: lowP?.temperatureC, weight: 1)
            ]
            result.append(forecast)
        }
        // Cap near Open-Meteo's 10-day window.
        return Array(result.prefix(10))
    }

    private static func dominantDayCode(day: Date, hourly: [HourlyForecast], timeZone: TimeZone) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hours = hourly.filter { cal.isDate($0.time, inSameDayAs: day) && $0.isDay }
        guard !hours.isEmpty else { return hourly.first(where: { cal.isDate($0.time, inSameDayAs: day) })?.weatherCode }
        // Prefer the worst precip code in daytime hours.
        return hours.map(\.weatherCode).max()
    }
}
