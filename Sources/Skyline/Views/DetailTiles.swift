import SwiftUI
import SkylineCore

/// Square condition tiles (Apple Weather's grid). Tapping a tile opens its detail panel.
struct DetailTilesGrid: View {
    let report: WeatherReport
    let units: DisplayUnits
    var onOpen: (DetailModule) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 165), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            tappable(.uv) { UVTile(report: report) }
            SunTile(report: report)
            tappable(.wind) { WindTile(report: report, units: units) }
            tappable(.precipitation) { PrecipitationTile(report: report, units: units) }
            tappable(.feelsLike) { FeelsLikeTile(report: report, units: units) }
            tappable(.humidity) { HumidityTile(report: report, units: units) }
            tappable(.visibility) { VisibilityTile(report: report, units: units) }
            tappable(.pressure) { PressureTile(report: report, units: units) }
            if let aq = report.airQuality { AirQualityTile(airQuality: aq, report: report) }
            MoonTile(date: report.current.time)
            tappable(.confidence) { ConfidenceTile(report: report, units: units) }
            tappable(.accuracy) { AccuracyTile(location: report.location, units: units) }
        }
    }

    private func tappable<V: View>(_ module: DetailModule, @ViewBuilder _ tile: () -> V) -> some View {
        Button { onOpen(module) } label: { tile() }
            .buttonStyle(.plain)
    }
}

struct UVTile: View {
    let report: WeatherReport
    var body: some View {
        let uv = report.current.uvIndex ?? 0
        let series = report.upcomingHours(count: 14).map { ($0.time, $0.uvIndex ?? 0) }
        let peak = Briefing.peak(series, from: report.current.time, hours: 14)
        Tile(title: "UV Index", systemImage: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(uv.rounded()))").font(.system(size: 32, weight: .medium))
                    Text(UVScale.category(uv)).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                // Hourly UV for the next ~14 h, coloured on the WHO scale.
                HourlyMiniBars(values: series, maxValue: 11, timeZone: report.timeZone, highlight: peak?.time,
                               color: { UVColors.color($0) })
                    .frame(height: 34)
                Spacer(minLength: 4)
                if let peak, peak.value >= 1 {
                    Text(peak.value >= 3 ? "Peak \(Int(peak.value.rounded())) at \(Fmt.hour(peak.time, report.timeZone)). Use sun protection."
                                        : "Low; peak \(Int(peak.value.rounded())) at \(Fmt.hour(peak.time, report.timeZone)).")
                        .font(.caption).foregroundStyle(Glass.secondaryText).lineLimit(2)
                } else {
                    Text("No UV until morning.").font(.caption).foregroundStyle(Glass.secondaryText)
                }
            }
        }
    }
}

enum UVColors {
    static func color(_ uv: Double) -> Color {
        switch uv {
        case ..<3: Color(red: 0.36, green: 0.80, blue: 0.40)
        case ..<6: Color(red: 0.98, green: 0.84, blue: 0.20)
        case ..<8: Color(red: 1.0, green: 0.58, blue: 0.16)
        case ..<11: Color(red: 0.95, green: 0.25, blue: 0.25)
        default: Color(red: 0.70, green: 0.35, blue: 0.95)
        }
    }
}

enum AQIColors {
    static func color(_ aqi: Double) -> Color {
        switch aqi {
        case ..<51: Color(red: 0.36, green: 0.80, blue: 0.40)
        case ..<101: Color(red: 0.98, green: 0.84, blue: 0.20)
        case ..<151: Color(red: 1.0, green: 0.58, blue: 0.16)
        case ..<201: Color(red: 0.95, green: 0.25, blue: 0.25)
        case ..<301: Color(red: 0.62, green: 0.30, blue: 0.85)
        default: Color(red: 0.55, green: 0.10, blue: 0.20)
        }
    }
}

