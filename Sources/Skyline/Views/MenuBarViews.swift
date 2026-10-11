import AppKit
import SwiftUI
import SkylineCore

/// Status item: icon + temperature. Re-renders only when the report changes.
struct MenuBarLabel: View {
    let store: WeatherStore

    var body: some View {
        if let report = store.menuBarReport {
            Label(store.units.temperatureString(report.current.temperature),
                  systemImage: report.current.condition.symbolName(isDay: report.current.isDay))
                .labelStyle(.titleAndIcon)
        } else {
            Label("Skyline", systemImage: "cloud.sun")
                .labelStyle(.iconOnly)
        }
    }
}

struct MenuBarContentView: View {
    @Environment(WeatherStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let report = store.menuBarReport
        VStack(alignment: .leading, spacing: 10) {
            if let report {
                header(report)
                if let alert = report.alerts.first {
                    Label("\(alert.event)\(report.alerts.count > 1 ? " +\(report.alerts.count - 1)" : "")",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AlertsCard.color(alert.severity))
                }
                if let nowcast = report.nowcastSummary {
                    Label(nowcast, systemImage: "umbrella.fill").font(.callout)
                }
                hourly(report)
                daily(report)
            } else if let location = store.menuBarLocation {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading \(location.name)…")
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text("Open Skyline to add a location.").frame(maxWidth: .infinity, minHeight: 80)
            }
            Rectangle().fill(.white.opacity(0.25)).frame(height: 0.5)
            HStack {
                Button("Open Skyline") {
                    openWindow(id: SceneID.main)
                    NSApp.activate()
                }
                Button("Radar") {
                    if let location = store.menuBarLocation { store.selectedID = location.id }
                    store.activeModule = nil
                    store.radarExpanded = true
                    openWindow(id: SceneID.main)
                    NSApp.activate()
                }
                Spacer()
                Button {
                    Task { await store.refreshAll(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Skyline")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .foregroundStyle(.white)
        .background(SkyPalette.gradient(for: report))
        .environment(\.colorScheme, .dark)
        .task {
            if let location = store.menuBarLocation { await store.load(location) }
        }
        .onAppear {
            let open = openWindow
            AppActions.openMainWindow = { open(id: SceneID.main) }
        }
    }

    private func header(_ report: WeatherReport) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if report.location.isCurrentLocation { Image(systemName: "location.fill").font(.caption) }
                    Text(report.location.name).font(.headline)
                }
                Text(report.current.condition.description).font(.callout).opacity(0.9)
                if let today = report.today {
                    Text("H:\(store.units.temperatureString(today.high))  L:\(store.units.temperatureString(today.low))")
                        .font(.callout)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 30)
                Text(store.units.temperatureString(report.current.temperature))
                    .font(.system(size: 40, weight: .light))
            }
        }
    }

    private func hourly(_ report: WeatherReport) -> some View {
        let hours = Array(report.upcomingHours(count: 7).dropFirst())
        return HStack(spacing: 0) {
            ForEach(hours) { hour in
                VStack(spacing: 4) {
                    Text(Fmt.hour(hour.time, report.timeZone)).font(.caption2.weight(.semibold))
                    WeatherSymbol(condition: hour.condition, isDay: hour.isDay, size: 16)
                    Text(store.units.temperatureString(hour.temperature)).font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func daily(_ report: WeatherReport) -> some View {
        let days = Array(report.daily.prefix(5))
        let low = days.map(\.low).min() ?? 0
        let high = days.map(\.high).max() ?? 1
        return VStack(spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.id) { offset, day in
                HStack(spacing: 8) {
                    Text(offset == 0 ? "Today" : Fmt.weekday(day.date, report.timeZone))
                        .frame(width: 46, alignment: .leading)
                    WeatherSymbol(condition: day.condition, isDay: true, size: 14)
                        .frame(width: 22)
                    Text(store.units.temperatureString(day.low)).opacity(0.65).frame(width: 34, alignment: .trailing)
                    TemperatureRangeBar(rangeLow: low, rangeHigh: high, low: day.low, high: day.high)
                    Text(store.units.temperatureString(day.high)).frame(width: 34, alignment: .trailing)
                }
                .font(.callout.weight(.medium))
            }
        }
    }
}

struct SettingsView: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Units", selection: $store.units) {
                ForEach(UnitPreference.allCases) { Text($0.label).tag($0) }
            }
            Picker("Refresh every", selection: $store.refreshMinutes) {
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            Section("Data sources") {
                Text("Forecasts blend Open-Meteo models (best match, NOAA HRRR, ECMWF IFS, NOAA GFS, DWD ICON) with the official National Weather Service forecast in the US. Alerts from NWS. Radar from NOAA NEXRAD via Iowa Environmental Mesonet (US) and RainViewer (global). All free, no API keys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
