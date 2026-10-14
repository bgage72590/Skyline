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
    @Environment(\.openWindow) private var openWindow

    struct Spec: Equatable {
        var symbol: String
        var text: String
        var dimmed: Bool
        var key: String { symbol + "|" + text + (dimmed ? "|d" : "") }
    }

    var body: some View {
        labelContent
            .onAppear {
                // The label lives as long as the app, so the Dock icon, a relaunch and Shortcuts can
                // reopen the window even before the dropdown or window has ever been shown (batch 6).
                let open = openWindow
                AppActions.openMainWindow = { open(id: SceneID.main) }
            }
    }

    @ViewBuilder private var labelContent: some View {
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
                        AppExit.showMainWindow(); GlobalHotkey.closePanel()
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let change = InsightFormat.changes(report, units: store.units).first {
                    // "Tomorrow's high is down 5° since this morning" (T11).
                    Label(change, systemImage: change.contains(" up ") ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.medium))
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Everything below the headline scrolls if the dropdown would be taller than the screen (T21).
                // Build 31: back to build 26's FitOrScroll sizing (natural height when it fits, scroll only
                // when taller than the screen allows), with a single copy of the details: the layout
                // measures the scroll view's ideal height, which is its content's natural height.
                FitOrScroll(maxHeight: Self.maxDetailsHeight) {
                    ScrollView { details(report) }
                        .scrollIndicators(.automatic)
                        .scrollBounceBehavior(.basedOnSize)
                }
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
                    AppExit.showMainWindow(); GlobalHotkey.closePanel()
                    NSApp.activate()
                }
                Button("Radar") {
                    if let location = store.menuBarLocation { store.selectedID = location.id }
                    store.activeModule = nil
                    store.radarExpanded = true
                    AppExit.showMainWindow(); GlobalHotkey.closePanel()
                    NSApp.activate()
                }
                Spacer()
                Button {
                    store.toggleTemperatureUnit()
                } label: {
                    Text(store.units.temperature.label).font(.callout.weight(.semibold)).monospacedDigit()
                }
                .help("Switch to \(store.units.temperature == .fahrenheit ? "°C" : "°F")")
                // SettingsLink is inert in the ⌃⌥W HotkeyPanel (no Settings scene there). Open the
                // Settings window the AppKit way so the gear works from both the menu-bar dropdown
                // and the hotkey panel (QA #3).
                Button {
                    AppExit.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
                Button("Update…") { Updater.checkForUpdates() }
                    .help("Update Skyline from iCloud Drive")
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
                    AppExit.perform(.menuBarQuit)
                } label: {
                    Label("Quit Skyline", systemImage: "power").labelStyle(.titleAndIcon).font(.caption)
                }
                .help("Quit Skyline completely (closing the window or ⌘Q keeps it in the menu bar)")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 344)
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
            rainCard(report)
            hourly(report)
            conditionsGrid(report)
            daily(report).menuGlass()
            otherLocations(report)
        }
    }

    /// When rain is next expected, with the 2-hour curve when it's close.
    private func rainCard(_ report: WeatherReport) -> some View {
        let now = Date()
        let soon = Briefing.rainDueSoon(report, now: now)
        let text = MenuSummary.rainTiming(report, now: now, hourLabel: { Fmt.hour($0, report.timeZone) })
        return VStack(alignment: .leading, spacing: 6) {
            if let text {
                Label(text, systemImage: soon || report.current.condition.isPrecipitation ? "cloud.rain.fill" : "umbrella")
                    .font(.callout.weight(.medium))
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if soon { MiniNowcast(report: report).frame(height: 46) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .menuGlass()
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if report.location.isCurrentLocation { Image(systemName: "location.fill").font(.caption) }
                    Text(report.location.isCurrentLocation ? "My Location" : report.location.name).font(.headline)
                        .lineLimit(1)
                }
                if report.location.isCurrentLocation && report.location.name != "My Location" {
                    Text(report.location.name).font(.caption).opacity(0.85).lineLimit(1)
                }
                Text(report.current.condition.description).font(.callout.weight(.medium))
                Text("Feels like \(store.units.temperatureString(report.current.apparentTemperature))")
                    .font(.callout).opacity(0.9)
                if let today = report.today {
                    Text("H:\(store.units.temperatureString(today.high))  L:\(store.units.temperatureString(today.low))")
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 34)
                Text(store.units.temperatureString(report.current.temperature))
                    .font(.system(size: 50, weight: .thin))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 2)
    }

    private func hourly(_ report: WeatherReport) -> some View {
        let hours = Array(report.upcomingHours(count: 8).dropFirst().prefix(6))
        return HStack(spacing: 0) {
            ForEach(hours) { hour in
                VStack(spacing: 4) {
                    Text(Fmt.hour(hour.time, report.timeZone)).font(.caption2.weight(.semibold)).opacity(0.9)
                    WeatherSymbol(condition: hour.condition, isDay: hour.isDay, size: 18)
                        .frame(height: 20)
                    Text(store.units.temperatureString(hour.temperature)).font(.callout.weight(.semibold)).monospacedDigit()
                    let p = Int((hour.precipitationProbability ?? 0).rounded())
                    Text(p >= 20 ? "\(p)%" : " ").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.80, blue: 1.0))
                        .accessibilityHidden(p < 20)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
        .menuGlass()
    }

    /// Wind, humidity, UV, air quality, sunrise/sunset and pressure in a 3 × 2 grid of small tiles.
    private func conditionsGrid(_ report: WeatherReport) -> some View {
        let c = report.current
        let tz = report.timeZone
        let now = Date()
        let gust = Briefing.peak(report.hourly.compactMap { h in h.windGust.map { (h.time, $0) } }, from: c.time, hours: 24)
        var tiles: [(String, String, String, String)] = []  // symbol, title, value, caption
        tiles.append(("wind", "Wind", store.units.speedString(c.windSpeed),
                      c.windDirection.map { "from \(Compass.abbreviation($0))" + (gust.map { " · gusts \(store.units.speedString($0.value))" } ?? "") }
                        ?? (gust.map { "gusts \(store.units.speedString($0.value))" } ?? "")))
        tiles.append(("humidity.fill", "Humidity", "\(Int(c.humidity.rounded()))%",
                      MenuSummary.comfort(dewPointC: c.dewPoint).map { "\($0) · dew \(store.units.temperatureString(c.dewPoint))" } ?? ""))
        if let uv = c.uvIndex {
            let peak = report.today?.uvIndexMax.map { " · max \(Int($0.rounded()))" } ?? ""
            tiles.append(("sun.max.fill", "UV", "\(Int(uv.rounded()))", UVScale.category(uv) + peak))
        }
        if let aq = report.airQuality {
            tiles.append(("aqi.medium", "Air quality", "\(aq.usAQI)", aq.category))
        }
        if let sun = MenuSummary.nextSunEvent(report, now: now) {
            tiles.append((sun.isSunrise ? "sunrise.fill" : "sunset.fill", sun.isSunrise ? "Sunrise" : "Sunset",
                          Fmt.time(sun.time, tz), { var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                            return cal.isDate(sun.time, inSameDayAs: now) ? "today" : "tomorrow" }()))
        }
        if tiles.count < 6, let p = c.pressure {
            tiles.append(("gauge.with.dots.needle.50percent", "Pressure", store.units.pressureString(p), ""))
        }
        if tiles.count < 6, let rainToday = report.today?.precipitationProbability {
            tiles.append(("drop.fill", "Rain today", "\(Int(rainToday.rounded()))%", ""))
        }
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(Array(tiles.prefix(6).enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 2) {
                    Label(t.1, systemImage: t.0).font(.caption2.weight(.semibold)).opacity(0.85).lineLimit(1)
                    Text(t.2).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    Text(t.3.isEmpty ? " " : t.3).font(.caption2).opacity(0.85).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                .menuGlass(cornerRadius: 14, padding: 8)
                .accessibilityElement(children: .combine)
            }
        }
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
                        AppExit.showMainWindow(); GlobalHotkey.closePanel()
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
            .menuGlass(padding: 4)
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

extension View {
    /// Dropdown card: Liquid Glass on macOS 26 and later, a frosted material on older systems (polish 3).
    /// Static (no animation), so it costs nothing while the dropdown just sits open.
    @ViewBuilder
    func menuGlass(cornerRadius: CGFloat = 18, padding: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.padding(padding)
                .glassEffect(.regular.tint(.black.opacity(0.22)), in: shape)
        } else {
            self.padding(padding)
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.black.opacity(0.22))
                    }
                }
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// Gives its single subview (a ScrollView around the content) the content's natural height when that
/// fits under `maxHeight`, else `maxHeight`, so it scrolls only when really taller (build 26 sizing,
/// one copy of the content). Pure layout: no state is written while measuring, so the dropdown window
/// never sizes itself from a not-yet-measured height (the "squeezed" dropdown of builds 27-30).
struct FitOrScroll: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