/// A compact strip of hourly bars (tile-sized), each coloured by its value, with the peak hour
/// outlined and a couple of hour labels underneath.
struct HourlyMiniBars: View {
    let values: [(Date, Double)]
    let maxValue: Double
    let timeZone: TimeZone
    var highlight: Date? = nil
    let color: (Double) -> Color

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let n = max(values.count, 1)
                let gap: CGFloat = 2
                let w = max((geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n), 1)
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(values.indices, id: \.self) { i in
                        let v = values[i].1
                        let h = max(2, geo.size.height * CGFloat(min(v / maxValue, 1)))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(v).opacity(v <= 0 ? 0.35 : 0.95))
                            .frame(width: w, height: h)
                            .overlay {
                                if values[i].0 == highlight {
                                    RoundedRectangle(cornerRadius: 1.5).strokeBorder(.white, lineWidth: 1)
                                }
                            }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            HStack {
                Text(values.first.map { Fmt.hour($0.0, timeZone) } ?? "")
                Spacer()
                Text(values.last.map { Fmt.hour($0.0, timeZone) } ?? "")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Glass.secondaryText)
        }
        .accessibilityHidden(true)
    }
}

struct SunTile: View {
    let report: WeatherReport
    var body: some View {
        let now = Date()
        let tz = report.timeZone
        let today = report.daily.first
        let tomorrow = report.daily.dropFirst().first
        let next: (title: String, time: Date?, otherTitle: String, other: Date?) = {
            if let rise = today?.sunrise, now < rise { return ("Sunrise", rise, "Sunset", today?.sunset) }
            if let set = today?.sunset, now < set { return ("Sunset", set, "Sunrise", tomorrow?.sunrise) }
            return ("Sunrise", tomorrow?.sunrise, "Sunset", tomorrow?.sunset)
        }()
        Tile(title: next.title, systemImage: next.title == "Sunrise" ? "sunrise.fill" : "sunset.fill") {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.time.map { Fmt.time($0, tz) } ?? "--").font(.system(size: 28, weight: .medium))
                SunCurve(progress: dayProgress(now: now, day: today))
                    .frame(height: 44)
                    .padding(.vertical, 2)
                Spacer(minLength: 0)
                if let other = next.other {
                    Text("\(next.otherTitle): \(Fmt.time(other, tz))").font(.caption).opacity(0.85)
                }
            }
        }
    }

    /// 0…1 between sunrise and sunset; nil at night.
    private func dayProgress(now: Date, day: DailyForecast?) -> Double? {
        guard let r = day?.sunrise, let s = day?.sunset, now > r, now < s else { return nil }
        return now.timeIntervalSince(r) / s.timeIntervalSince(r)
    }
}

/// Apple-style sun path: a sine curve with a horizon line and the sun's current position.
struct SunCurve: View {
    /// 0…1 through the daylight hours; nil at night.
    let progress: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let horizon = h * 0.55, amp = h * 0.42
            ZStack(alignment: .topLeading) {
                Path { p in
                    for i in 0...60 {
                        let pt = Self.point(t: Double(i) / 60, w: w, horizon: horizon, amp: amp)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.9), .white.opacity(0.3)],
                                       startPoint: .leading, endPoint: .trailing), lineWidth: 2)
                Rectangle().fill(.white.opacity(0.4)).frame(width: w, height: 1).offset(y: horizon)
                if let progress {
                    let pt = Self.point(t: 0.25 + progress * 0.5, w: w, horizon: horizon, amp: amp)
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .shadow(color: .white, radius: 4)
                        .offset(x: pt.x - 5, y: pt.y - 5)
                }
            }
        }
    }

    /// t = 0.25 sunrise, 0.5 solar noon, 0.75 sunset.
    static func point(t: Double, w: CGFloat, horizon: CGFloat, amp: CGFloat) -> CGPoint {
        CGPoint(x: w * CGFloat(t), y: horizon - CGFloat(sin((t - 0.25) * 2 * .pi)) * amp)
    }
}

