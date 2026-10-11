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
                        CircleButton(systemImage: radar.isPlaying ? "pause.fill" : "play.fill",
                                     help: radar.isPlaying ? "Pause" : "Play radar loop") { radar.togglePlay() }
                            .disabled(radar.frames.count < 2)
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
        .task(id: location.id) { radar.configure(for: location.coordinate) }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.isCurrentLocation ? "My Location" : location.name).font(.headline)
                        Text(alerts.isEmpty ? "Precipitation" : "Precipitation · \(alerts.count) alert\(alerts.count == 1 ? "" : "s") outlined")
                            .font(.caption).foregroundStyle(Glass.secondaryText)
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
                    RadarLegend(provider: radar.provider)
                        .padding(10)
                        .glassChip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
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
                         horizontalOverscan: mapOverscan)
                .padding(.horizontal, -mapOverscan)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // No matched-geometry morph from the card: it resized the MKMapView on every animation frame
        // (~100 MB of transient Metal/IOSurface memory per expand). The overlay scales+fades in instead
        // (a render transform, no re-layout of the map).
        .modifier(MatchedIfExpanded(enabled: false, namespace: namespace, isSource: store.radarExpanded))
        .foregroundStyle(.white)
        .task(id: location.id) {
            radar.configure(for: location.coordinate)
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

struct RadarTimeLabel: View {
    let radar: RadarPlayback
    let timeZone: TimeZone
    var compact = false

    var body: some View {
        Group {
            if !radar.isReady && !radar.frames.isEmpty {
                HStack(spacing: 6) {
                    ProgressView(value: radar.progress).progressViewStyle(.circular).controlSize(.mini)
                    Text("Loading \(Int(radar.progress * 100))%")
                }
            } else if let frame = radar.currentFrame {
                Text(label(frame)).monospacedDigit()
            }
        }
        .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassChip(Capsule())
    }

    private func label(_ frame: RadarFrame) -> String {
        let time = Fmt.time(frame.time, timeZone)
        guard let last = radar.frames.last else { return time }
        let minutes = Int((last.time.timeIntervalSince(frame.time) / 60).rounded())
        return minutes == 0 ? "\(time) · Now" : "\(time) · −\(minutes) min"
    }
}

/// Persisted radar-layer opacity (default ~70 % so roads, labels and coastlines show through).
enum RadarOpacity {
    static let key = "radarOpacity"
    static let defaultValue = 0.7
    static let range: ClosedRange<Double> = 0.2...1.0
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
            if radar.provider == .nexrad {
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
            Button { radar.togglePlay() } label: {
                Image(systemName: radar.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.18), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(radar.frames.count < 2)
            .help(radar.isPlaying ? "Pause (Space)" : "Play (Space)")

            VStack(spacing: 4) {
                Slider(value: Binding(get: { Double(radar.index) },
                                      set: { radar.crossfade = false; radar.scrub(to: Int($0.rounded())) }),
                       in: 0...Double(max(radar.frames.count - 1, 1)),
                       onEditingChanged: { editing in
                           radar.crossfade = !editing
                           if store.isScrubbing != editing { store.isScrubbing = editing }
                           showCallout = editing
                       })
                    .disabled(radar.frames.count < 2)
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
                    Text("Now")
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

/// Legend. NEXRAD uses the standard NWS reflectivity scale (what the IEM N0Q tiles are coloured with),
/// labelled in dBZ with plain-English intensity.
struct RadarLegend: View {
    let provider: RadarProvider

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
                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                HStack(spacing: 0) {
                    Text("Light").frame(width: 70, alignment: .leading)
                    Text("Moderate").frame(width: 56, alignment: .leading)
                    Text("Heavy · hail").frame(width: 70, alignment: .leading)
                }
                .font(.system(size: 9)).foregroundStyle(Glass.secondaryText)
            } else {
                LinearGradient(colors: rainViewerColors, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 196, height: 8)
                    .clipShape(Capsule())
                HStack { Text("Light"); Spacer(); Text("Heavy") }
                    .font(.caption2).frame(width: 196).foregroundStyle(Glass.secondaryText)
            }
            Text(provider.attribution).font(.system(size: 9)).foregroundStyle(Glass.secondaryText)
        }
    }

    private var rainViewerColors: [Color] {
        [Color(red: 0.55, green: 0.8, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.95),
         Color(red: 1.0, green: 0.85, blue: 0.0), Color(red: 1.0, green: 0.3, blue: 0.0),
         Color(red: 0.75, green: 0.0, blue: 0.4)]
    }
}
