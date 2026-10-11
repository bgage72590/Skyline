import Foundation
import Observation
import SkylineCore

/// Drives the radar timeline. The frame timer only exists while playing *and* visible,
/// so a hidden/occluded radar window costs zero CPU.
@MainActor
@Observable
final class RadarPlayback {
    var provider: RadarProvider = .nexrad
    var frames: [RadarFrame] = []
    var index: Int = 0
    var isPlaying = false { didSet { updateTimer() } }
    var isVisible = false { didSet { if !isVisible { isPlaying = false }; updateTimer() } }
    var isLoading = false
    var errorMessage: String?
    /// Overlay opacity (0…1).
    var opacity: Double = 0.75

    @ObservationIgnored private let service: WeatherService
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?

    /// Frame interval and the pause on the newest frame, tuned to read like a smooth loop.
    private let frameInterval: Duration = .milliseconds(450)
    private let holdOnLatest: Duration = .milliseconds(1600)

    init(service: WeatherService) {
        self.service = service
    }

    var currentFrame: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }

    func loadFrames(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 120, !frames.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        let requested = provider
        do {
            let new = try await service.radarFrames(requested, forceRefresh: force)
            guard requested == provider else { return }
            if new.map(\.id) != frames.map(\.id) {
                frames = new
                index = max(0, new.count - 1)
            }
            loadedAt = Date()
            errorMessage = new.isEmpty ? "No radar frames available." : nil
        } catch {
            errorMessage = "Radar unavailable: \(error.localizedDescription)"
        }
    }

    func setProvider(_ p: RadarProvider) {
        guard p != provider else { return }
        provider = p
        frames = []
        loadedAt = nil
        Task { await loadFrames(force: true) }
    }

    func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        index = (index + delta + frames.count) % frames.count
    }

    private func updateTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard isPlaying, isVisible else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let atLatest = self.index >= self.frames.count - 1
                try? await Task.sleep(for: atLatest ? self.holdOnLatest : self.frameInterval)
                if Task.isCancelled { return }
                self.step(1)
                // Pick up new scans once per loop when the index is stale (> 5 min).
                if self.index == 0, let loadedAt = self.loadedAt, Date().timeIntervalSince(loadedAt) > 300 {
                    await self.loadFrames(force: true)
                }
            }
        }
    }
}
