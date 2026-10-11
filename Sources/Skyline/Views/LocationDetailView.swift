import SwiftUI
import SkylineCore

/// Detail page laid out like Apple Weather on the Mac: centred hero over a condition gradient,
/// full-width hourly module, 10-day module on the left, map + square tiles on the right.
/// The map expands in place to fill this area; other modules open an in-window detail panel.
struct LocationDetailView: View {
    let location: WeatherLocation
    @Environment(WeatherStore.self) private var store
    @Namespace private var radarNamespace
    @State private var width: CGFloat = 900

    var body: some View {
        let report = store.reports[location.id]
        ZStack {
            SkyPalette.gradient(for: report).ignoresSafeArea()
            if let report {
                ScrollView {
                    content(report)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 26)
                        .frame(maxWidth: 1120)
                        .frame(maxWidth: .infinity)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: WidthKey.self, value: geo.size.width)
                        })
                }
                .onPreferenceChange(WidthKey.self) { width = $0 }
                .opacity(store.radarExpanded ? 0 : 1)
                .scrollDisabled(store.radarExpanded || store.activeModule != nil)

                if store.radarExpanded {
                    ExpandedRadarView(location: location, pinText: store.units.temperatureString(report.current.temperature),
                                      namespace: radarNamespace)
                        .padding(14)
                        .transition(.opacity)
                        .zIndex(2)
                }
                if let selection = store.activeModule {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { store.activeModule = nil } }
                        .transition(.opacity)
                        .zIndex(3)
                    ModuleDetailView(report: report, selection: selection)
                        .id(selection.id + (selection.day.map { "\($0.timeIntervalSince1970)" } ?? ""))
                        .padding(30)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(4)
                }
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
        .task(id: location.id) { await store.load(location) }
        .onChange(of: location.id) { _, _ in store.radarExpanded = false; store.activeModule = nil }
    }

    @ViewBuilder
    private func content(_ report: WeatherReport) -> some View {
        let units = store.units
        VStack(spacing: 14) {
            HeroView(report: report, units: units)
            if !report.alerts.isEmpty {
                AlertsCard(alerts: report.alerts, timeZone: report.timeZone)
            }
            HourlyCard(report: report, units: units) { open(.conditions, day: nil) }
            if width >= 820 {
                HStack(alignment: .top, spacing: 14) {
                    DailyCard(report: report, units: units) { open(.conditions, day: $0) }
                        .frame(width: 350)
                    VStack(spacing: 14) {
                        RadarCard(location: location, pinText: units.temperatureString(report.current.temperature),
                                  namespace: radarNamespace)
                        DetailTilesGrid(report: report, units: units) { open($0, day: nil) }
                    }
                }
            } else {
                DailyCard(report: report, units: units) { open(.conditions, day: $0) }
                RadarCard(location: location, pinText: units.temperatureString(report.current.temperature),
                          namespace: radarNamespace)
                DetailTilesGrid(report: report, units: units) { open($0, day: nil) }
            }
            SourcesFooter(report: report)
        }
        .foregroundStyle(.white)
    }

    private func open(_ module: DetailModule, day: Date?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            store.activeModule = ModuleSelection(module: module, day: day)
        }
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
        VStack(spacing: 0) {
            if report.location.isCurrentLocation {
                Text("My Location")
                    .font(.system(size: 34, weight: .regular))
                Text(report.location.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .opacity(0.85)
            } else {
                Text(report.location.name)
                    .font(.system(size: 34, weight: .regular))
            }
            Text(units.temperatureString(report.current.temperature))
                .font(.system(size: 102, weight: .thin))
                .padding(.leading, 28) // optically centre despite the trailing degree sign
            Text(report.current.condition.description)
                .font(.title3.weight(.medium))
                .opacity(0.9)
            if let today = report.today {
                Text("H:\(units.temperatureString(today.high))  L:\(units.temperatureString(today.low))")
                    .font(.title3.weight(.medium))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 30)
        .padding(.bottom, 16)
    }
}

