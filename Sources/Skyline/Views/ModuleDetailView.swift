import Charts
import SwiftUI
import SkylineCore

/// Modules that open a detail panel when tapped (as in Apple Weather).
enum DetailModule: String, CaseIterable, Identifiable {
    case conditions, uv, wind, precipitation, feelsLike, humidity, visibility, pressure, confidence, accuracy
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
        case .accuracy: "Forecast Accuracy"
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
        case .accuracy: "scope"
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
    /// Model spread in display units (temperature charts only): shaded as value ± spread/2.
    var spread: Double? = nil
    var id: Date { time }
}

/// Module detail. Wide windows show it as an inspector column beside the radar (`inspector: true`);
/// narrow windows show it as a sheet-style panel over the forecast.
struct ModuleDetailView: View {
    let report: WeatherReport
    var inspector = false
    @Environment(WeatherStore.self) private var store
    @State private var module: DetailModule
    @State private var day: Date
    @State private var scrub: Date?

    init(report: WeatherReport, selection: ModuleSelection, inspector: Bool = false) {
        self.report = report
        self.inspector = inspector
        _module = State(initialValue: selection.module)
        _day = State(initialValue: selection.day ?? report.daily.first?.date ?? Date())
    }

    private var units: DisplayUnits { store.units }
    private var tz: TimeZone { report.timeZone }
    private var selectedDay: DailyForecast? { report.daily.first { $0.date == day } ?? report.daily.first }

    var body: some View {
        if inspector {
            ScrollView { panel.padding(.bottom, 8) }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity, alignment: .top)
                .glassPanel(cornerRadius: 16)
        } else {
            // Hugs its content when it fits; scrolls inside the panel when the window is short.
            ViewThatFits(in: .vertical) {
                panel.fixedSize(horizontal: false, vertical: true)
                ScrollView { panel }.scrollIndicators(.automatic)
            }
            .frame(maxWidth: 760)
            .glassPanel()
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
    }

