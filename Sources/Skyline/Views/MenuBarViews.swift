import AppKit
import SwiftUI
import SkylineCore

/// Status item: icon + temperature. Re-renders only when the report changes.
/// Drawn as a template image (the menu bar tints it like any other item) so the layout can be fixed:
/// the digits are tabular and the temperature always reserves the width of "88°F" or "88°C", so
/// 9°F → 10°F or a different digit doesn't nudge the neighbouring menu-bar icons (L11). When the data is stale or
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
                // Two digits plus the unit letter actually in use, so the extra character isn't clipped
                // and a digit change still doesn't move the icons beside this item.
                Text(Self.reservedWidth(spec.text)).hidden()
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

    /// Width stand-in for a two-digit temperature in the same unit as `text` ("72°F" → "88°F").
    static func reservedWidth(_ text: String) -> String {
        if text.hasSuffix("C") { return "88°C" }
        if text.hasSuffix("F") { return "88°F" }
        return "88°"
    }
}

struct MenuBarContentView: View {
    @Environment(WeatherStore.self) private var store
    /// The other-cities list starts collapsed (Brian, Oct 17: keep it, but collapsed).
    @AppStorage("menuCitiesExpanded") private var citiesExpanded = false

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
                // SPC level 2+ gets its own amber row instead of a sentence at the end of the headline.
                if let severe = MenuSummary.severeRow(report, now: Date()) {
                    Label(severe, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Self.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Storm Prediction Center outlook for this place")
                }
                // The rain sentence lives in the rain card (one shared RainTiming line), so the headline
                // keeps only the rest ("Tomorrow is 13° cooler.").
                let headline = Briefing.headline(report, now: Date(),
                                                 hourLabel: { Fmt.hour($0, report.timeZone) },
                                                 delta: { Int(store.units.temperatureDelta($0).rounded()) },
                                                 includeRain: false, includeSevere: false)
                if !headline.isEmpty {
                    Text(headline)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            // Build 35 footer (UI/UX spec "Footer layout fix"): seven controls no longer fit 316 pt, so the
            // daily ones stay visible as 28 pt icons and the rare ones move into a "…" menu.
            HStack(spacing: 0) {
                Button("Open Skyline") { AppExit.showMainWindow(); GlobalHotkey.closePanel(); NSApp.activate() }
                    .fixedSize()
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    FooterIcon("map", help: "Show radar map") {
                        if let l = store.menuBarLocation { store.selectedID = l.id }
                        store.activeModule = nil; store.radarExpanded = true
                        AppExit.showMainWindow(); GlobalHotkey.closePanel(); NSApp.activate()
                    }
                    Button { store.toggleTemperatureUnit() } label: {
                        Text(store.units.temperature.label).font(.callout.weight(.semibold)).monospacedDigit()
                            .frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                    }
                    .help("Switch to \(store.units.temperature == .fahrenheit ? "°C" : "°F")")
                    .accessibilityLabel("Temperature unit: \(store.units.temperature == .fahrenheit ? "Fahrenheit" : "Celsius")")
                    .accessibilityHint("Switches to \(store.units.temperature == .fahrenheit ? "Celsius" : "Fahrenheit")")
                    if store.loadingIDs.isEmpty {
                        FooterIcon("arrow.clockwise", help: "Refresh weather") { Task { await store.refreshAll(force: true) } }
                    } else {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28).help("Refreshing…")
                            .accessibilityLabel("Refreshing weather")
                    }
                    Menu {
                        // SettingsLink is inert in the ⌃⌥W HotkeyPanel, so Settings opens the AppKit way (QA #3).
                        // Each item also closes the ⌃⌥W hotkey panel (QA build-41 F1).
                        Button("Settings…") { GlobalHotkey.closePanel(); AppExit.openSettings() }
                        Button("Check for Updates…") { GlobalHotkey.closePanel(); Updater.checkForUpdates() }
                        Divider()
                        Button("Quit Skyline") { GlobalHotkey.closePanel(); AppExit.perform(.menuBarQuit) }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More: Settings, Updates, Quit")
                    .accessibilityLabel("More options")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 344)
        .id(store.clockStyle)
        .foregroundStyle(.white)
        .dropdownSurface(report: report)
        .environment(\.colorScheme, .dark)
        .background(DropdownWindowConfigurator(cornerRadius: DropdownShape.radius,
                                                onBecomeKey: { Task { await store.dropdownOpened() } }))
        .task { await store.dropdownOpened() }
    }

    static let amber = Color(red: 1.0, green: 0.76, blue: 0.24)

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
            // Only when the quarters ahead are wet (a quarter that already ended drew an empty axis).
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
                // Only when it's at least 3° off (67° "feels like 68°" was noise).
                if let feels = MenuSummary.feelsLikeText(temperature: report.current.temperature,
                                                          apparent: report.current.apparentTemperature, units: store.units,
                                                          withUnit: true) {
                    Text(feels).font(.callout).opacity(0.9)
                }
                if let today = report.today {
                    Text("H:\(store.units.temperatureString(today.high, withUnit: true))  L:\(store.units.temperatureString(today.low, withUnit: true))")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                WeatherSymbol(condition: report.current.condition, isDay: report.current.isDay, size: 34)
                Text(store.units.temperatureString(report.current.temperature, withUnit: true))
                    .font(.system(size: 50, weight: .thin))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
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
                    Text(store.units.temperatureString(hour.temperature, withUnit: true))
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                    // Columns are named by the hour's END time (Brian, Oct 17), like the rain line.
                    // A rain icon always shows its % (one cutoff, `HourlyDisplay`).
                    let pop = HourlyDisplay.popText(hour)
                    Text(pop ?? " ").font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.popBlue)
                        .accessibilityHidden(pop == nil)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
        .menuGlass()
    }

