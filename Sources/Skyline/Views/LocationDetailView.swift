import SwiftUI
import SkylineCore

/// Detail area.
///
/// * Wide windows (detail ≥ 1000 pt, hysteresis 960/1000): a scrolling forecast column next to the
///   sidebar and a large always-visible radar on the far right (the window reads as three columns).
///   Module detail opens as an inspector in place of the forecast column.
/// * Narrow windows: one scrolling column with the inline radar card (expand button) and module
///   detail as a sheet-style panel.
///
/// The width breakpoint is applied on the next main-queue turn and only when it actually flips, so a
/// geometry change can never write observed state inside a layout pass.
struct LocationDetailView: View {
    let location: WeatherLocation
    @Environment(WeatherStore.self) private var store
    @Namespace private var radarNamespace
    @State private var isWide = true
    @State private var widthBox = WidthBox()
    @FocusState private var contentFocused: Bool

    static let wideOn: CGFloat = 1000
    static let wideOff: CGFloat = 960

    var body: some View {
        let report = store.reports[location.id]
        ZStack {
            LivingBackground(report: report)
            if let report {
                if isWide { wideLayout(report) } else { narrowLayout(report) }
            } else if let error = store.errors[location.id] {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 44))
                    Text("Couldn’t load weather for \(location.name)").font(.title3)
                    Text(error).font(.caption).foregroundStyle(Glass.secondaryText)
                    Button("Try Again") { Task { await store.load(location, force: true) } }
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        // Old or offline data says so (overlay: never resizes the forecast column or the map).
        .overlay(alignment: .top) {
            if let report, store.isStale(report) {
                StaleDataBanner(report: report, offline: store.isOffline(report), error: store.errors[location.id],
                                isLoading: store.isLoading(location)) {
                    Task { await store.load(location, force: true) }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            if UserDefaults.standard.bool(forKey: "SkylineLogLayout") { NSLog("SkylineLayout width=%.0f wide=%d", w, isWide ? 1 : 0) }
            // Record the latest width (unobserved), then decide on the next main-queue turn from the
            // *latest* width, so a stale early value (e.g. 100 pt while the window opens) can't win.
            widthBox.width = w
            guard !widthBox.pending else { return }
            widthBox.pending = true
            DispatchQueue.main.async {
                widthBox.pending = false
                let latest = widthBox.width
                let wide = isWide ? latest >= Self.wideOff : latest >= Self.wideOn
                if wide != isWide { isWide = wide }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.isWideLayout, isWide)
        .navigationTitle(location.isCurrentLocation ? "My Location" : location.name)
        .task(id: location.id) { await store.load(location) }
        .onChange(of: location.id) { _, _ in
            store.radarExpanded = false; store.activeModule = nil; store.focusedAlertID = nil
        }
        // Keyboard: the detail area can take focus (⌘⇧F). Space (play/pause radar) is handled by an
        // in-app key monitor (AppActions.installSpaceShortcut) so it works without focus but never
        // while typing in the search field.
        .focusable()
        .focused($contentFocused)
        .focusEffectDisabled()
        .onChange(of: store.focusContentRequest) { _, _ in contentFocused = true }
    }

    // MARK: Wide

    private func wideLayout(_ report: WeatherReport) -> some View {
        let pin = store.units.temperatureString(report.current.temperature)
        let showColumn = !store.radarExpanded
        // Forecast column next to the sidebar, the large radar on the far right.
        // The forecast column is ALWAYS in the view tree (same identity), so opening/closing a module
        // detail or expanding the radar never rebuilds its ScrollView and the scroll position survives:
        // the detail is laid over it, and "expanded radar" collapses the slot to zero width (clipped)
        // while the column keeps its own fixed 420 pt layout inside.
        let detailOpen = store.activeModule != nil
        return HStack(spacing: 0) {
            ZStack(alignment: .top) {
                ForecastColumn(report: report, location: location, radarNamespace: radarNamespace,
                               showsRadarCard: false, onOpen: open)
                    .opacity(detailOpen ? 0 : 1)
                    .allowsHitTesting(!detailOpen)
                    .accessibilityHidden(detailOpen)
                if let selection = store.activeModule {
                    ModuleDetailView(report: report, selection: selection, inspector: true)
                        .id(selection.id + (selection.day.map { "\($0.timeIntervalSince1970)" } ?? ""))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(width: 420)
            .frame(width: showColumn ? 420 : 0, alignment: .leading)
            .clipped()
            .padding(.trailing, showColumn ? 14 : 0)
            // Memory: showing/hiding the column must not resize the MKMapView (each resize reallocates its
            // Metal drawables and reloads vector tiles: the stress-test peak driver). The radar panel
            // gives the map a matching overscan instead, and the layout change snaps (the column fades).
            .transaction(value: showColumn) { $0.animation = nil }
            .opacity(showColumn ? 1 : 0)
            .allowsHitTesting(showColumn)
            RadarPanel(location: location, pinText: pin, alerts: report.activeAlerts(),
                       mapOverscan: showColumn ? (420 + 14) / 2 : 0)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                .transaction(value: showColumn) { $0.animation = nil }
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    // MARK: Narrow

    /// The forecast column is the base view; the expanded radar and the module panel live in an
    /// overlay, so they can never resize the column (a tall panel used to grow the stack, shrink the
    /// scroll range and reset the scroll position) or change its identity.
    private func narrowLayout(_ report: WeatherReport) -> some View {
        ForecastColumn(report: report, location: location, radarNamespace: radarNamespace,
                       showsRadarCard: true, onOpen: open)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(store.radarExpanded ? 0 : 1)
            // No .scrollDisabled toggle: the overlay above takes the pointer instead.
            .allowsHitTesting(!store.radarExpanded && store.activeModule == nil)
            .overlay {
                ZStack {
                    if store.radarExpanded {
                        ExpandedRadarView(location: location, pinText: store.units.temperatureString(report.current.temperature),
                                          alerts: report.activeAlerts(), namespace: radarNamespace)
                            .padding(14)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            .zIndex(2)
                    }
                    if let selection = store.activeModule {
                        Color.black.opacity(0.45)
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
                }
            }
    }

    private func open(_ module: DetailModule, day: Date?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            store.activeModule = ModuleSelection(module: module, day: day)
        }
    }
}

/// Plain (unobserved) holder for the latest measured width; writing it never invalidates a view.
private final class WidthBox {
    var width: CGFloat = 0
    var pending = false
}

private struct IsWideLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when the detail area uses the wide radar + forecast-column layout.
    var isWideLayout: Bool {
        get { self[IsWideLayoutKey.self] }
        set { self[IsWideLayoutKey.self] = newValue }
    }
}

/// The scrolling forecast: hero (shrinks as you scroll), a pinned plain-English summary, alert banner,
/// next-hour rain (only when rain is due), hourly, daily, radar card (narrow only) and tiles.
struct ForecastColumn: View {
    let report: WeatherReport
    let location: WeatherLocation
    var radarNamespace: Namespace.ID
    let showsRadarCard: Bool
    let onOpen: (DetailModule, Date?) -> Void
    @Environment(WeatherStore.self) private var store

    var body: some View {
        let units = store.units
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                HeroView(report: report, units: units)
                    // Shrinks and fades as it scrolls under the pinned summary (no state writes).
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView).minY
                        let t = min(max(-y / 220, 0), 1)
                        return content
                            .scaleEffect(1 - 0.25 * t, anchor: .top)
                            .opacity(1 - Double(t) * 0.9)
                    }
                Section {
                    if !report.activeAlerts().isEmpty {
                        AlertBanner(alerts: report.activeAlerts(), timeZone: report.timeZone)
                    }
                    if Briefing.rainDueSoon(report, now: report.current.time) {
                        NowcastCard(report: report, units: units)
                    }
                    HourlyCard(report: report, units: units) { onOpen(.conditions, nil) }
                    DailyCard(report: report, units: units) { onOpen(.conditions, $0) }
                        .id(ScrollProbe.dailyID)
                    if showsRadarCard {
                        RadarCard(location: location, pinText: units.temperatureString(report.current.temperature),
                                  alerts: report.activeAlerts(), namespace: radarNamespace)
                    }
                    DetailTilesGrid(report: report, units: units) { onOpen($0, nil) }
                    SourcesFooter(report: report)
                } header: {
                    BriefingBar(report: report, units: units)
                }
            }
            .padding(.horizontal, showsRadarCard ? 22 : 0)
            .padding(.bottom, 26)
            // QA probe: the content's top in scroll-view space (= −offset) into an unobserved box.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { ScrollProbe.heroMinY = $0 }
        }
        .scrollIndicators(.never)
        .task {
            // Serve overscan hit-test scroll requests; also run the optional scroll-preservation QA.
            for _ in 0..<120 { // ~30 s
                if ScrollProbe.pendingScrollToDaily {
                    ScrollProbe.pendingScrollToDaily = false
                    proxy.scrollTo(ScrollProbe.dailyID, anchor: .top)
                }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { break }
            }
            await ScrollProbe.runIfRequested(store: store, report: report, proxy: proxy)
        }
        }
        .foregroundStyle(.white)
    }
}

/// QA hook `-SkylineScrollTest YES`: scrolls the forecast column to the 10-day card, opens and closes a
/// day's detail, expands and collapses the radar, and prints the offset before/after each step
/// (`[scrolltest] … PASS|FAIL`). With `-SkylineStressQuit YES` it quits afterwards. Inert otherwise.
@MainActor
enum ScrollProbe {
    static let dailyID = "forecast-daily"
    /// Hero's minY in the scroll view's coordinate space (= −offset). Plain static; never observed.
    static var heroMinY: CGFloat = 0
    /// Set by OverscanHitProbe; ForecastColumn scrolls to the 10-day card once, then clears it.
    static var pendingScrollToDaily = false
    private static var ran = false

