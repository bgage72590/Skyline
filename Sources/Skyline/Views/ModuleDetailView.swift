import Charts
import SwiftUI
import SkylineCore

/// Modules that open a detail panel when tapped (as in Apple Weather).
enum DetailModule: String, CaseIterable, Identifiable {
    case conditions, uv, wind, precipitation, feelsLike, humidity, visibility, pressure, confidence
    var id: String { rawValue }

    var title: String {
        switch self {
        case .conditions: "Conditions"
        case .uv: "UV Index"
        case .wind: "Wind"
        case .precipitation: "Precipitation"
        case .feelsLike: "Feels Like"
        case .humidity: "Humidity"
        case .visibility: "Visibility"
        case .pressure: "Pressure"
        case .confidence: "Forecast Confidence"
        }
    }

    var symbol: String {
        switch self {
        case .conditions: "thermometer.medium"
        case .uv: "sun.max.fill"
        case .wind: "wind"
        case .precipitation: "drop.fill"
        case .feelsLike: "thermometer.medium"
        case .humidity: "humidity.fill"
        case .visibility: "eye.fill"
        case .pressure: "gauge.with.dots.needle.33percent"
        case .confidence: "checkmark.seal.fill"
        }
    }
}

struct ModuleSelection: Identifiable, Equatable {
    var module: DetailModule
    var day: Date?
    var id: String { module.rawValue }
}

private struct ChartPoint: Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

/// In-window detail panel over the forecast (Apple Weather's module "expand").
struct ModuleDetailView: View {
    let report: WeatherReport
    @Environment(WeatherStore.self) private var store
    @State private var module: DetailModule
    @State private var day: Date

    init(report: WeatherReport, selection: ModuleSelection) {
        self.report = report
        _module = State(initialValue: selection.module)
        _day = State(initialValue: selection.day ?? report.daily.first?.date ?? Date())
    }