struct WindTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let c = report.current
        Tile(title: "Wind", systemImage: "wind") {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    row("Wind", units.speedString(c.windSpeed))
                    Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5)
                    row("Gusts", units.speedString(c.windGust))
                    Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5)
                    row("Direction", "\(Int((c.windDirection ?? 0).rounded()))° \(Compass.abbreviation(c.windDirection))")
                }
                .font(.caption)
                CompassView(degrees: c.windDirection, centerText: "\(Int(units.speed(c.windSpeed).rounded()))",
                            centerUnit: units.speedUnit)
            }
            .frame(maxHeight: .infinity)
            if let peak = Briefing.peak(report.hourly.compactMap { h in h.windGust.map { (h.time, $0) } },
                                        from: report.current.time, hours: 24), peak.value > 0 {
                // One line, shrinking if needed: "Peak gust 100 km/h at 11 PM" and the shorter
                // 24-hour form ("… at 23") both fit the tile instead of ending in an ellipsis.
                Text("Peak gust \(units.speedString(peak.value)) at \(Fmt.hour(peak.time, report.timeZone))")
                    .font(.caption).foregroundStyle(Glass.secondaryText)
                    .lineLimit(1).minimumScaleFactor(0.6).allowsTightening(true)
                    .layoutPriority(1)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).opacity(0.7)
            Text(value).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct PrecipitationTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let next24 = report.upcomingHours(count: 24).compactMap(\.precipitation).reduce(0, +)
        let chance = report.today?.precipitationProbability
        Tile(title: "Precipitation", systemImage: "drop.fill") {
            TileValue(value: units.precipitationString(next24),
                      label: "Next 24h",
                      detail: report.nowcastSummary(at: Date()).map { $0 + "." }
                        ?? chance.map { "\(Int($0.rounded()))% chance today." }
                        ?? "None expected.")
        }
    }
}

struct FeelsLikeTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let c = report.current
        let delta = c.apparentTemperature - c.temperature
        let detail: String = {
            if abs(delta) < 1.5 { return "Similar to the actual temperature." }
            if delta < 0 { return c.windSpeed > 10 ? "Wind is making it feel colder." : "It feels colder than the actual temperature." }
            return c.humidity > 60 ? "Humidity is making it feel warmer." : "It feels warmer than the actual temperature."
        }()
        Tile(title: "Feels Like", systemImage: "thermometer.medium") {
            TileValue(value: units.temperatureString(c.apparentTemperature, withUnit: true), detail: detail)
        }
    }
}

struct HumidityTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let c = report.current
        Tile(title: "Humidity", systemImage: "humidity.fill") {
            TileValue(value: "\(Int(c.humidity.rounded()))%",
                      detail: c.dewPoint.map { "The dew point is \(units.temperatureString($0)) right now." })
        }
    }
}

struct VisibilityTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let v = report.current.visibility
        let detail: String = {
            guard let v else { return "" }
            switch v {
            case 16_000...: return "Perfectly clear view."
            case 8_000..<16_000: return "Mostly clear view."
            case 2_000..<8_000: return "Haze or precipitation is reducing visibility."
            default: return "Fog or heavy precipitation is limiting visibility."
            }
        }()
        Tile(title: "Visibility", systemImage: "eye.fill") {
            TileValue(value: units.visibilityString(v), detail: detail)
        }
    }
}

struct PressureTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let p = report.current.pressure
        let trend = pressureTrend()
        Tile(title: "Pressure", systemImage: "gauge.with.dots.needle.33percent") {
            PressureGauge(hPa: p, trend: trend,
                          valueText: p.map { units.pressureNumber($0) } ?? "--",
                          unitText: units.pressureUnit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// hPa change over the next 3 hours (positive = rising).
    private func pressureTrend() -> Double? {
        let hours = report.upcomingHours(count: 4).compactMap(\.pressure)
        guard let first = hours.first, let last = hours.last, hours.count > 1 else { return nil }
        return last - first
    }
}

/// Dial like Apple's pressure tile: tick arc 950–1050 hPa, needle at the current value, trend arrow.
struct PressureGauge: View {
    let hPa: Double?
    let trend: Double?
    let valueText: String
    let unitText: String

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - 4
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let start = 135.0, sweep = 270.0
            let fraction = min(max(((hPa ?? 1013) - 950) / 100, 0), 1)
            ZStack {
                ForEach(0..<41, id: \.self) { i in
                    let angle = Angle.degrees(start + sweep * Double(i) / 40)
                    Path { p in
                        p.move(to: point(center, radius, angle))
                        p.addLine(to: point(center, radius - (i % 5 == 0 ? 9 : 5), angle))
                    }
                    .stroke(.white.opacity(0.45), lineWidth: 1.2)
                }
                if hPa != nil {
                    let angle = Angle.degrees(start + sweep * fraction)
                    Path { p in
                        p.move(to: point(center, radius + 2, angle))
                        p.addLine(to: point(center, radius - 12, angle))
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
                VStack(spacing: 0) {
                    if let trend, abs(trend) >= 0.5 {
                        Image(systemName: trend > 0 ? "arrow.up" : "arrow.down").font(.caption.weight(.bold))
                    } else {
                        Image(systemName: "equal").font(.caption.weight(.bold))
                    }
                    Text(valueText).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text(unitText).font(.caption2).opacity(0.8)
                }
                .position(center)
            }
        }
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ a: Angle) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(cos(a.radians)), y: c.y + r * CGFloat(sin(a.radians)))
    }
}