    private var panel: some View {
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
                CircleButton(systemImage: inspector ? "sidebar.leading" : "xmark",
                             help: inspector ? "Close inspector (Esc)" : "Close (Esc)") { close() }
                    .keyboardShortcut(.cancelAction)
            }
            if module == .accuracy {
                AccuracyPanel(location: report.location, units: units)
            } else {
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
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            }
        }
        .padding(inspector ? 16 : 20)
        .foregroundStyle(.white)
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
                    scrub = nil
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
                Text(units.temperatureString(isToday ? (module == .conditions ? report.current.temperature : report.current.apparentTemperature) : d.high, withUnit: true))
                    .font(.system(size: 40, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                WeatherSymbol(condition: d.condition, isDay: true, size: 26)
                Text("H:\(units.temperatureString(d.high, withUnit: true))  L:\(units.temperatureString(d.low, withUnit: true))")
                    .font(.title3).opacity(0.85)
                    .lineLimit(1).minimumScaleFactor(0.7)
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
            case .accuracy:
                EmptyView()
            case .confidence:
                let a = ForecastConfidence.assess(day: d, modelSeries: report.modelSeries, timeZone: tz, now: Date())
                Text(a.levelName).font(.system(size: 40, weight: .medium))
                if let text = ForecastConfidence.detailText(a, delta: { units.temperatureDelta($0) }) {
                    Text(text).font(.title3).opacity(0.85)
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
            case .pressure: v = h.pressure.map { units.pressure($0) }
            case .confidence, .accuracy: v = nil
            }
            let spread = (module == .conditions) ? h.temperatureSpread.map(units.temperatureDelta) : nil
            return v.map { ChartPoint(time: h.time, value: $0, spread: spread) }
        }
    }

    /// Y range from this day's own data (with a minimum span, so a steady day reads as gentle, not
    /// flat on a fixed 0–100 scale and not noise blown up to full height).
    private func domain(_ pts: [ChartPoint]) -> ClosedRange<Double> {
        if module == .precipitation || module == .humidity { return 0...100 }
        let lows = pts.map { $0.value - ($0.spread ?? 0) / 2 }
        let highs = pts.map { $0.value + ($0.spread ?? 0) / 2 }
        var lo = lows.min() ?? 0, hi = highs.max() ?? 1
        let minSpan: Double = switch module {
        case .conditions, .feelsLike: 8
        case .uv: 4
        case .pressure: units.pressureStep
        default: 4
        }
        if hi - lo < minSpan { let mid = (hi + lo) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2 }
        let pad = (hi - lo) * 0.18
        if module == .uv || module == .wind || module == .visibility { return max(0, lo - pad)...(hi + pad * 1.6) }
        return (lo - pad)...(hi + pad * 1.6) // extra headroom for the scrubber callout
    }

    private func valueText(_ v: Double) -> String {
        switch module {
        case .conditions, .feelsLike: "\(Int(v.rounded()))°"
        case .uv: "\(Int(v.rounded())) \(UVScale.category(v))"
        case .wind: "\(Int(v.rounded())) \(units.speedUnit)"
        case .precipitation: "\(Int(v.rounded()))% chance"
        case .humidity: "\(Int(v.rounded()))%"
        case .visibility: String(format: "%.1f", v)
        case .pressure: units.pressure == .inHg ? String(format: "%.2f inHg", v) : "\(Int(v.rounded())) hPa"
        case .confidence, .accuracy: ""
        }
    }

    @ViewBuilder
    private func chart(_ d: DailyForecast) -> some View {
        let pts = points(d)
        let domain = domain(pts)
        let now = report.current.time
        let isToday = d.date == report.daily.first?.date
        // Past hours dotted, forecast solid; the forecast series starts at the last past point so they join.
        let past = pts.filter { $0.time <= now }
        let future = pts.filter { $0.time >= (past.last?.time ?? .distantPast) }
        let selected = scrub.flatMap { s in pts.first { $0.time == s } }
        if pts.isEmpty {
            Text("No hourly data for this day.").frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Chart {
                if module == .precipitation {
                    ForEach(pts) { p in
                        BarMark(x: .value("Hour", p.time, unit: .hour), y: .value(module.title, p.value))
                            .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1.0).opacity(p.time < now ? 0.55 : 1))
                    }
                } else {
                    ForEach(pts) { p in
                        if let spread = p.spread, spread > 0 {
                            AreaMark(x: .value("Hour", p.time),
                                     yStart: .value("Low", p.value - spread / 2),
                                     yEnd: .value("High", p.value + spread / 2),
                                     series: .value("Layer", "Model spread"))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(.white.opacity(0.16))
                        }
                    }
                    ForEach(pts) { p in
                        AreaMark(x: .value("Hour", p.time), yStart: .value("Base", domain.lowerBound),
                                 yEnd: .value(module.title, p.value), series: .value("Layer", "Fill"))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [lineColors.last!.opacity(0.28), .clear],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    ForEach(past) { p in
                        LineMark(x: .value("Hour", p.time), y: .value(module.title, p.value), series: .value("Part", "Past"))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.5, 6]))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    ForEach(future) { p in
                        LineMark(x: .value("Hour", p.time), y: .value(module.title, p.value), series: .value("Part", "Forecast"))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                            .foregroundStyle(LinearGradient(colors: lineColors, startPoint: .bottom, endPoint: .top))
                    }
                }
                if isToday && selected == nil {
                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected.time))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            ScrubCallout(title: Fmt.time(selected.time, tz) + (selected.time < now ? " · past" : ""),
                                         value: valueText(selected.value) + (selected.spread.map { $0 >= 1 ? " ±\(Int(($0 / 2).rounded()))°" : "" } ?? ""))
                        }
                    if module != .precipitation {
                        PointMark(x: .value("Selected", selected.time), y: .value(module.title, selected.value))
                            .symbolSize(70)
                            .foregroundStyle(.white)
                    }
                }
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: (pts.first!.time)...(pts.last!.time))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.15))
                    // Fmt honours the 12/24-hour setting (Charts' own format follows only the system).
                    AxisValueLabel { if let d = v.as(Date.self) { Text(Fmt.hour(d, tz)) } }
                        .foregroundStyle(Glass.secondaryText)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.15))
                    AxisValueLabel().foregroundStyle(Glass.secondaryText)
                }
            }
            .chartScrubber(times: pts.map(\.time), selection: $scrub)
            .environment(\.timeZone, tz)
            .frame(height: inspector ? 230 : 260)
            if module == .conditions, pts.contains(where: { ($0.spread ?? 0) > 0 }) {
                Label("Shaded band: spread between forecast models. Wider = less certain.", systemImage: "square.fill")
                    .font(.caption).foregroundStyle(Glass.secondaryText)
            }
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

    /// Build 35 (weighting-check.md fix 1, labels only, no change to the math): each source's weight is
    /// shown per field with its share of that field's blend, "–" where it has no value (e.g. NWS without
    /// a low), and a merged NOAA row of identical values is labelled as the one vote it is.
    private func confidenceTable(_ d: DailyForecast) -> some View {
        let highTotal = d.sources.filter { $0.high != nil }.reduce(0) { $0 + $1.weight }
        let lowTotal = d.sources.filter { $0.low != nil }.reduce(0) { $0 + $1.weight }
        func share(_ w: Double, _ value: Double?, _ total: Double, _ fieldShare: Double?) -> String {
            guard value != nil else { return "–" }          // no value from this source
            guard w > 0 else { return "0× · not counted" }    // a value that carries no weight
            // Review L3: the blend's own per-field dedupe (a NOAA row equal to another on this field only).
            if let fieldShare {
                return fieldShare > 0 ? String(format: "%.1f× · %.0f%%", w, 100 * fieldShare) : "same as NOAA vote · 0%"
            }
            return total > 0 ? String(format: "%.1f× · %.0f%%", w, 100 * w / total) : String(format: "%.1f×", w)
        }
        func cell(_ value: String, _ weight: String) -> some View {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).lineLimit(1).minimumScaleFactor(0.75)
                Text(weight).font(.caption.monospacedDigit()).opacity(0.65)
            }
            .frame(width: 92, alignment: .trailing)
        }
        return VStack(spacing: 0) {
            HStack {
                Text("Source").frame(maxWidth: .infinity, alignment: .leading)
                Text("High · weight").frame(width: 92, alignment: .trailing)
                Text("Low · weight").frame(width: 92, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).opacity(0.7).padding(.vertical, 6)
            ForEach(d.sources) { s in
                Divider().overlay(Color.white.opacity(0.2))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name)
                        if s.name.contains(" = ") {
                            Text("Identical forecasts · 1 vote").font(.caption).opacity(0.65)
                        } else if s.high != nil, s.low == nil {
                            Text("High only (no NWS low for this day)").font(.caption).opacity(0.65)
                        } else if s.high == nil, s.low != nil {
                            Text("Low only").font(.caption).opacity(0.65)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    cell(units.temperatureString(s.high, withUnit: true), share(s.weight, s.high, highTotal, s.highShare))
                    cell(units.temperatureString(s.low, withUnit: true), share(s.weight, s.low, lowTotal, s.lowShare))
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 7)
            }
            Divider().overlay(Color.white.opacity(0.2))
            HStack {
                Text("Skyline blend").font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text(units.temperatureString(d.high, withUnit: true)).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 92, alignment: .trailing)
                Text(units.temperatureString(d.low, withUnit: true)).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 92, alignment: .trailing)
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summary(_ d: DailyForecast) -> String {
        switch module {
        case .conditions:
            return d.summary ?? "\(d.condition.description). High \(units.temperatureString(d.high, withUnit: true)), low \(units.temperatureString(d.low, withUnit: true))."
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
        case .accuracy:
            return ""
        case .confidence:
            return "Skyline weights each source by its typical skill: HRRR dominates the first 18 hours in the US, the NWS official forecast and ECMWF carry the most weight after that. When sources disagree, confidence drops."
        }
    }
}