    private var units: UnitPreference { store.units }
    private var tz: TimeZone { report.timeZone }
    private var selectedDay: DailyForecast? { report.daily.first { $0.date == day } ?? report.daily.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Menu {
                    ForEach(DetailModule.allCases) { m in
                        Button { module = m } label: { Label(m.title, systemImage: m.symbol) }
                    }
                } label: {
                    Label(module.title, systemImage: module.symbol).font(.title3.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                CircleButton(systemImage: "xmark", help: "Close (Esc)") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            dayStrip
            if let d = selectedDay {
                headline(d)
                if module == .confidence {
                    confidenceTable(d)
                } else {
                    chart(d)
                }
                Text(summary(d))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .frame(maxWidth: 760)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
    }

    private func close() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { store.activeModule = nil }
    }

    // MARK: Pieces

    private var dayStrip: some View {
        HStack(spacing: 0) {
            ForEach(report.daily) { d in
                let selected = d.date == day
                Button {
                    day = d.date
                } label: {
                    VStack(spacing: 4) {
                        Text(String(Fmt.weekday(d.date, tz).prefix(1))).font(.caption2.weight(.semibold)).opacity(0.7)
                        Text(Fmt.string(d.date, template: "d", timeZone: tz))
                            .font(.callout.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(selected ? Color.white : Color.clear, in: Circle())
                            .foregroundStyle(selected ? Color.black : Color.white)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func headline(_ d: DailyForecast) -> some View {
        let isToday = d.date == report.daily.first?.date
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch module {
            case .conditions, .feelsLike:
                Text(units.temperatureString(isToday ? (module == .conditions ? report.current.temperature : report.current.apparentTemperature) : d.high))
                    .font(.system(size: 40, weight: .medium))
                WeatherSymbol(condition: d.condition, isDay: true, size: 26)
                Text("H:\(units.temperatureString(d.high))  L:\(units.temperatureString(d.low))").font(.title3).opacity(0.85)
            case .uv:
                Text("\(Int((d.uvIndexMax ?? 0).rounded()))").font(.system(size: 40, weight: .medium))
                Text(UVScale.category(d.uvIndexMax)).font(.title3).opacity(0.85)
            case .wind:
                Text(units.speedString(d.windSpeedMax)).font(.system(size: 40, weight: .medium))
                Text("Gusts \(units.speedString(d.windGustMax)) · \(Compass.abbreviation(d.windDirectionDominant))").font(.title3).opacity(0.85)
            case .precipitation:
                Text(units.precipitationString(d.precipitationSum ?? 0)).font(.system(size: 40, weight: .medium))
                Text("\(Int((d.precipitationProbability ?? 0).rounded()))% chance").font(.title3).opacity(0.85)
            case .humidity:
                let values = d.hours(from: report.hourly, timeZone: tz).compactMap(\.humidity)
                Text("\(Int((values.reduce(0, +) / Double(max(values.count, 1))).rounded()))%").font(.system(size: 40, weight: .medium))
                Text("Average").font(.title3).opacity(0.85)
            case .visibility:
                Text(units.visibilityString(d.hours(from: report.hourly, timeZone: tz).compactMap(\.visibility).min()))
                    .font(.system(size: 40, weight: .medium))
                Text("Lowest").font(.title3).opacity(0.85)
            case .pressure:
                Text(units.pressureString(d.hours(from: report.hourly, timeZone: tz).compactMap(\.pressure).first ?? report.current.pressure))
                    .font(.system(size: 40, weight: .medium))
            case .confidence:
                Text(confidenceLevel(d.highSpread)).font(.system(size: 40, weight: .medium))
                if let s = d.highSpread {
                    Text("Sources agree within ±\(Int((units.temperatureDelta(s) / 2).rounded()))°").font(.title3).opacity(0.85)
                }
            }
        }
    }

    private func points(_ d: DailyForecast) -> [ChartPoint] {
        d.hours(from: report.hourly, timeZone: tz).compactMap { h in
            let v: Double?
            switch module {
            case .conditions: v = units.temperature(h.temperature)
            case .feelsLike: v = h.apparentTemperature.map(units.temperature)
            case .uv: v = h.uvIndex
            case .wind: v = h.windSpeed.map(units.speed)
            case .precipitation: v = h.precipitationProbability
            case .humidity: v = h.humidity
            case .visibility: v = h.visibility.map(units.distance)
            case .pressure: v = h.pressure.map { units.isImperialDisplay ? $0 * 0.0295299830714 : $0 }
            case .confidence: v = nil
            }
            return v.map { ChartPoint(time: h.time, value: $0) }
        }
    }

    @ViewBuilder
    private func chart(_ d: DailyForecast) -> some View {
        let pts = points(d)
        let lo = pts.map(\.value).min() ?? 0
        let hi = pts.map(\.value).max() ?? 1
        let pad = max((hi - lo) * 0.15, module == .uv ? 1 : 0.5)
        let domain = module == .precipitation || module == .humidity ? 0...100 : (lo - pad)...(hi + pad)
        let isToday = d.date == report.daily.first?.date
        if pts.isEmpty {
            Text("No hourly data for this day.").frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Chart {
                ForEach(pts) { p in
                    if module == .precipitation {
                        BarMark(x: .value("Hour", p.time, unit: .hour), y: .value(module.title, p.value))
                            .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1.0))
                    } else {
                        AreaMark(x: .value("Hour", p.time), yStart: .value("Base", domain.lowerBound),
                                 yEnd: .value(module.title, p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [lineColors.last!.opacity(0.35), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Hour", p.time), y: .value(module.title, p.value))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                            .foregroundStyle(LinearGradient(colors: lineColors, startPoint: .bottom, endPoint: .top))
                    }
                }
                if isToday {
                    RuleMark(x: .value("Now", report.current.time))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(.white.opacity(0.75))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.75))
                }
            }
            .environment(\.timeZone, tz)
            .frame(height: 260)
        }
    }

    private var lineColors: [Color] {
        switch module {
        case .conditions, .feelsLike: [Color(red: 0.3, green: 0.8, blue: 0.9), .yellow, .orange]
        case .uv: [.green, .yellow, .orange, .red]
        case .wind: [Color(red: 0.6, green: 0.9, blue: 1.0), .white]
        case .humidity: [Color(red: 0.4, green: 0.7, blue: 1.0), Color(red: 0.6, green: 0.85, blue: 1.0)]
        default: [.white.opacity(0.7), .white]
        }
    }

    private func confidenceTable(_ d: DailyForecast) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Source").frame(maxWidth: .infinity, alignment: .leading)
                Text("High").frame(width: 60, alignment: .trailing)
                Text("Low").frame(width: 60, alignment: .trailing)
                Text("Weight").frame(width: 70, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).opacity(0.7).padding(.vertical, 6)
            ForEach(d.sources) { s in
                Divider().overlay(Color.white.opacity(0.2))
                HStack {
                    Text(s.name).frame(maxWidth: .infinity, alignment: .leading)
                    Text(units.temperatureString(s.high)).frame(width: 60, alignment: .trailing)
                    Text(units.temperatureString(s.low)).frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.1f×", s.weight)).frame(width: 70, alignment: .trailing).opacity(0.7)
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 7)
            }
            Divider().overlay(Color.white.opacity(0.2))
            HStack {
                Text("Skyline blend").font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text(units.temperatureString(d.high)).frame(width: 60, alignment: .trailing)
                Text(units.temperatureString(d.low)).frame(width: 60, alignment: .trailing)
                Text("").frame(width: 70)
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func confidenceLevel(_ spread: Double?) -> String {
        guard let spread else { return "—" }
        return spread <= 2 ? "High" : (spread <= 4 ? "Medium" : "Low")
    }

    private func summary(_ d: DailyForecast) -> String {
        switch module {
        case .conditions:
            return d.summary ?? "\(d.condition.description). High \(units.temperatureString(d.high)), low \(units.temperatureString(d.low))."
        case .uv:
            return "UV index peaks at \(Int((d.uvIndexMax ?? 0).rounded())) (\(UVScale.category(d.uvIndexMax))). Use sun protection when it is 3 or higher."
        case .wind:
            return "Winds up to \(units.speedString(d.windSpeedMax)) from the \(Compass.abbreviation(d.windDirectionDominant)), with gusts to \(units.speedString(d.windGustMax))."
        case .precipitation:
            return "\(Int((d.precipitationProbability ?? 0).rounded()))% chance of precipitation, \(units.precipitationString(d.precipitationSum ?? 0)) expected. The chart shows the hourly chance."
        case .feelsLike:
            return "Feels-like temperature combines air temperature, humidity and wind."
        case .humidity:
            return "Relative humidity through the day. A dew point above 65°F (18°C) feels muggy."
        case .visibility:
            return "Visibility through the day. Below 1 mi (1.6 km) usually means fog or heavy precipitation."
        case .pressure:
            return "Falling pressure often signals unsettled weather; rising pressure, clearing."
        case .confidence:
            return "Skyline weights each source by its typical skill: HRRR dominates the first 18 hours in the US, the NWS official forecast and ECMWF carry the most weight after that. When sources disagree, confidence drops."
        }
    }
}