    static func runIfRequested(store: WeatherStore, report: WeatherReport, proxy: ScrollViewProxy) async {
        // Serve a one-shot scroll request from the overscan hit-test probe (no observed state).
        if pendingScrollToDaily {
            pendingScrollToDaily = false
            proxy.scrollTo(dailyID, anchor: .top)
        }
        guard UserDefaults.standard.bool(forKey: "SkylineScrollTest"), !ran else { return }
        func log(_ s: String) { print("[scrolltest] \(s)"); fflush(stdout) }
        // Wait for the window/layout to settle; a column replaced meanwhile (wide↔narrow) cancels this.
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, !ran else { return }
        ran = true
        proxy.scrollTo(dailyID, anchor: .top)
        try? await Task.sleep(for: .seconds(1.5))
        let before = heroMinY
        store.activeModule = ModuleSelection(module: .conditions, day: report.daily.dropFirst().first?.date)
        try? await Task.sleep(for: .seconds(2))
        log(String(format: "duringDetail=%.0f", heroMinY))
        store.activeModule = nil
        try? await Task.sleep(for: .seconds(2))
        let afterDetail = heroMinY
        store.radarExpanded = true
        try? await Task.sleep(for: .seconds(2))
        store.radarExpanded = false
        try? await Task.sleep(for: .seconds(2))
        let afterRadar = heroMinY
        let ok = before < -100 && abs(afterDetail - before) < 2 && abs(afterRadar - before) < 2
        log(String(format: "before=%.0f afterDetail=%.0f afterRadar=%.0f %@", before, afterDetail, afterRadar, ok ? "PASS" : "FAIL"))
        if UserDefaults.standard.bool(forKey: "SkylineStressQuit") { NSApp.terminate(nil) }
    }
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
        // The pinned briefing (and the Next 2 Hours card) already say what the nowcast says, so the
        // hourly card leads with the day's forecast text and falls back to the nowcast.
        if let summary = report.today?.summary {
            return summary.split(separator: ".").prefix(2).joined(separator: ".") + "."
        }
        return report.nowcastSummary.map { $0 + "." }
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
            Text("Data from \(Fmt.dayTime(report.dataAsOf, .current)) · Weather data by Open-Meteo.com (CC BY 4.0)")
        }
        .font(.caption2)
        .multilineTextAlignment(.center)
        .opacity(0.7)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

/// Slim "Offline · showing data from 2:10 PM [Retry]" capsule over the top of the detail area.
struct StaleDataBanner: View {
    let report: WeatherReport
    let offline: Bool
    let error: String?
    let isLoading: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: offline ? "wifi.slash" : "clock.arrow.circlepath")
            Text((offline ? "Offline · showing data from " : "Showing data from ") + Fmt.dataTime(report.dataAsOf))
                .lineLimit(1)
            if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(.orange.opacity(0.7), lineWidth: 1))
        .help(error ?? "The forecast hasn’t been refreshed recently.")
    }
}
