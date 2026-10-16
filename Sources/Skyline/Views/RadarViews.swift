import SwiftUI
import SkylineCore

/// Apple-Weather-style map module: compact, animates inline, expands in place to fill the detail area.
struct RadarCard: View {
    let location: WeatherLocation
    let pinText: String?
    var alerts: [WeatherAlert] = []
    var namespace: Namespace.ID
    @Environment(WeatherStore.self) private var store
    @AppStorage(RadarOpacity.key) private var opacity = RadarOpacity.defaultValue

    var body: some View {
        let radar = store.radar
        let expanded = store.radarExpanded
        Card(title: "Precipitation", systemImage: "umbrella.fill") {
            ZStack {
                RadarMapView(playback: radar, center: location.coordinate, frames: radar.frames,
                             maxNativeZoom: radar.provider.maximumNativeZoom, interactive: false,
                             spanDegrees: 3.2, opacity: opacity, pinText: pinText,
                             followsPlayback: !expanded, reportsProgress: !expanded,
                             alerts: alerts, focusedAlertID: nil)
                    .allowsHitTesting(false)
                // Whole map is a button, like Apple's map tile.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { expand() }
                VStack {
                    HStack {
                        Spacer()
                        CircleButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand map") { expand() }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        RadarPlayButton(radar: radar, compact: true)
                        RadarTimeLabel(radar: radar, timeZone: location.timeZone, compact: true)
                        Spacer()
                        RadarOpacityControl(opacity: $opacity, compact: true)
                    }
                }
                .padding(8)
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .matchedGeometryEffect(id: "radar-map", in: namespace, isSource: !expanded)
        }
        .task(id: location.id) { radar.configure(for: location) }
    }

    private func expand() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            store.activeModule = nil
            store.radarExpanded = true
        }
    }
}

/// The always-visible radar of the wide layout: same map UI as the expanded view, no autoplay
/// (an idle window stays at ~0 % CPU), and its button hides/shows the forecast column instead.
struct RadarPanel: View {
    let location: WeatherLocation
    let pinText: String?
    var alerts: [WeatherAlert] = []
    var mapOverscan: CGFloat = 0
    @Namespace private var unused

    var body: some View {
        ExpandedRadarView(location: location, pinText: pinText, alerts: alerts, namespace: unused, isPanel: true,
                          mapOverscan: mapOverscan)
    }
}

/// The expanded map filling the detail area (not a window or sheet).
struct ExpandedRadarView: View {
    let location: WeatherLocation
    let pinText: String?
    var alerts: [WeatherAlert] = []
    var namespace: Namespace.ID
    var isPanel = false
    /// Points the map extends past each side of the panel (clipped). The wide layout passes half the
    /// forecast column's width while it is shown, so the MKMapView keeps the same size whether or not
    /// the column is visible: toggling it never resizes the map (resizes were the memory-peak driver).
    var mapOverscan: CGFloat = 0
    @Environment(WeatherStore.self) private var store
    @AppStorage(RadarOpacity.key) private var opacity = RadarOpacity.defaultValue
    @State private var selectedAlert: WeatherAlert?
    @State private var recenterToken = 0

