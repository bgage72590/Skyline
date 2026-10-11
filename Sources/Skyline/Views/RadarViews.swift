import SwiftUI
import SkylineCore

/// Static (non-animated) radar preview in the detail page. Zero CPU once tiles are drawn.
struct RadarCard: View {
    let location: WeatherLocation
    @Environment(WeatherStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var latest: [RadarFrame] = []

    private var provider: RadarProvider { .preferred(for: location.coordinate) }

    var body: some View {
        Card(title: "Radar", systemImage: "map.fill") {
            ZStack(alignment: .bottomTrailing) {
                RadarMapView(center: location.coordinate, frames: latest, index: max(0, latest.count - 1),
                             maxNativeZoom: provider.maximumNativeZoom, interactive: false, spanDegrees: 4)
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
                Button {
                    store.radarLocation = location
                    openWindow(id: SceneID.radar)
                } label: {
                    Label("Animated Radar", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
            HStack {
                if let frame = latest.last {
                    Text("Latest scan \(Fmt.time(frame.time, location.timeZone))")
                }
                Spacer()
                Text(provider.attribution)
            }
            .font(.caption2)
            .opacity(0.7)
        }
        .task(id: location.id) {
            if let frames = try? await store.service.radarFrames(provider) {
                latest = frames.last.map { [$0] } ?? []
            }
        }
    }
}

/// Full interactive radar with a play/pause timeline. Animation runs only while this window is visible.
struct RadarWindowView: View {
    @Environment(WeatherStore.self) private var store

    var body: some View {
        let radar = store.radar
        let location = store.radarLocation ?? store.selectedLocation
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let location {
                    RadarMapView(center: location.coordinate, frames: radar.frames, index: radar.index,
                                 maxNativeZoom: radar.provider.maximumNativeZoom, interactive: true,
                                 spanDegrees: radar.provider == .nexrad ? 5 : 8, opacity: radar.opacity)
                } else {
                    Text("Select a location first.").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                RadarControlsOverlay(radar: radar)
                    .padding(12)
            }
            RadarTimeline(radar: radar, timeZone: location?.timeZone ?? .current)
        }
        .navigationTitle(location.map { "Radar · \($0.name)" } ?? "Radar")
        .background(WindowVisibilityReader { visible in radar.isVisible = visible })
        .onAppear {
            if let location { radar.setProvider(.preferred(for: location.coordinate)) }
        }
        .onChange(of: location?.id) { _, _ in
            if let location { radar.setProvider(.preferred(for: location.coordinate)) }
        }
        .task(id: radar.provider) {
            await radar.loadFrames()
            if radar.isVisible && radar.frames.count > 1 { radar.isPlaying = true }
        }
    }
}

struct RadarControlsOverlay: View {
    @Bindable var radar: RadarPlayback

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Picker("Source", selection: Binding(get: { radar.provider }, set: { radar.setProvider($0) })) {
                ForEach(RadarProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $radar.opacity, in: 0.3...1)
                    .frame(width: 110)
            }
            .help("Radar opacity")
            RadarLegend(provider: radar.provider)
            if let error = radar.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RadarLegend: View {
    let provider: RadarProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 160, height: 6)
                .clipShape(Capsule())
            HStack {
                Text("Light")
                Spacer()
                Text("Heavy")
            }
            .font(.caption2)
            .frame(width: 160)
            .foregroundStyle(.secondary)
        }
    }

    private var colors: [Color] {
        switch provider {
        case .nexrad: // NWS reflectivity palette
            return [Color(red: 0.0, green: 0.9, blue: 0.95), Color(red: 0.0, green: 0.8, blue: 0.0),
                    Color(red: 1.0, green: 0.95, blue: 0.0), Color(red: 1.0, green: 0.55, blue: 0.0),
                    Color(red: 0.9, green: 0.0, blue: 0.0), Color(red: 0.8, green: 0.0, blue: 0.8)]
        case .rainViewer: // "Universal Blue"
            return [Color(red: 0.55, green: 0.8, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.95),
                    Color(red: 1.0, green: 0.85, blue: 0.0), Color(red: 1.0, green: 0.3, blue: 0.0),
                    Color(red: 0.75, green: 0.0, blue: 0.4)]
        }
    }
}

struct RadarTimeline: View {
    @Bindable var radar: RadarPlayback
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 12) {
            Button { radar.step(-1); radar.isPlaying = false } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(.borderless)
            Button { radar.isPlaying.toggle() } label: {
                Image(systemName: radar.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(radar.frames.count < 2)
            Button { radar.step(1); radar.isPlaying = false } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(.borderless)

            Slider(value: Binding(get: { Double(radar.index) },
                                  set: { radar.isPlaying = false; radar.index = Int($0.rounded()) }),
                   in: 0...Double(max(radar.frames.count - 1, 1)))
                .disabled(radar.frames.count < 2)

            VStack(alignment: .trailing, spacing: 0) {
                Text(radar.currentFrame.map { Fmt.time($0.time, timeZone) } ?? "--")
                    .font(.body.monospacedDigit().weight(.semibold))
                Text(relativeLabel).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
            if radar.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var relativeLabel: String {
        guard let frame = radar.currentFrame, let last = radar.frames.last else { return "" }
        let minutes = Int((last.time.timeIntervalSince(frame.time) / 60).rounded())
        return minutes == 0 ? "Latest" : "−\(minutes) min"
    }
}
