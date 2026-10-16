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
    /// Last source the user picked (or the default for the first city). Persisted so switching cities
    /// and relaunching keep RainViewer vs NEXRAD (QA #6). NEXRAD is still forced off outside CONUS.
    private(set) var provider: RadarProvider = RadarProvider(rawValue: UserDefaults.standard.string(forKey: "radarProvider") ?? "") ?? .nexrad
    private(set) var frames: [RadarFrame] = []
    /// Loop length (NEXRAD). Persisted; RainViewer ignores it (its free tier is fixed at ~2 h).
    private(set) var range: RadarRange = RadarRange(rawValue: UserDefaults.standard.string(forKey: "radarRange") ?? "") ?? .oneHour
    /// Future radar (T12): HRRR forecast frames after "now" (NEXRAD only). Persisted; off by default
    /// (radar-features §4) so a first launch stays on observed scans until the user opts in.
    private(set) var showsFuture: Bool = UserDefaults.standard.object(forKey: "radarFuture") as? Bool ?? false
    /// Loop playback speed (½×…4×). Persisted.
    private(set) var playbackSpeed: RadarPlaybackSpeed = {
        let raw = UserDefaults.standard.double(forKey: "radarPlaybackSpeed")
        return RadarPlaybackSpeed(rawValue: raw) ?? .one
    }()
    /// Reflectivity loop, or a rainfall-total overlay (L21, NEXRAD/US only). Not persisted: each launch
    /// starts on the radar.
    private(set) var layer: RadarLayer = .reflectivity
    /// NEXRAD view: nearest site (default), the national composite, or a site the user picked. Persisted.
    private(set) var siteChoice = RadarSiteChoice(stored: UserDefaults.standard.string(forKey: "radarSite"))
    /// The single site being shown (nil: national composite or not NEXRAD).
    private(set) var station: NexradStation?
    /// Why the composite is showing instead of the chosen site (no recent scans).
    private(set) var siteNote: String?
    @ObservationIgnored private var coordinate: Coordinate?
    /// Whether the place is in the lower 48 (NEXRAD, future radar and rainfall totals available).
    private(set) var inCONUS = true
    /// Observed only by the small time label / scrubber. Map layers are driven directly (see `sinks`),
    /// so a frame change never re-renders the map's SwiftUI parent or touches layout.
    var index: Int = 0 {
        didSet {
            SwiftUIUpdatePass.assertOutside("radar index")
            if index != oldValue { notifySinks() }
        }
    }
    var isPlaying = false { didSet { updateHoldsLoop(); updateClock() } }
    var isVisible = false {
        didSet {
            updateHoldsLoop(); updateClock(); updateStormPoll()
            // Tile retries pause while the window is hidden; catch up once it's back (next main-queue turn).
            if isVisible && !oldValue { RadarImageCache.shared.requestRetryWhenVisible() }
        }
    }
    /// Strong nearby storm cells for motion arrows (polled only while the radar is visible).
    private(set) var stormCells: [StormCell] = []
    /// True while the user drags the radar scrubber (frames are loaded for scrubbing).
    var isScrubbingRadar = false { didSet { if isScrubbingRadar != oldValue { updateHoldsLoop() } } }
    /// Whether map views hold every frame of the loop. Only while playing (or queued to play), scrubbing,
    /// or for `releaseLoopAfter` after that; otherwise just the shown frame's tiles stay in memory.
    @ObservationIgnored private(set) var holdsLoop = false
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    static let releaseLoopAfter: Duration = .seconds(45)
    /// Fraction (0…1) of all frames' visible tiles that are loaded, reported by the map view.
    private(set) var progress: Double = 0
    private(set) var isLoadingIndex = false
    private(set) var errorMessage: String?
    /// While the user drags the scrubber, frames switch without cross-fading.
    @ObservationIgnored var crossfade = true
    @ObservationIgnored private let sinks = NSHashTable<AnyObject>.weakObjects()
    /// QA hook: the expanded map registers a zoom handler so the stress test can zoom programmatically.
    @ObservationIgnored var debugZoomHandler: ((Double) -> Void)?
    /// Measurement hooks (build 42 pan test): pan the expanded map by a fraction of its width/height,
    /// and read (visible holes in the shown frame, missing ring tiles, held tiles).
    @ObservationIgnored var debugPanHandler: ((Double, Double) -> Void)?
    @ObservationIgnored var debugRadarStats: (() -> (holes: Int, ringMissing: Int, held: Int))?

    @ObservationIgnored private let service: WeatherService
    /// The play clock. A TaskSlot so a clock task that resumes after being replaced can't orphan its successor.
    @ObservationIgnored private let clock = TaskSlot()
    /// Storm-attribute poll (~2 min) — only while `isVisible` and in CONUS.
    @ObservationIgnored private let stormPoll = TaskSlot()
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var generation = RequestGeneration()

    static let baseFrameMs: Double = 550
    static let baseHoldOnLatestMs: Double = 1600
    static let baseHoldOnNowMs: Double = 900
    static let frameInterval: Duration = .milliseconds(550)
    static let holdOnLatest: Duration = .milliseconds(1600)
    /// A short pause on "now" before the forecast frames, so the hand-off is visible.
    static let holdOnNow: Duration = .milliseconds(900)
    /// Frames are re-indexed at most this often (new scans arrive every 5–10 min).
    static let indexMaxAge: TimeInterval = 5 * 60

    init(service: WeatherService) {
        self.service = service
    }

    var currentFrame: RadarFrame? { frames.indices.contains(index) ? frames[index] : nil }
    /// Index of the newest observed scan ("now"); later frames are model forecasts.
    var nowIndex: Int { frames.lastIndex { !$0.isForecast } ?? max(0, frames.count - 1) }
    var hasForecastFrames: Bool { frames.last?.isForecast == true }
    var isReady: Bool { !frames.isEmpty && progress >= 0.98 }
    /// Play was pressed but the loop is still loading: playback starts by itself when it's ready (R2).
    var isWaitingToPlay: Bool { isPlaying && !isReady && frames.count > 1 }
    var isRunning: Bool { clock.isOccupied }

    /// Picks the right provider for a place and loads the frame index if stale. Keeps the user's last
    /// choice across cities and relaunches (QA #6); falls back to RainViewer outside CONUS where NEXRAD
    /// has holes. `load: false` when the caller awaits `loadFrames()` itself (L7: two index loads raced).
    func configure(for location: WeatherLocation, load: Bool = true) {
        inCONUS = location.isInCONUS
        // Wipe storm arrows immediately on a city change so the old place's cells never linger.
        let next = location.coordinate
        stormCells = StormMotion.cellsAfterLocationChange(previous: coordinate, new: next, cells: stormCells)
        coordinate = next
        updateStormPoll()
        let newStation = siteChoice.resolvedStation(for: location.coordinate, inCONUS: inCONUS)
        if newStation != station {
            station = newStation
            siteNote = nil
            if provider == .nexrad, layer == .reflectivity, !frames.isEmpty {
                setPlaying(false); resetFrames()
                if load { Task { await loadFrames(force: true) } }
                return
            }
        }
        if !inCONUS, layer != .reflectivity { layer = .reflectivity; resetFrames() }
        // Use the persisted preference; don't write it back when falling back outside CONUS.
        let saved = RadarProvider(rawValue: UserDefaults.standard.string(forKey: "radarProvider") ?? "") ?? provider
        let preferred = RadarProvider.resolved(saved: saved, inCONUS: inCONUS)
        if preferred != provider { switchProvider(preferred, persist: false) } else if load { Task { await loadFrames() } }
    }

    private func resetFrames() {
        frames = []
        progress = 0
        progressGate.reset()
        loadedAt = nil
    }

    func setShowsFuture(_ on: Bool) {
        guard on != showsFuture else { return }
        showsFuture = on
        UserDefaults.standard.set(on, forKey: "radarFuture")
        guard provider == .nexrad, layer == .reflectivity else { return }
        setPlaying(false)
        resetFrames()
        Task { await loadFrames(force: true) }
    }

    func setLayer(_ l: RadarLayer) {
        guard l != layer, l == .reflectivity || (provider == .nexrad && inCONUS) else { return }
        layer = l
        setPlaying(false)
        resetFrames()
        Task { await loadFrames(force: true) }
    }

    func switchProvider(_ p: RadarProvider, persist: Bool = true) {
        guard p != provider else { return }
        provider = p
        if persist { UserDefaults.standard.set(p.rawValue, forKey: "radarProvider") }
        if p != .nexrad { layer = .reflectivity }
        frames = []
        progress = 0
        progressGate.reset()
        loadedAt = nil
        Task { await loadFrames(force: true) }
    }

    func setSiteChoice(_ choice: RadarSiteChoice) {
        guard choice != siteChoice else { return }
        siteChoice = choice
        UserDefaults.standard.set(choice.stored, forKey: "radarSite")
        let newStation = coordinate.flatMap { choice.resolvedStation(for: $0, inCONUS: inCONUS) }
        siteNote = nil
        guard newStation != station else { return }
        station = newStation
        guard provider == .nexrad, layer == .reflectivity else { return }
        setPlaying(false)
        resetFrames()
        Task { await loadFrames(force: true) }
    }

    /// The nearest site for the current place (shown next to "Nearest" in the picker).
    var nearestStation: NexradStation? {
        guard inCONUS, let coordinate else { return nil }
        return NexradStation.nearest(to: coordinate)
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
        // L7: a newer request supersedes this one; a slower, older answer is dropped, not applied.
        let token = generation.next()
        isLoadingIndex = true
        defer { if generation.isCurrent(token) { isLoadingIndex = false } }
        let requested = provider, requestedRange = range, requestedLayer = layer, requestedStation = station
        let site = requested == .nexrad && requestedLayer == .reflectivity ? requestedStation?.id : nil
        let future = showsFuture && requested == .nexrad
        do {
            let new: [RadarFrame]
            if requestedLayer.isRainfallTotal {
                new = IEMMRMS.frame(requestedLayer, now: Date()).map { [$0] } ?? []
            } else {
                var loaded = site == nil ? [] : ((try? await service.radarFrames(requested, range: requestedRange, future: future, site: site, forceRefresh: force)) ?? [])
                if loaded.isEmpty {
                    loaded = try await service.radarFrames(requested, range: requestedRange, future: future, forceRefresh: force)
                }
                new = loaded
                if let s = requestedStation, site != nil, generation.isCurrent(token) {
                    let note: String? = loaded.first?.urlTemplate.contains("ridge::\(s.id)-") == true ? nil
                        : "\(s.icao) has no recent scans. Showing the national composite."
                    if note != siteNote { siteNote = note }
                }
            }
            guard generation.isCurrent(token), requested == provider, requestedRange == range, requestedLayer == layer,
                  requestedStation == station else { return }
            loadedAt = Date()
            errorMessage = new.isEmpty ? "No radar frames available." : nil
            if new.map(\.id) != frames.map(\.id) {
                let wasAtNow = index >= nowIndex
                frames = new
                // Start on "now" (the newest scan), not the end of the forecast.
                if wasAtNow || !isPlaying { index = nowIndex }
                index = min(index, max(0, new.count - 1))
                progress = 0
                progressGate.reset()
            }
        } catch {
            guard generation.isCurrent(token) else { return }
            errorMessage = "Radar unavailable: \(UserFacingError.message(error))"
        }
    }

    /// Called asynchronously (never from inside layout) by the map that owns progress reporting.
    func reportProgress(_ value: Double) {
        SwiftUIUpdatePass.assertOutside("radar progress")
        guard let delivered = progressGate.filter(value), delivered != progress else { return }
        let wasReady = isReady
        progress = delivered
        if isReady != wasReady { updateClock() }
    }

    @ObservationIgnored private var progressGate = ChangeGate(step: 0.02)

    // MARK: Direct frame delivery to map layers

    func addSink(_ sink: RadarLayerView) { sinks.add(sink) }
    func removeSink(_ sink: RadarLayerView) { sinks.remove(sink) }

    private func updateHoldsLoop() {
        let wanted = isVisible && (isPlaying || isScrubbingRadar)
        if wanted {
            releaseTask?.cancel(); releaseTask = nil
            guard !holdsLoop else { return }
            holdsLoop = true
            // The loop isn't loaded until the map says so: not "ready", so the clock can't step onto
            // blank frames before the first progress report.
            progress = 0
            progressGate.reset()
            notifyLoopHold()
        } else if holdsLoop, releaseTask == nil {
            // Keep the loop briefly (pause → play again is instant), then free all but the shown frame.
            releaseTask = Task { [weak self] in
                try? await Task.sleep(for: Self.releaseLoopAfter)
                guard !Task.isCancelled, let self else { return }
                self.releaseTask = nil
                guard !(self.isVisible && (self.isPlaying || self.isScrubbingRadar)) else { return }
                self.holdsLoop = false
                self.notifyLoopHold()
                MemoryRelief.soon()
            }
            if !isVisible { releaseTask?.cancel(); releaseTask = nil; holdsLoop = false; notifyLoopHold() }
        }
    }

    private func notifyLoopHold() {
        for case let sink as RadarLayerView in sinks.allObjects { sink.loopHoldChanged() }
    }

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

    /// Jump the scrubber to the newest observed scan ("Now").
    func jumpToNow() {
        scrub(to: nowIndex)
    }

    func setPlaybackSpeed(_ speed: RadarPlaybackSpeed) {
        guard speed != playbackSpeed else { return }
        playbackSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "radarPlaybackSpeed")
        // Restart the clock so the new interval applies immediately.
        if clock.isOccupied {
            clock.cancel()
            updateClock()
        }
    }

    private func updateClock() {
        let shouldRun = isPlaying && isVisible && isReady && frames.count > 1
        if shouldRun == clock.isOccupied { return }
        clock.cancel()
        guard shouldRun else { return }
        clock.start { [weak self] token in
            while !Task.isCancelled {
                guard let self else { return }
                let atLatest = self.index >= self.frames.count - 1
                let atNow = self.hasForecastFrames && self.index == self.nowIndex
                try? await Task.sleep(for: atLatest ? self.holdOnLatestInterval
                                       : (atNow ? self.holdOnNowInterval : self.frameInterval))
                if Task.isCancelled || !self.clock.owns(token) { return }
                if atLatest, let loadedAt = self.loadedAt, Date().timeIntervalSince(loadedAt) > Self.indexMaxAge {
                    // New scans: the map keeps showing the old frames until the new ones are prefetched.
                    await self.loadFrames(force: true)
                    // Paused, hidden or replaced while reloading: stop, and never touch a successor's slot.
                    if Task.isCancelled || !self.clock.owns(token) { return }
                    if !self.isReady { self.clock.clear(token: token); return }
                }
                self.step(1)
            }
        }
    }

    /// Poll IEM storm attributes ~every 2 min only while the radar is on screen (CONUS).
    private func updateStormPoll() {
        let should = isVisible && inCONUS && coordinate != nil
        if should == stormPoll.isOccupied {
            if !should, !stormCells.isEmpty { stormCells = [] }
            return
        }
        stormPoll.cancel()
        if !should {
            if !stormCells.isEmpty { stormCells = [] }
            return
        }
        stormPoll.start { [weak self] token in
            while !Task.isCancelled {
                guard let self, self.stormPoll.owns(token), let c = self.coordinate else { return }
                let cells = await self.service.stormCells(near: c)
                if Task.isCancelled || !self.stormPoll.owns(token) { return }
                // Drop a response that arrived after the user switched cities (we already cleared).
                guard self.coordinate == c else { continue }
                if cells != self.stormCells { self.stormCells = cells }
                try? await Task.sleep(for: .seconds(StormMotion.pollInterval))
                if Task.isCancelled || !self.stormPoll.owns(token) { return }
            }
        }
    }

    /// Effective frame interval at the current playback speed.
    private var frameInterval: Duration {
        .milliseconds(Int(playbackSpeed.frameMilliseconds(baseMs: Self.baseFrameMs).rounded()))
    }
    private var holdOnLatestInterval: Duration {
        .milliseconds(Int(playbackSpeed.holdMilliseconds(baseMs: Self.baseHoldOnLatestMs).rounded()))
    }
    private var holdOnNowInterval: Duration {
        let ms = playbackSpeed.holdMilliseconds(baseMs: Self.baseHoldOnNowMs,
                                                minimumMs: RadarPlaybackSpeed.minHoldOnNowMs)
        return .milliseconds(Int(ms.rounded()))
    }
}
