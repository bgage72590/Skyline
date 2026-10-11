import SwiftUI
import SkylineCore

struct LocationDetailView: View {
    let location: WeatherLocation
    @Environment(WeatherStore.self) private var store
    @State private var width: CGFloat = 900

    var body: some View {
        let report = store.reports[location.id]
        ZStack {
            SkyPalette.gradient(for: report).ignoresSafeArea()
            if let report {
                ScrollView {
                    content(report)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: WidthKey.self, value: geo.size.width)
                        })
                }
                .onPreferenceChange(WidthKey.self) { width = $0 }
            } else if let error = store.errors[location.id] {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 44))
                    Text("Couldn’t load weather for \(location.name)").font(.title3)
                    Text(error).font(.caption).foregroundStyle(.white.opacity(0.8))
                    Button("Try Again") { Task { await store.load(location, force: true) } }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle(location.isCurrentLocation ? "My Location" : location.name)
        .navigationSubtitle(report.map { "Updated \(Fmt.time($0.fetchedAt, .current))" } ?? "")
        .task(id: location.id) { await store.load(location) }
    }

    @ViewBuilder
    private func content(_ report: WeatherReport) -> some View {
        let units = store.units
        VStack(spacing: 14) {
            HeroView(report: report, units: units)
            if !report.alerts.isEmpty {
                AlertsCard(alerts: report.alerts, timeZone: report.timeZone)
            }
            HourlyCard(report: report, units: units)
            if width >= 820 {
                HStack(alignment: .top, spacing: 14) {
                    DailyCard(report: report, units: units)
                        .frame(width: 360)
                    VStack(spacing: 14) {
                        RadarCard(location: location)
                        DetailTilesGrid(report: report, units: units)
                    }
                }
            } else {
                DailyCard(report: report, units: units)
                RadarCard(location: location)
                DetailTilesGrid(report: report, units: units)
            }
            SourcesFooter(report: report)
        }
        .foregroundStyle(.white)
    }
}

private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct HeroView: View {
    let report: WeatherReport
    let units: UnitPreference

    var body: some View {
        VStack(spacing: 2) {
            if report.location.isCurrentLocation {
                Label("My Location", systemImage: "location.fill")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .opacity(0.85)
            }
            Text(report.location.name)
                .font(.system(size: 34))
            Text(units.temperatureString(report.current.temperature))
                .font(.system(size: 96, weight: .thin))
                .padding(.leading, 26) // optically centre despite the trailing degree sign
            Text(report.current.condition.description)
                .font(.title3.weight(.medium))
                .opacity(0.9)
            if let today = report.today {
                Text("H:\(units.temperatureString(today.high))   L:\(units.temperatureString(today.low))")
                    .font(.title3.weight(.medium))
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.top, 28)
        .padding(.bottom, 10)
    }
}

struct HourlyCard: View {
    let report: WeatherReport
    let units: UnitPreference

    var body: some View {
        let hours = report.upcomingHours(count: 25)
        Card(title: "Hourly Forecast", systemImage: "clock", subtitle: headline) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(hours.enumerated()), id: \.element.id) { offset, hour in
                        VStack(spacing: 8) {
                            Text(offset == 0 ? "Now" : Fmt.hour(hour.time, report.timeZone))
                                .font(.callout.weight(.semibold))
                            VStack(spacing: 1) {
                                WeatherSymbol(condition: offset == 0 ? report.current.condition : hour.condition,
                                              isDay: offset == 0 ? report.current.isDay : hour.isDay)
                                Text(popText(hour))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color(red: 0.55, green: 0.82, blue: 1.0))
                            }
                            Text(units.temperatureString(offset == 0 ? report.current.temperature : hour.temperature))
                                .font(.title3.weight(.medium))
                        }
                        .frame(width: 52)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func popText(_ hour: HourlyForecast) -> String {
        guard let p = hour.precipitationProbability, p >= 20 else { return " " }
        return "\(Int((p / 10).rounded() * 10))%"
    }

    /// Apple-style one-line summary: nowcast first, otherwise the NWS/consensus text for today.
    private var headline: String? {
        if let nowcast = report.nowcastSummary { return nowcast + "." }
        if let summary = report.today?.summary {
            return summary.split(separator: ".").first.map { String($0) + "." }
        }
        return nil
    }
}

struct DailyCard: View {
    let report: WeatherReport
    let units: UnitPreference
    @State private var expanded: Date?

    var body: some View {
        let days = report.daily
        let low = days.map(\.low).min() ?? 0
        let high = days.map(\.high).max() ?? 1
        Card(title: "\(days.count)-Day Forecast", systemImage: "calendar") {
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { offset, day in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expanded = expanded == day.date ? nil : day.date
                            }
                        } label: {
                            row(offset: offset, day: day, rangeLow: low, rangeHigh: high)
                        }
                        .buttonStyle(.plain)
                        if expanded == day.date {
                            DayDetail(day: day, units: units, timeZone: report.timeZone)
                                .padding(.bottom, 8)
                        }
                        if offset < days.count - 1 {
                            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
    }

    private func row(offset: Int, day: DailyForecast, rangeLow: Double, rangeHigh: Double) -> some View {
        HStack(spacing: 10) {
            Text(offset == 0 ? "Today" : Fmt.weekday(day.date, report.timeZone))
                .frame(width: 58, alignment: .leading)
            VStack(spacing: 0) {
                WeatherSymbol(condition: day.condition, isDay: true, size: 18)
                if let p = day.precipitationProbability, p >= 20 {
                    Text("\(Int((p / 10).rounded() * 10))%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.82, blue: 1.0))
                }
            }
            .frame(width: 34)
            Text(units.temperatureString(day.low))
                .opacity(0.65)
                .frame(width: 40, alignment: .trailing)
            TemperatureRangeBar(rangeLow: rangeLow, rangeHigh: rangeHigh, low: day.low, high: day.high,
                                current: offset == 0 ? report.current.temperature : nil)
            Text(units.temperatureString(day.high))
                .frame(width: 40, alignment: .trailing)
        }
        .font(.title3.weight(.medium))
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Expanded day: official text, wind, precip, model agreement.
struct DayDetail: View {
    let day: DailyForecast
    let units: UnitPreference
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.summary ?? "\(day.condition.description). High \(units.temperatureString(day.high)), low \(units.temperatureString(day.low)).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let sum = day.precipitationSum, sum > 0 {
                    Label(units.precipitationString(sum), systemImage: "drop.fill")
                }
                if let wind = day.windSpeedMax {
                    Label("\(units.speedString(wind)) \(Compass.abbreviation(day.windDirectionDominant))", systemImage: "wind")
                }
                if let uv = day.uvIndexMax {
                    Label("UV \(Int(uv.rounded()))", systemImage: "sun.max")
                }
                if let spread = day.highSpread {
                    Label("±\(Int((units.temperatureDelta(spread) / 2).rounded()))° model spread", systemImage: "chart.bar.xaxis")
                }
            }
            .font(.caption)
            .opacity(0.85)
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SourcesFooter: View {
    let report: WeatherReport

    var body: some View {
        VStack(spacing: 4) {
            Text("Blended forecast from " + report.sources.joined(separator: ", "))
            if let office = report.nwsOffice, !office.isEmpty {
                Text("Official forecast & alerts: National Weather Service (\(office))")
            }
            Text("Updated \(Fmt.dayTime(report.fetchedAt, .current)) · Weather data by Open-Meteo.com (CC BY 4.0)")
        }
        .font(.caption2)
        .multilineTextAlignment(.center)
        .opacity(0.7)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}