    static let popBlue = Color(red: 0.55, green: 0.80, blue: 1.0)

    /// Wind, humidity, UV, air quality, sunrise/sunset and pressure in a 3 × 2 grid of small tiles.
    private func conditionsGrid(_ report: WeatherReport) -> some View {
        let c = report.current
        let tz = report.timeZone
        let now = Date()
        let gust = Briefing.peak(report.hourly.compactMap { h in h.windGust.map { (h.time, $0) } }, from: c.time, hours: 24)
        var tiles: [(String, String, String, String)] = []  // symbol, title, value, caption
        tiles.append(("wind", "Wind", store.units.speedString(c.windSpeed),
                      // The gust is the highest in the next 24 h, and says so (it read as the current gust).
                      c.windDirection.map { "from \(Compass.abbreviation($0))" + (gust.map { " · " + MenuSummary.gustCaption(store.units.speedString($0.value)) } ?? "") }
                        ?? (gust.map { MenuSummary.gustCaption(store.units.speedString($0.value)) } ?? "")))
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
                    // The wind caption is the longest ("from WNW · 24-h peak gust 100 km/h"). Three lines
                    // plus a small shrink keep the whole label inside the cell.
                    Text(t.3.isEmpty ? " " : t.3).font(.caption2).opacity(0.85).lineLimit(3).minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                .menuGlass(cornerRadius: 14, padding: 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The other saved locations, collapsed by default; one tap opens a city in the main window. A row
    /// whose data is stale is dimmed and says how old it is (they refresh on open when stale).
    @ViewBuilder
    private func otherLocations(_ report: WeatherReport) -> some View {
        let others = store.allLocations.filter { $0.id != report.location.id }.prefix(5)
        if !others.isEmpty {
            VStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { citiesExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Other cities").font(.callout.weight(.medium))
                        Text("\(others.count)").font(.caption.weight(.semibold)).opacity(0.7)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.8)
                            .rotationEffect(.degrees(citiesExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(citiesExpanded ? "Hide other cities" : "Show other cities")
                if citiesExpanded {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 2) {
                            ForEach(Array(others)) { location in
                                cityRow(location, now: context.date)
                            }
                        }
                    }
                }
            }
            .menuGlass(padding: 4)
        }
    }

    private func cityRow(_ location: WeatherLocation, now: Date) -> some View {
        let r = store.reports[location.id]
        let age = r.flatMap { MenuSummary.rowAge($0, now: now, staleAfter: store.staleDataAge) }
        return Button {
            store.selectedID = location.id
            AppExit.showMainWindow(); GlobalHotkey.closePanel()
            NSApp.activate()
        } label: {
            HStack(spacing: 8) {
                Text(location.isCurrentLocation ? "My Location" : location.name).lineLimit(1)
                Spacer()
                if let age {
                    Label(age, systemImage: "clock").labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        .help("Data from \(r.map { Fmt.dataTime($0.dataAsOf) } ?? "")")
                }
                if let r { WeatherSymbol(condition: r.current.condition, isDay: r.current.isDay, size: 13) }
                Text(store.units.temperatureString(r?.current.temperature, withUnit: true)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.callout)
            .opacity(age == nil ? 1 : 0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    // Rain chance on the day's row, same rule as the hourly row.
                    Text(HourlyDisplay.popText(day) ?? "").font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.popBlue)
                        .frame(width: 30, alignment: .leading)
                    Text(store.units.temperatureString(day.low, withUnit: true)).opacity(0.8)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 50, alignment: .trailing)
                    TemperatureRangeBar(rangeLow: low, rangeHigh: high, low: day.low, high: day.high)
                    Text(store.units.temperatureString(day.high, withUnit: true))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 50, alignment: .trailing)
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
                    CGPoint(x: w * CGFloat(i) / CGFloat(max(samples.count - 1, 1)), y: h - h * CGFloat(NowcastCurve.miniLevel(s.rate) / 3))
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
        .accessibilityLabel(MenuSummary.rainTiming(report, now: Date(), hourLabel: { Fmt.hour($0, report.timeZone) }) ?? "Rain chart")
    }
}

enum DropdownShape {
    /// Outer corners of the dropdown (MenuBarExtra panel and hotkey panel), Brian's 22 pt.
    static let radius: CGFloat = 22
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension View {
    /// The dropdown's surface: one tinted Liquid Glass layer on macOS 26+, the sky gradient with its
    /// black wash before that. Either way clipped to 22 pt corners; the window itself is transparent
    /// (DropdownWindowConfigurator), so these are the corners you see.
    @ViewBuilder
    func dropdownSurface(report: WeatherReport?) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(SkyPalette.glassTint(for: report)), in: DropdownShape.shape)
                .clipShape(DropdownShape.shape)
        } else {
            self.background {
                // Black wash keeps white text ≥ 4.5:1 on every sky (T6; tested via SkyColors.dropdownScrim).
                ZStack {
                    SkyPalette.gradient(for: report)
                    Color.black.opacity(SkyColors.dropdownScrim)
                }
            }
            .clipShape(DropdownShape.shape)
        }
    }

    /// Dropdown card: Liquid Glass on macOS 26 and later, a frosted material on older systems (polish 3).
    /// Static (no animation), so it costs nothing while the dropdown just sits open.
    @ViewBuilder
    func menuGlass(cornerRadius: CGFloat = 18, padding: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // Build 57: the whole dropdown is one Liquid Glass surface; cards are flat on it (no glass
            // on glass, per Apple's guidance and the spec).
            self.padding(padding)
                .background(shape.fill(.white.opacity(0.08)))
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
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

/// 28 pt icon button for the dropdown footer (build 35).
private struct FooterIcon: View {
    let symbol: String, help: String, action: () -> Void
    init(_ symbol: String, help: String, action: @escaping () -> Void) { self.symbol = symbol; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