    var body: some View {
        let radar = store.radar
        ZStack {
            // The map sits in the background so a horizontal overscan can make it wider than the panel
            // without affecting layout; the clip shape trims it. See `mapOverscan`.
            Color.clear
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if isPanel {
                        CircleButton(systemImage: store.radarExpanded ? "sidebar.trailing" : "arrow.up.left.and.arrow.down.right",
                                     help: store.radarExpanded ? "Show the forecast column (Esc)" : "Give the map the whole window") {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { store.radarExpanded.toggle() }
                        }
                        .keyboardShortcut(store.radarExpanded ? KeyboardShortcut.cancelAction : nil)
                    } else {
                        CircleButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Collapse map (Esc)") { collapse() }
                            .keyboardShortcut(.cancelAction)
                    }
                    CircleButton(systemImage: "location.fill", help: "Center on \(location.isCurrentLocation ? "me" : location.name)") {
                        recenterToken += 1
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.isCurrentLocation ? "My Location" : location.name).font(.headline)
                        Text(alerts.isEmpty ? "Precipitation" : "Precipitation · \(alerts.count) alert\(alerts.count == 1 ? "" : "s") outlined")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
                        // Same rain-timing string as the menu bar (MenuSummary / nowcast) — not from HRRR tiles.
                        if let forecast = MenuSummary.radarForecastLine(
                            store.reports[location.id], now: Date(),
                            hourLabel: { Fmt.hour($0, location.timeZone) }) {
                            Text("Forecast · \(forecast)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Glass.secondaryText)
                                .accessibilityLabel("Forecast")
                                .accessibilityValue(forecast)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassChip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    RadarOptions(radar: radar, opacity: $opacity)
                }
                .padding(12)
                Spacer()
                HStack(alignment: .bottom) {
                    RadarLegend(provider: radar.provider, layer: radar.layer,
                                showsForecastNote: radar.hasForecastFrames,
                                showingForecastFrame: radar.currentFrame?.isForecast == true)
                        .padding(10)
                        .glassChip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    if radar.currentFrame?.isForecast == true {
                        Text("FORECAST · HRRR")
                            .font(.caption2.weight(.bold))
                            .tracking(0.6)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color(red: 0.92, green: 0.86, blue: 1.0))
                            .background(Capsule().fill(Color(red: 0.35, green: 0.22, blue: 0.55).opacity(0.85)))
                            .overlay(Capsule().stroke(Color(red: 0.78, green: 0.62, blue: 1.0), lineWidth: 1))
                            .accessibilityLabel("Forecast, HRRR model")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                RadarTimeline(radar: radar, timeZone: location.timeZone)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .background {
            RadarMapView(playback: radar, center: location.coordinate, frames: radar.frames,
                         maxNativeZoom: radar.provider.maximumNativeZoom, interactive: true,
                         spanDegrees: radar.provider == .nexrad ? 5 : 9, opacity: opacity,
                         pinText: pinText, followsPlayback: true, reportsProgress: true,
                         alerts: alerts, focusedAlertID: store.focusedAlertID,
                         horizontalOverscan: mapOverscan,
                         onAlertSelect: { id in
                             if let alert = alerts.first(where: { $0.id == id }) {
                                 selectedAlert = alert
                             }
                         },
                         recenterToken: recenterToken)
                .padding(.horizontal, -mapOverscan)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Match clip for hit testing (clipShape alone does not); AppKit overscan is gated in hitTest(_:).
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // No matched-geometry morph from the card: it resized the MKMapView on every animation frame
        // (~100 MB of transient Metal/IOSurface memory per expand). The overlay scales+fades in instead
        // (a render transform, no re-layout of the map).
        .modifier(MatchedIfExpanded(enabled: false, namespace: namespace, isSource: store.radarExpanded))
        .foregroundStyle(.white)
        .sheet(item: $selectedAlert) { alert in
            AlertDetailView(alert: alert, timeZone: location.timeZone) {
                store.showAlertOnMap(alert, wideLayout: true)
            }
        }
        .task(id: location.id) {
            // One index load (L7): configure doesn't start its own when we await one here.
            radar.configure(for: location, load: false)
            await radar.loadFrames()
            // Expanding is an explicit "show me the loop"; the always-on panel waits for Space/Play.
            if !isPanel, radar.frames.count > 1 { radar.setPlaying(true) }
        }
    }

    private func collapse() {
        store.radar.setPlaying(false) // the compact tile stays still (and free) unless the user hits play
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            store.radarExpanded = false
        }
    }
}

private struct MatchedIfExpanded: ViewModifier {
    let enabled: Bool
    let namespace: Namespace.ID
    let isSource: Bool
    func body(content: Content) -> some View {
        if enabled { content.matchedGeometryEffect(id: "radar-map", in: namespace, isSource: isSource) } else { content }
    }
}

struct CircleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .glassChip(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Play/pause for the radar loop. While the loop is still loading, Play is accepted and *queued*: the
/// button shows a progress ring and "Starts when loaded" instead of flipping to Pause and doing nothing (R2).
struct RadarPlayButton: View {
    let radar: RadarPlayback
    var compact = false

    var body: some View {
        let size: CGFloat = compact ? 30 : 34
        Button { radar.togglePlay() } label: {
            ZStack {
                if radar.isWaitingToPlay {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.04, radar.progress))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "hourglass").font(.system(size: compact ? 11 : 13, weight: .bold))
                } else {
                    Image(systemName: radar.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 12 : 16, weight: .bold))
                }
            }
            .frame(width: size, height: size)
            .background {
                if compact { Circle().fill(Glass.chipTint).background(.ultraThinMaterial, in: Circle()) }
                else { Circle().fill(.white.opacity(0.18)) }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(radar.frames.count < 2)
        .help(radar.isWaitingToPlay ? "Starts when the loop has loaded (click to cancel)"
              : radar.isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

struct RadarTimeLabel: View {
    let radar: RadarPlayback
    let timeZone: TimeZone
    var compact = false

    var body: some View {
        if !radar.isReady && !radar.frames.isEmpty {
            // Loading is a state you can't miss (R2): an accent-tinted chip with a bar, saying what
            // happens next, instead of a small grey "Loading 30%".
            let pct = Int((radar.progress * 100).rounded())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(radar.isWaitingToPlay ? "Loading loop · starts at 100%" : "Loading radar")
                    Spacer(minLength: 4)
                    Text("\(pct)%").monospacedDigit()
                }
                ProgressView(value: radar.progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: compact ? 130 : 170)
            }
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.55)))
            .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1))
            .fixedSize()
        } else if let frame = radar.currentFrame {
            Text(Self.label(frame, frames: radar.frames, nowIndex: radar.nowIndex, layer: radar.layer, timeZone: timeZone))
                .monospacedDigit()
                .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassChip(Capsule())
                // Model forecast frames are tinted and say so: they look like radar but aren't (T12).
                .overlay {
                    if frame.isForecast {
                        Capsule().stroke(Color(red: 0.78, green: 0.62, blue: 1.0), lineWidth: 1.5)
                    }
                }
                .help(frame.isForecast ? "Model forecast (NOAA HRRR via Iowa Environmental Mesonet), not observed radar" : "")
        }
    }

    static func label(_ frame: RadarFrame, frames: [RadarFrame], nowIndex: Int, layer: RadarLayer, timeZone: TimeZone) -> String {
        let time = Fmt.time(frame.time, timeZone)
        if layer.isRainfallTotal { return "\(layer.label) · as of \(time)" }
        guard frames.indices.contains(nowIndex) else { return time }
        let minutes = Int((frame.time.timeIntervalSince(frames[nowIndex].time) / 60).rounded())
        if frame.isForecast { return "\(time) · +\(minutes) min · Forecast" }
        return minutes == 0 ? "\(time) · Now" : "\(time) · −\(-minutes) min"
    }
}

