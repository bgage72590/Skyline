import SwiftUI
import SkylineCore

/// Apple-Weather-style map module: compact, animates inline, expands in place to fill the detail area.
struct RadarCard: View {
    let location: WeatherLocation
    let pinText: String?
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
                             followsPlayback: !expanded, reportsProgress: !expanded)
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

/// The expanded map filling the detail area (not a window or sheet).
struct ExpandedRadarView: View {
    let location: WeatherLocation
    let pinText: String?
    var namespace: Namespace.ID
    @Environment(WeatherStore.self) private var store
    @AppStorage(RadarOpacity.key) private var opacity = RadarOpacity.defaultValue

    var body: some View {
        let radar = store.radar
        ZStack {
            RadarMapView(playback: radar, center: location.coordinate, frames: radar.frames,
                         maxNativeZoom: radar.provider.maximumNativeZoom, interactive: true,
                         spanDegrees: radar.provider == .nexrad ? 5 : 9, opacity: opacity,
                         pinText: pinText, followsPlayback: true, reportsProgress: true)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    CircleButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Collapse map (Esc)") { collapse() }
                        .keyboardShortcut(.cancelAction)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.isCurrentLocation ? "My Location" : location.name).font(.headline)
                        Text("Precipitation").font(.caption).opacity(0.8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                    RadarOptions(radar: radar, opacity: $opacity)
                }
                .padding(12)
                Spacer()
                HStack(alignment: .bottom) {
                    RadarLegend(provider: radar.provider)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                RadarTimeline(radar: radar, timeZone: location.timeZone)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .matchedGeometryEffect(id: "radar-map", in: namespace, isSource: store.radarExpanded)
        .foregroundStyle(.white)
        .task {
            radar.configure(for: location.coordinate)
            await radar.loadFrames()
            // Intent only: the clock starts once every frame's tiles are prefetched.
            if radar.frames.count > 1 { radar.setPlaying(true) }
        }
    }

    private func collapse() {
        store.radar.setPlaying(false) // the compact tile stays still (and free) unless the user hits play
        withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
            store.radarExpanded = false
        }
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
                .background(.ultraThinMaterial, in: Circle())
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
        .background(.ultraThinMaterial, in: Capsule())
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
            if compact { Capsule().fill(.ultraThinMaterial) }
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
            VStack(alignment: .trailing, spacing: 2) {
                Text("Radar opacity").font(.caption2.weight(.semibold)).opacity(0.75)
                RadarOpacityControl(opacity: $opacity)
            }
            if let error = radar.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RadarTimeline: View {
    let radar: RadarPlayback
    let timeZone: TimeZone

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
            .keyboardShortcut(.space, modifiers: [])
            .disabled(radar.frames.count < 2)
            .help(radar.isPlaying ? "Pause (Space)" : "Play (Space)")

            VStack(spacing: 4) {
                Slider(value: Binding(get: { Double(radar.index) },
                                      set: { radar.crossfade = false; radar.scrub(to: Int($0.rounded())) }),
                       in: 0...Double(max(radar.frames.count - 1, 1)),
                       onEditingChanged: { editing in radar.crossfade = !editing })
                    .disabled(radar.frames.count < 2)
                HStack {
                    Text(radar.frames.first.map { Fmt.time($0.time, timeZone) } ?? "")
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct RadarLegend: View {
    let provider: RadarProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("PRECIPITATION").font(.caption2.weight(.semibold)).opacity(0.7)
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 170, height: 6)
                .clipShape(Capsule())
            HStack {
                Text("Light")
                Spacer()
                Text("Heavy")
            }
            .font(.caption2)
            .frame(width: 170)
            .opacity(0.8)
            Text(provider.attribution).font(.system(size: 9)).opacity(0.6)
        }
    }

    private var colors: [Color] {
        switch provider {
        case .nexrad:
            return [Color(red: 0.0, green: 0.9, blue: 0.95), Color(red: 0.0, green: 0.8, blue: 0.0),
                    Color(red: 1.0, green: 0.95, blue: 0.0), Color(red: 1.0, green: 0.55, blue: 0.0),
                    Color(red: 0.9, green: 0.0, blue: 0.0), Color(red: 0.8, green: 0.0, blue: 0.8)]
        case .rainViewer:
            return [Color(red: 0.55, green: 0.8, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.95),
                    Color(red: 1.0, green: 0.85, blue: 0.0), Color(red: 1.0, green: 0.3, blue: 0.0),
                    Color(red: 0.75, green: 0.0, blue: 0.4)]
        }
    }
}
