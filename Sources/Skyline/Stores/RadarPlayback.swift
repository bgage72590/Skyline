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
    var index: Int = 0
    var isPlaying = false { didSet { updateClock() } }
    var isVisible = false { didSet { updateClock() } }
    /// Fraction (0…1) of all frames' visible tiles that are loaded, reported by the map view.
    private(set) var progress: Double = 0
    private(set) var isLoadingIndex = false
    private(set) var errorMessage: String?
    var opacity: Double = 0.75

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
        loadedAt = nil
        Task { await loadFrames(force: true) }
    }

    func loadFrames(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.indexMaxAge, !frames.isEmpty { return }
        isLoadingIndex = true
        defer { isLoadingIndex = false }
        let requested = provider
        do {
            let new = try await service.radarFrames(requested, forceRefresh: force)
            guard requested == provider else { return }
            loadedAt = Date()
            errorMessage = new.isEmpty ? "No radar frames available." : nil
            if new.map(\.id) != frames.map(\.id) {
                frames = new
                index = max(0, new.count - 1)
                progress = 0
            }
        } catch {
            errorMessage = "Radar unavailable: \(error.localizedDescription)"
        }
    }

    func reportProgress(_ value: Double) {
        let rounded = (value * 50).rounded() / 50 // 2 % steps: avoids needless SwiftUI updates
        guard rounded != progress else { return }
        let wasReady = isReady
        progress = rounded
        if isReady != wasReady { updateClock() }
    }

    func togglePlay() { isPlaying.toggle() }

    func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        index = (index + delta + frames.count) % frames.count
    }

    func scrub(to i: Int) {
        isPlaying = false
        index = min(max(0, i), max(0, frames.count - 1))
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