/// An hourly-strip item: a forecast hour or a sunrise/sunset marker (as Apple Weather shows).
private enum HourItem: Identifiable {
    case hour(HourlyForecast, isNow: Bool)
    case sun(Date, sunrise: Bool)

    var id: String {
        switch self {
        case .hour(let h, _): "h\(h.time.timeIntervalSince1970)"
        case .sun(let d, let rise): "\(rise ? "r" : "s")\(d.timeIntervalSince1970)"
        }
    }
    var time: Date {
        switch self {
        case .hour(let h, _): h.time
        case .sun(let d, _): d
        }
    }
}

struct HourlyCard: View {
    let report: WeatherReport
    let units: UnitPreference
    var onOpen: () -> Void = {}

    var body: some View {
        let items = makeItems()
        Button(action: onOpen) {
            Card(title: headline == nil ? "Hourly Forecast" : nil, systemImage: "clock", subtitle: headline) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(items) { item in
                            cell(item).frame(width: 54)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cell(_ item: HourItem) -> some View {
        switch item {
        case .hour(let hour, let isNow):
            VStack(spacing: 8) {
                Text(isNow ? "Now" : Fmt.hour(hour.time, report.timeZone))
                    .font(.callout.weight(.semibold))
                VStack(spacing: 1) {
                    WeatherSymbol(condition: isNow ? report.current.condition : hour.condition,
                                  isDay: isNow ? report.current.isDay : hour.isDay)
                    Text(popText(hour))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(red: 0.55, green: 0.82, blue: 1.0))
                }
                Text(units.temperatureString(isNow ? report.current.temperature : hour.temperature))
                    .font(.title3.weight(.medium))
            }
        case .sun(let time, let sunrise):
            VStack(spacing: 8) {
                Text(Fmt.time(time, report.timeZone))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: sunrise ? "sunrise.fill" : "sunset.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                    .frame(height: 27.5)
                Text(" ").font(.caption2)
                Text(sunrise ? "Sunrise" : "Sunset")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private func makeItems() -> [HourItem] {
        let hours = report.upcomingHours(count: 25)
        guard let first = hours.first, let last = hours.last else { return [] }
        var items: [HourItem] = hours.enumerated().map { .hour($0.element, isNow: $0.offset == 0) }
        for day in report.daily.prefix(3) {
            if let r = day.sunrise, r > first.time, r < last.time { items.append(.sun(r, sunrise: true)) }
            if let s = day.sunset, s > first.time, s < last.time { items.append(.sun(s, sunrise: false)) }
        }
        return items.sorted { $0.time < $1.time }
    }

    private func popText(_ hour: HourlyForecast) -> String {
        guard let p = hour.precipitationProbability, p >= 20 else { return " " }
        return "\(Int((p / 10).rounded() * 10))%"
    }

    /// Apple-style one-line summary: nowcast first, otherwise the NWS/consensus text for today.
    private var headline: String? {
        if let nowcast = report.nowcastSummary { return nowcast + "." }
        if let summary = report.today?.summary {
            return summary.split(separator: ".").prefix(2).joined(separator: ".") + "."
        }
        return nil
    }
}

struct DailyCard: View {
    let report: WeatherReport
    let units: UnitPreference
    var onOpenDay: (Date) -> Void = { _ in }

    var body: some View {
        let days = report.daily
        let low = days.map(\.low).min() ?? 0
        let high = days.map(\.high).max() ?? 1
        Card(title: "\(days.count)-Day Forecast", systemImage: "calendar") {
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { offset, day in
                    VStack(spacing: 0) {
                        Button { onOpenDay(day.date) } label: {
                            row(offset: offset, day: day, rangeLow: low, rangeHigh: high)
                        }
                        .buttonStyle(.plain)
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
                .opacity(0.6)
                .frame(width: 40, alignment: .trailing)
            TemperatureRangeBar(rangeLow: rangeLow, rangeHigh: rangeHigh, low: day.low, high: day.high,
                                current: offset == 0 ? report.current.temperature : nil)
            Text(units.temperatureString(day.high))
                .frame(width: 40, alignment: .trailing)
        }
        .font(.title3.weight(.medium))
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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