struct AirQualityTile: View {
    let airQuality: AirQuality
    let report: WeatherReport
    var body: some View {
        let now = report.current.time
        let series = airQuality.hourly.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(24).map { ($0.time, $0.value) }
        let peak = Briefing.peak(Array(series), from: now, hours: 24)
        Tile(title: "Air Quality", systemImage: "aqi.medium") {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(airQuality.usAQI)").font(.system(size: 32, weight: .medium))
                    Text(airQuality.category).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 4)
                if series.count > 3 {
                    HourlyMiniBars(values: Array(series), maxValue: max(150, (peak?.value ?? 0) * 1.1),
                                   timeZone: report.timeZone, highlight: peak?.time, color: { AQIColors.color($0) })
                        .frame(height: 34)
                } else {
                    ScaleBar(fraction: Double(airQuality.usAQI) / 300,
                             colors: [.green, .yellow, .orange, .red, .purple, Color(red: 0.5, green: 0, blue: 0.15)])
                }
                Spacer(minLength: 4)
                Group {
                    if let peak, series.count > 3 {
                        Text("Peak \(Int(peak.value.rounded())) (\(AirQuality.category(Int(peak.value.rounded())))) at \(Fmt.hour(peak.time, report.timeZone))")
                    } else if let pm = airQuality.pm25 {
                        Text("US AQI · PM2.5 \(Int(pm.rounded())) µg/m³")
                    }
                }
                .font(.caption).foregroundStyle(Glass.secondaryText).lineLimit(2)
            }
        }
    }
}

struct MoonTile: View {
    let date: Date
    var body: some View {
        let moon = MoonPhase(date: date)
        Tile(title: "Moon", systemImage: "moon.fill") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(moon.name).font(.headline).lineLimit(2)
                    Spacer(minLength: 0)
                    Text("Illumination \(Int((moon.illumination * 100).rounded()))%").font(.caption)
                    Text(moon.daysUntilFull < 0.5 ? "Full moon tonight" : "Full moon in \(Int(moon.daysUntilFull.rounded())) days")
                        .font(.caption).opacity(0.85)
                }
                Spacer(minLength: 0)
                Image(systemName: moon.symbolName)
                    .font(.system(size: 54, weight: .thin))
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}

/// Skyline-only module, styled like Apple's tiles: how closely the sources agree for today.
struct ConfidenceTile: View {
    let report: WeatherReport
    let units: DisplayUnits
    var body: some View {
        let spread = report.today?.highSpread
        let level: String = {
            guard let spread else { return "—" }
            if spread <= 2 { return "High" }
            if spread <= 4 { return "Medium" }
            return "Low"
        }()
        Tile(title: "Confidence", systemImage: "checkmark.seal.fill") {
            TileValue(value: level,
                      label: spread.map { "±\(Int((units.temperatureDelta($0) / 2).rounded()))° between sources" },
                      detail: "\(report.sources.count) sources blended. Tap for the breakdown; see Accuracy for how they verify.")
        }
    }
}
