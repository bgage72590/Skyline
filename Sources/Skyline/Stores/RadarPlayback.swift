import Foundation
import Observation
import SkylineCore

/// Radar timeline state shared by the inline radar card and its expanded in-window view.
///
/// Playback rules (smooth + cheap):
/// * Every frame's tiles are prefetched first; the clock only starts once `progress` reaches ~100 %.
/// * A steady clock advances one frame every `frameInterval`, holding on the newest scan.
/// * The clock exists only while `isPlaying` (user intent) **and** `isVisible` (window on screen and
///   not occluded) **and** the frames are loaded, so a hidden window costs no CPU.
/// * The map layer cross-fades between frame layers on the GPU; nothing is re-downloaded per frame.
@MainActor
@Observable
final class RadarPlayback {
    private(set) var provider: RadarProvider = .nexrad
    private(set) var frames: [RadarFrame] = []
    /// Loop length (NEXRAD). Persisted; RainViewer ignores it (its free tier is fixed at ~2 h).
    private(set) var range: RadarRange = RadarRange(rawValue: UserDefaults.standard.string(forKey: "radarRange") ?? "") ?? .oneHour
    /// Observed only by the small time label / scrubber. Map layers are driven directly (see `sinks`),
    /// so a frame change never re-renders the map's SwiftUI parent or touches layout.
    var index: Int = 0 {
        didSet { if index != oldValue { notifySinks() } }
    }
    var isPlaying = false { didSet { updateClock() } }
    var isVisible = false { didSet { updateClock() } }
    /// Fraction (0…1) of all frames' visible tiles that are loaded, reported by the map view.
    private(set) var progress: Double = 0
    private(set) var isLoadingIndex = false
    private(set) var errorMessage: String?
    /// While the user drags the scrubber, frames switch without cross-fading.
    @ObservationIgnored var crossfade = true
    @ObservationIgnored private let sinks = NSHashTable<AnyObject>.weakObjects()
    /// QA hook: the expanded map registers a zoom handler so the stress test can zoom programmatically.
    @ObservationIgnored var debugZoomHandler: ((Double) -> Void)?

    @ObservationIgnored private let service: WeatherService
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?

    static let frameInterval: Duration = .milliseconds(550)
    static let holdOnLatest: Duration = .milliseconds(1600)
    /// Frames are re-indexed at most this often (new scans arrive every 5–10 min).
    static let indexMaxAge: TimeInterval = 5 * 60

    init(service: WeatherService) {
        self.service = service
    }

    var currentFrame: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }
    var isReady: Bool { !frames.isEmpty && progress >= 0.98 }
    var isRunning: Bool { clock != nil }

    /// Picks the right provider for a location and loads the frame index if stale.
    func configure(for coordinate: Coordinate) {
        let preferred = RadarProvider.preferred(for: coordinate)
        if preferred != provider { switchProvider(preferred) } else { Task { await loadFrames() } }
    }

    func switchProvider(_ p: RadarProvider) {
        guard p != provider else { return }
        provider = p
        frames = []
        progress = 0
        progressGate.reset()
        loadedAt = nil
        Task { await loadFrames(force: true) }
    }

    func setRange(_ r: RadarRange) {
        guard r != range else { return }
        range = r
        UserDefaults.standard.set(r.rawValue, forKey: "radarRange")
        guard provider == .nexrad else { return }
        setPlaying(false)
        frames = []
        progress = 0
        progressGate.reset()
        loadedAt = nil
        Task { await loadFrames(force: true) }
    }

    func loadFrames(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.indexMaxAge, !frames.isEmpty { return }
        isLoadingIndex = true
        defer { isLoadingIndex = false }
        let requested = provider, requestedRange = range
        do {
            let new = try await service.radarFrames(requested, range: requestedRange, forceRefresh: force)
            guard requested == provider, requestedRange == range else { return }
            loadedAt = Date()
            errorMessage = new.isEmpty ? "No radar frames available." : nil
            if new.map(\.id) != frames.map(\.id) {
                frames = new
                index = max(0, new.count - 1)
                progress = 0
                progressGate.reset()
            }
        } catch {
            errorMessage = "Radar unavailable: \(error.localizedDescription)"
        }
    }

    /// Called asynchronously (never from inside layout) by the map that owns progress reporting.
    func reportProgress(_ value: Double) {
        guard let delivered = progressGate.filter(value), delivered != progress else { return }
        let wasReady = isReady
        progress = delivered
        if isReady != wasReady { updateClock() }
    }

    @ObservationIgnored private var progressGate = ChangeGate(step: 0.02)

    // MARK: Direct frame delivery to map layers

    func addSink(_ sink: RadarLayerView) { sinks.add(sink) }
    func removeSink(_ sink: RadarLayerView) { sinks.remove(sink) }

    private func notifySinks() {
        let animated = crossfade
        for case let sink as RadarLayerView in sinks.allObjects {
            sink.playbackIndexChanged(index, animated: animated)
        }
    }

    func togglePlay() { isPlaying.toggle() }

    /// Writes only real changes: an @Observable setter notifies observers even when the value is equal,
    /// and every notification schedules another SwiftUI update pass.
    func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
    }

    func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        let next = (index + delta + frames.count) % frames.count
        if next != index { index = next }
    }

    func scrub(to i: Int) {
        setPlaying(false)
        let next = min(max(0, i), max(0, frames.count - 1))
        if next != index { index = next }
    }

    private func updateClock() {
        let shouldRun = isPlaying && isVisible && isReady && frames.count > 1
        if shouldRun == (clock != nil) { return }
        clock?.cancel()
        clock = nil
        guard shouldRun else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let atLatest = self.index >= self.frames.count - 1
                try? await Task.sleep(for: atLatest ? Self.holdOnLatest : Self.frameInterval)
                if Task.isCancelled { return }
                if atLatest, let loadedAt = self.loadedAt, Date().timeIntervalSince(loadedAt) > Self.indexMaxAge {
                    // New scans: the map keeps showing the old frames until the new ones are prefetched.
                    await self.loadFrames(force: true)
                    if !self.isReady { self.clock = nil; return }
                }
                self.step(1)
            }
        }
    }
}