/// Persisted radar-layer opacity. Default 60 % (normal source-over compositing since batch 2, so the
/// old screen-blend value doesn't carry over: a new key gives everyone the new default once), and it
/// goes down to 5 % to check a road or town under heavy rain.
enum RadarOpacity {
    static let key = "radarOpacity.v2"
    static let defaultValue = 0.6
    static let range: ClosedRange<Double> = 0.05...1.0
}

/// Opacity slider for the radar layer: compact capsule in the map tile, labelled in the expanded map.
struct RadarOpacityControl: View {
    @Binding var opacity: Double
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.2.layers.3d.top.filled")
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
            Slider(value: $opacity, in: RadarOpacity.range)
                .controlSize(compact ? .mini : .small)
                .frame(width: compact ? 80 : 130)
            Text("\(Int((opacity * 100).rounded()))%")
                .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.semibold))
                .frame(width: compact ? 30 : 36, alignment: .trailing)
        }
        .padding(.horizontal, compact ? 8 : 0)
        .padding(.vertical, compact ? 4 : 0)
        .background {
            if compact { Capsule().fill(Glass.chipTint).background(.ultraThinMaterial, in: Capsule()) }
        }
        .help("Radar opacity: lower it to see the map underneath")
    }
}

struct RadarOptions: View {
    let radar: RadarPlayback
    @Binding var opacity: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Picker("Source", selection: Binding(get: { radar.provider }, set: { radar.switchProvider($0) })) {
                ForEach(RadarProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            if radar.provider == .nexrad && !radar.inCONUS {
                // QA 4: say why there are holes instead of silently showing a US-only mosaic.
                Text("NEXRAD covers the US only. RainViewer shows this area.")
                    .font(.caption).foregroundStyle(.yellow)
                    .frame(width: 280, alignment: .trailing)
            }
            if radar.provider == .nexrad && radar.inCONUS {
                Picker("Layer", selection: Binding(get: { radar.layer }, set: { radar.setLayer($0) })) {
                    ForEach(RadarLayer.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .help("Radar loop, or rainfall totals for the last hour / 24 hours (MRMS)")
            }
            if radar.provider == .nexrad && radar.inCONUS && radar.layer == .reflectivity {
                RadarSitePicker(radar: radar)
            }
            if radar.provider == .nexrad && radar.layer == .reflectivity {
                Toggle("Future radar (model)", isOn: Binding(get: { radar.showsFuture }, set: { radar.setShowsFuture($0) }))
                    .toggleStyle(.checkbox)
                    .font(.caption.weight(.semibold))
                    .help("Adds the next 2 hours from the NOAA HRRR model after “Now”. It's a forecast, not radar.")
                HStack(spacing: 6) {
                    Text("Loop").font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
                    Picker("Loop length", selection: Binding(get: { radar.range }, set: { radar.setRange($0) })) {
                        ForEach(RadarRange.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                .help("How far back the radar loop goes")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("Radar opacity").font(.caption2.weight(.semibold)).opacity(0.75)
                RadarOpacityControl(opacity: $opacity)
            }
            if let error = radar.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .glassChip(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RadarTimeline: View {
    let radar: RadarPlayback
    let timeZone: TimeZone
    @Environment(WeatherStore.self) private var store
    @State private var showCallout = false

    var body: some View {
        HStack(spacing: 14) {
            RadarPlayButton(radar: radar)

            VStack(spacing: 4) {
                Slider(value: Binding(get: { Double(radar.index) },
                                      set: { radar.crossfade = false; radar.scrub(to: Int($0.rounded())) }),
                       in: 0...Double(max(radar.frames.count - 1, 1)),
                       onEditingChanged: { editing in
                           radar.crossfade = !editing
                           if store.isScrubbing != editing { store.isScrubbing = editing }
                           radar.isScrubbingRadar = editing
                           showCallout = editing
                       })
                    .disabled(radar.frames.count < 2)
                    // While frames load, the track can't look finished: the slider is dimmed and a
                    // progress bar fills underneath it (R2).
                    .opacity(radar.isReady ? 1 : 0.45)
                    .overlay(alignment: .bottom) {
                        if !radar.isReady, !radar.frames.isEmpty {
                            ProgressView(value: radar.progress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .padding(.horizontal, 6)
                                .offset(y: 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // Hatched forecast segment + "Now" tick (T12 / radar-features §4).
                        if radar.hasForecastFrames, radar.frames.count > 1 {
                            GeometryReader { geo in
                                let track = geo.size.width - 16
                                let nowFrac = Double(radar.nowIndex) / Double(radar.frames.count - 1)
                                let x0 = 8 + track * nowFrac
                                ForecastHatch(width: max(0, geo.size.width - 8 - x0), height: 8)
                                    .position(x: x0 + max(0, geo.size.width - 8 - x0) / 2,
                                              y: geo.size.height / 2)
                                Rectangle().fill(.white.opacity(0.85))
                                    .frame(width: 2, height: 14)
                                    .position(x: x0, y: geo.size.height / 2)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        // Same callout as the charts while scrubbing (drawn, never measured back into state).
                        if showCallout, let frame = radar.currentFrame, radar.frames.count > 1 {
                            GeometryReader { geo in
                                let f = Double(radar.index) / Double(radar.frames.count - 1)
                                ScrubCallout(title: Fmt.time(frame.time, timeZone))
                                    .position(x: 8 + (geo.size.width - 16) * f, y: -18)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.leftArrow) { radar.crossfade = false; radar.scrub(to: radar.index - 1); radar.crossfade = true; return .handled }
                    .onKeyPress(.rightArrow) { radar.crossfade = false; radar.scrub(to: radar.index + 1); radar.crossfade = true; return .handled }
                HStack {
                    Text(radar.frames.first.map { Fmt.time($0.time, timeZone) } ?? "")
                    Spacer()
                    Text("← → step · Space play").opacity(0.8)
                    Spacer()
                    if radar.hasForecastFrames, let last = radar.frames.last {
                        Text("Forecast to \(Fmt.time(last.time, timeZone))")
                            .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 1.0))
                    } else {
                        Text("Now")
                    }
                }
                .font(.caption2)
                .opacity(0.75)
            }
            RadarTimeLabel(radar: radar, timeZone: timeZone)
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassChip(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Diagonal hatch over the forecast half of the timeline scrubber.
private struct ForecastHatch: View {
    var width: CGFloat
    var height: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let color = Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.55)
            var path = Path()
            let step: CGFloat = 5
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.78, green: 0.62, blue: 1.0).opacity(0.12)))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .allowsHitTesting(false)
    }
}

/// Legend. NEXRAD uses the standard NWS reflectivity scale (what the IEM N0Q tiles are coloured with),
/// labelled in dBZ with plain-English intensity. Forecast frames switch to the HRRR REFP precip-type ramp.
struct RadarLegend: View {
    let provider: RadarProvider
    var layer: RadarLayer = .reflectivity
    var showsForecastNote = false
    /// When true, show REFP rain/snow/mix colours instead of the dBZ ramp.
    var showingForecastFrame = false
    @Environment(WeatherStore.self) private var store

    static let nexradStops: [(dbz: Int, color: Color)] = [
        (5, Color(red: 0.25, green: 0.91, blue: 0.91)), (10, Color(red: 0.0, green: 0.62, blue: 0.96)),
        (15, Color(red: 0.0, green: 0.0, blue: 0.96)), (20, Color(red: 0.0, green: 0.96, blue: 0.0)),
        (25, Color(red: 0.0, green: 0.78, blue: 0.0)), (30, Color(red: 0.0, green: 0.56, blue: 0.0)),
        (35, Color(red: 1.0, green: 1.0, blue: 0.0)), (40, Color(red: 0.91, green: 0.75, blue: 0.0)),
        (45, Color(red: 1.0, green: 0.56, blue: 0.0)), (50, Color(red: 1.0, green: 0.0, blue: 0.0)),
        (55, Color(red: 0.84, green: 0.0, blue: 0.0)), (60, Color(red: 0.75, green: 0.0, blue: 0.0)),
        (65, Color(red: 1.0, green: 0.0, blue: 1.0)), (70, Color(red: 0.6, green: 0.33, blue: 0.79)),
    ]

    var body: some View {
        if layer.isRainfallTotal { rainfallLegend }
        else if showingForecastFrame && provider == .nexrad { forecastLegend }
        else { reflectivityLegend }
    }

    private var forecastLegend: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("FORECAST · PRECIP TYPE")
                .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            HStack(spacing: 8) {
                ForEach(IEMHRRR.legendTypes, id: \.name) { stop in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: Double((stop.hex >> 16) & 0xFF) / 255,
                                        green: Double((stop.hex >> 8) & 0xFF) / 255,
                                        blue: Double(stop.hex & 0xFF) / 255))
                            .frame(width: 12, height: 8)
                        Text(stop.name).font(.system(size: 10, weight: .medium))
                    }
                }
            }
            Text("NOAA HRRR precip type via Iowa Environmental Mesonet")
                .font(.system(size: 10)).foregroundStyle(Glass.secondaryText)
        }
    }

    /// IEM's MRMS ramp, labelled in the user's precipitation unit (L21).
    private var rainfallLegend: some View {
        let stops = IEMMRMS.legendStops
        let inches = store.units.precipitation == .inches
        return VStack(alignment: .leading, spacing: 3) {
            Text(layer == .rain1h ? "RAIN, LAST HOUR" : "RAIN, LAST 24 HOURS")
                .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            HStack(spacing: 0) {
                ForEach(stops.indices, id: \.self) { i in
                    let hex = stops[i].hex
                    Rectangle().fill(Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                                           blue: Double(hex & 0xFF) / 255))
                        .frame(width: 22, height: 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack(spacing: 0) {
                ForEach([0, 2, 4, 6, 8], id: \.self) { i in
                    let mm = stops[i].mm
                    Text(inches ? String(format: mm / 25.4 < 1 ? "%.1f″" : "%.0f″", mm / 25.4) : "\(Int(mm)) mm")
                        .frame(width: 44, alignment: .leading)
                }
            }
            .font(.system(size: 10, weight: .medium)).monospacedDigit()
            Text("MRMS (radar + gauges) via Iowa Environmental Mesonet").font(.system(size: 10)).foregroundStyle(Glass.secondaryText)
        }
    }

    private var reflectivityLegend: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider == .nexrad ? "REFLECTIVITY (dBZ)" : "PRECIPITATION")
                .font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
            if provider == .nexrad {
                HStack(spacing: 0) {
                    ForEach(Self.nexradStops, id: \.dbz) { stop in
                        Rectangle().fill(stop.color).frame(width: 14, height: 8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                HStack(spacing: 0) {
                    ForEach([5, 20, 35, 50, 65], id: \.self) { v in
                        Text("\(v)").frame(width: 42, alignment: .leading)
                    }
                }
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                HStack(spacing: 0) {
                    Text("Light").frame(width: 70, alignment: .leading)
                    Text("Moderate").frame(width: 56, alignment: .leading)
                    Text("Heavy · hail").frame(width: 70, alignment: .leading)
                }
                .font(.system(size: 10)).foregroundStyle(Glass.secondaryText)
            } else {
                LinearGradient(colors: rainViewerColors, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 196, height: 8)
                    .clipShape(Capsule())
                HStack { Text("Light"); Spacer(); Text("Heavy") }
                    .font(.caption2).frame(width: 196).foregroundStyle(Glass.secondaryText)
            }
            Text(provider.attribution).font(.system(size: 10)).foregroundStyle(Glass.secondaryText)
            if showsForecastNote, provider == .nexrad {
                Text("After “Now”: NOAA HRRR precip-type forecast via IEM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 1.0))
            }
        }
    }

    private var rainViewerColors: [Color] {
        [Color(red: 0.55, green: 0.8, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.95),
         Color(red: 1.0, green: 0.85, blue: 0.0), Color(red: 1.0, green: 0.3, blue: 0.0),
         Color(red: 0.75, green: 0.0, blue: 0.4)]
    }
}

/// NEXRAD station picker: nearest site (default), the national composite, or any lower-48 WSR-88D.
struct RadarSitePicker: View {
    let radar: RadarPlayback

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Text("Site").font(.caption2.weight(.semibold)).foregroundStyle(Glass.secondaryText)
                Picker("Radar site", selection: Binding(get: { radar.siteChoice }, set: { radar.setSiteChoice($0) })) {
                    Text(radar.nearestStation.map { "Nearest (\($0.icao))" } ?? "Nearest").tag(RadarSiteChoice.auto)
                    Text("National composite").tag(RadarSiteChoice.composite)
                    Divider()
                    ForEach(NexradStation.conus) { Text($0.label).tag(RadarSiteChoice.site($0.id)) }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            .help("Single-site NEXRAD (sharper, updates every 4–6 min) or the national mosaic")
            if let note = radar.siteNote {
                Text(note).font(.caption).foregroundStyle(.yellow).frame(width: 280, alignment: .trailing)
            }
        }
    }
}
