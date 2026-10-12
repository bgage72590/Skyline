import AppKit
import SwiftUI
import SkylineCore

/// Status item: icon + temperature. Re-renders only when the report changes.
/// Drawn as a template image (the menu bar tints it like any other item) so the layout can be fixed:
/// the digits are tabular and the temperature always reserves the width of "88°", so 9° → 10° or a
/// different digit doesn't nudge the neighbouring menu-bar icons (L11). When the data is stale or
/// offline the image is drawn at reduced strength.
struct MenuBarLabel: View {
    let store: WeatherStore

    struct Spec: Equatable {
        var symbol: String
        var text: String
        var dimmed: Bool
        var key: String { symbol + "|" + text + (dimmed ? "|d" : "") }
    }

    var body: some View {
        // Only reads the pre-rendered image (WeatherStore.trackMenuBarImage); no rendering in body.
        if let image = store.menuBarImage {
            Image(nsImage: image)
        } else if let spec = store.menuBarLabelSpec {
            Label(spec.text, systemImage: spec.symbol)
                .labelStyle(.titleAndIcon)
        } else {
            Label("Skyline", systemImage: "cloud.sun")
                .labelStyle(.iconOnly)
        }
    }

    /// Renders "symbol + temperature" into a template image (45 % alpha if dimmed). Called by the store
    /// outside any view update, only when the spec changes.
    @MainActor static func render(_ spec: Spec) -> NSImage? {
        let content = HStack(spacing: 4) {
            Image(systemName: spec.symbol)
            ZStack(alignment: .leading) {
                Text("88°").hidden() // reserve two digits' width
                Text(spec.text)
            }
            .monospacedDigit()
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(Color.black.opacity(spec.dimmed ? 0.45 : 1))
        .padding(.horizontal, 1)
        let renderer = ImageRenderer(content: content)
        // Always 2×: sharp on Retina, cleanly downsampled on a 1× display, so moving between displays
        // never leaves a soft image (Code Reviewer batch 3).
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
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
                if let alert = report.activeAlerts().first {
                    let alertCount = report.activeAlerts().count
                    // Opens the main window on this location with the full alert text.
                    Button {
                        store.selectedID = report.location.id
                        store.activeModule = nil
                        store.radarExpanded = false
                        store.pendingAlertID = alert.id
                        openWindow(id: SceneID.main)
                        NSApp.activate()
                    } label: {
                        HStack(spacing: 4) {
                            Label("\(alert.event)\(alertCount > 1 ? " +\(alertCount - 1)" : "")",
                                  systemImage: "exclamationmark.triangle.fill")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).opacity(0.8)
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AlertsCard.color(alert.severity))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Read the full alert")
                }
                Text(Briefing.headline(report, now: Date(),
                                       hourLabel: { Fmt.hour($0, report.timeZone) },
                                       delta: { Int(store.units.temperatureDelta($0).rounded()) }))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let change = InsightFormat.changes(report, units: store.units).first {
                    // "Tomorrow's high is down 5° since this morning" (T11).
                    Label(change, systemImage: change.contains(" up ") ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.medium))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Everything below the headline scrolls if the dropdown would be taller than the screen (T21).
                ViewThatFits(in: .vertical) {
                    details(report)
                    ScrollView { details(report) }.scrollIndicators(.automatic)
                }
                .frame(maxHeight: Self.maxDetailsHeight)
                updatedLine(report)
            } else if let location = store.menuBarLocation {
                if let error = store.errors[location.id], !store.isLoading(location) {
                    // First load failed (e.g. started offline): say so and offer a retry, like the main window.
                    VStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 26))
                        Text("Couldn’t load \(location.isCurrentLocation ? "My Location" : location.name)")
                            .font(.headline)
                        Text(error).font(.caption).opacity(0.8)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                        Button("Try Again") { Task { await store.load(location, force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading \(location.name)…")
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
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
                    store.toggleTemperatureUnit()
                } label: {
                    Text(store.units.temperature.label).font(.callout.weight(.semibold)).monospacedDigit()
                }
                .help("Switch to \(store.units.temperature == .fahrenheit ? "°C" : "°F")")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
                .help("Settings (⌘,)")
                if store.loadingIDs.isEmpty {
                    Button {
                        Task { await store.refreshAll(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                } else {
                    // Visible feedback while refreshing (T21).
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        .help("Refreshing…")
                }
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
        .id(store.clockStyle)
        .foregroundStyle(.white)
        .background {
            // Black wash keeps white text ≥ 4.5:1 on every sky (T6; tested via SkyColors.dropdownScrim).
            ZStack {
                SkyPalette.gradient(for: report)
                Color.black.opacity(SkyColors.dropdownScrim)
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            if let location = store.menuBarLocation { await store.load(location) }
        }
        .onAppear {
            let open = openWindow
            AppActions.openMainWindow = { open(id: SceneID.main) }
        }
    }

    /// Tallest the scrolling middle section may get: the screen's usable height minus the header,
    /// alert, briefing and footer.
    private static var maxDetailsHeight: CGFloat {
        // QA hook: `-SkylineMenuMaxHeight 220` forces the scrolling case on a normal screen.
        let forced = UserDefaults.standard.double(forKey: "SkylineMenuMaxHeight")
        if forced > 0 { return forced }
        return max(260, (NSScreen.main?.visibleFrame.height ?? 800) - 300)
    }

    @ViewBuilder
    private func details(_ report: WeatherReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if Briefing.rainDueSoon(report, now: Date()) {
                MiniNowcast(report: report).frame(height: 46)
            }
            hourly(report)
            chips(report)
            daily(report)
            otherLocations(report)
        }
    }

    /// "Updated 5 min ago" (ticks while the dropdown is open), or "Offline · Updated 2 h ago".
    private func updatedLine(_ report: WeatherReport) -> some View {
        let offline = store.isOffline(report)
        let stale = store.isStale(report)
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                if offline { Image(systemName: "wifi.slash") }
                Text((offline ? "Offline · " : "") + DataAge.updatedText(report, now: context.date))
            }
            .font(.caption.weight(stale ? .semibold : .regular))
            .foregroundStyle(stale ? Color.orange : Color.white.opacity(0.75))
            .help(store.errors[report.location.id] ?? "Data from \(Fmt.dataTime(report.dataAsOf))")
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
                    Text(store.units.temperatureString(hour.temperature)).font(.callout.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// UV, air quality and peak gust at a glance.
    private func chips(_ report: WeatherReport) -> some View {
        let tz = report.timeZone
        let gust = Briefing.peak(report.hourly.compactMap { h in h.windGust.map { (h.time, $0) } }, from: report.current.time, hours: 24)
        return HStack(spacing: 6) {
            if let uv = report.current.uvIndex {
                chip("sun.max.fill", "UV \(Int(uv.rounded()))", UVScale.category(uv))
            }
            if let aq = report.airQuality {
                chip("aqi.medium", "AQI \(aq.usAQI)", aq.category)
            }
            if let gust, gust.value > 0 {
                // Unit in the value, the word in the caption, so the number is never what gets cut (UI/UX #10).
                chip("wind", store.units.speedString(gust.value), "Gust · " + Fmt.hour(gust.time, tz))
            }
        }
    }

    private func chip(_ symbol: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(value, systemImage: symbol).font(.caption.weight(.semibold)).lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(caption).font(.caption2).opacity(0.9).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The other saved locations: one tap opens them in the main window.
    @ViewBuilder
    private func otherLocations(_ report: WeatherReport) -> some View {
        let others = store.allLocations.filter { $0.id != report.location.id }.prefix(5)
        if !others.isEmpty {
            VStack(spacing: 2) {
                ForEach(Array(others)) { location in
                    let r = store.reports[location.id]
                    Button {
                        store.selectedID = location.id
                        openWindow(id: SceneID.main)
                        NSApp.activate()
                    } label: {
                        HStack(spacing: 8) {
                            Text(location.isCurrentLocation ? "My Location" : location.name).lineLimit(1)
                            Spacer()
                            if let r { WeatherSymbol(condition: r.current.condition, isDay: r.current.isDay, size: 13) }
                            Text(store.units.temperatureString(r?.current.temperature)).monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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
                    Text(store.units.temperatureString(day.low)).opacity(0.8).frame(width: 34, alignment: .trailing)
                    TemperatureRangeBar(rangeLow: low, rangeHigh: high, low: day.low, high: day.high)
                    Text(store.units.temperatureString(day.high)).frame(width: 34, alignment: .trailing)
                }
                .font(.callout.weight(.medium))
                .monospacedDigit()
            }
        }
    }
}

/// Compact next-2-hours rain curve for the menu-bar dropdown (same interpolation as the main card).
struct MiniNowcast: View {
    let report: WeatherReport

    var body: some View {
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let samples = NowcastCurve.samples(report.minutely, from: start, minutes: 120, step: 2)
        VStack(spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let pts = samples.enumerated().map { i, s in
                    CGPoint(x: w * CGFloat(i) / CGFloat(max(samples.count - 1, 1)), y: h - h * CGFloat(NowcastCurve.level(s.rate) / 3))
                }
                ZStack {
                    ForEach([1.0, 2.0], id: \.self) { l in
                        Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5).position(x: w / 2, y: h - h * l / 3)
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.72, blue: 1.0).opacity(0.9),
                                                  Color(red: 0.36, green: 0.72, blue: 1.0).opacity(0.15)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
            HStack {
                Text("Now"); Spacer(); Text("1 h"); Spacer(); Text("2 h")
            }
            .font(.caption2.weight(.medium)).opacity(0.9)
        }
        .accessibilityLabel(report.nowcastSummary(at: Date()) ?? "Rain in the next two hours")
    }
}
