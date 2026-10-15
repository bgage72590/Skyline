import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Network
import SkylineCore

/// Decoded radar tiles shared by every radar map. Downloads go through a disk-backed URLCache
/// (tile servers send `max-age`), decoding happens off the main thread, and concurrent requests
/// for the same tile are coalesced.
@MainActor
final class RadarImageCache {
    static let shared = RadarImageCache()

    private let session: URLSession
    private let urlCache: URLCache
    private let images = NSCache<NSString, RadarTile>()
    private struct Waiter {
        /// Still needed? (false once the requesting map/zoom/frame set is gone) — checked before starting.
        let wanted: () -> Bool
        let completion: (RadarTile?) -> Void
        let cancelled: () -> Void
    }
    private var waiters: [String: [Waiter]] = [:]
    /// Tiles the server says don't exist (404, or an empty/undecodable 200): "resolved, nothing to draw"
    /// for `missingTTL`, then asked again. Pruned by age so it can't grow without bound.
    private var failures: [String: Date] = [:]
    /// Tiles that failed for a transient reason (offline, timeout, 5xx): retried with back-off
    /// (5 s, 10 s, 20 s … 60 s), and immediately after wake or when the network comes back.
    private var transient: [String: (at: Date, attempts: Int)] = [:]
    static let missingTTL: TimeInterval = 120
    /// Posted (main queue) when failed tiles should be requested again: wake, network back, back-off over.
    static let retryNotification = Notification.Name("SkylineRadarRetryTiles")
    private var retryScheduled = false
    private let pathMonitor = NWPathMonitor()
    private var lastPathSatisfied = true
    private var wakeObserver: NSObjectProtocol?

    /// What a download produced.
    enum Outcome: Sendable { case image(RadarTile), missing, transientFailure }

    private init() {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.briangage.Skyline/radar-tiles", isDirectory: true)
        // Encoded PNGs: the disk cache does the real work; RAM only for the last few bursts (L8 / E1).
        urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 300 << 20, directory: dir)
        config.urlCache = urlCache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        // Tile hosts (IEM, RainViewer) get the plain User-Agent; only api.weather.gov gets the contact.
        config.httpAdditionalHeaders = ["User-Agent": URLSessionHTTPClient.genericUserAgent]
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
        // Decoded RGBA bytes; live tiles are held by the radar view anyway, so this bridges tiles pruned
        // after a pan and re-requested on pan-back without a network trip (24 MB ≈ 96 tiles; restored
        // from 8 MB in build 35, radar-pan-diagnosis fix 3). `-SkylineDecodedCacheMB N` is a measurement hook.
        images.totalCostLimit = Self.normalCacheBytes
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged(satisfied: ok) } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Skyline.radar.path", qos: .utility))
        startPressureMonitor()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give Wi-Fi a moment, then re-request anything that failed while asleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self?.retryFailedNow() } }
        }
    }

    private func networkChanged(satisfied: Bool) {
        let wasSatisfied = lastPathSatisfied
        lastPathSatisfied = satisfied // set first: the retry below checks `isOnline`
        if satisfied && !wasSatisfied { retryFailedNow() }
    }

    /// Forget transient failures (and recent "missing" verdicts, which may have been caused by the same
    /// outage) and tell the radar views to request their missing tiles again.
    func retryFailedNow() {
        transient.removeAll()
        failures.removeAll()
        NotificationCenter.default.post(name: Self.retryNotification, object: nil)
    }

    /// Window closed: drop decoded tiles nobody is drawing and the encoded-response RAM cache.
    func trim() {
        images.removeAllObjects()
        // Shrinking the RAM capacity evicts the in-memory copies; the disk cache is untouched.
        urlCache.memoryCapacity = 0
        urlCache.memoryCapacity = 4 << 20
        pruneFailures()
    }

    private func pruneFailures() {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0.value) < Self.missingTTL }
        transient = transient.filter { now.timeIntervalSince($0.value.at) < 600 }
    }

    /// Seconds before a transiently failed tile may be asked again.
    private static func backoff(attempts: Int) -> TimeInterval { min(5 * pow(2, Double(max(attempts - 1, 0))), 60) }

    /// False while the Mac has no network. Retry ticks stop then; the network coming back triggers one.
    var isOnline: Bool { lastPathSatisfied }

    /// The radar window became visible again: re-request tiles whose back-off expired while it was hidden.
    func requestRetryWhenVisible() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.retryNotification, object: nil)
        }
    }

    private func scheduleRetryTick(after delay: TimeInterval) {
        // Offline: no point waking every minute; `networkChanged` retries when the path is back.
        guard !retryScheduled, lastPathSatisfied else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryScheduled = false
                NotificationCenter.default.post(name: Self.retryNotification, object: nil)
            }
        }
    }

    // MARK: Memory pressure (build 42): shrink the cache first, never frames, zoom or resolution.

    private var pressureSource: DispatchSourceMemoryPressure?
    private var restoreTask: Task<Void, Never>?
    static let normalCacheBytes = max(4, UserDefaults.standard.object(forKey: "SkylineDecodedCacheMB") as? Int ?? 24) << 20

    func startPressureMonitor() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryPressure(critical: source.data.contains(.critical)) }
        }
        source.resume()
        pressureSource = source
    }

    func memoryPressure(critical: Bool) {
        // Tiles the radar is drawing are held by the radar view, not by this cache, so nothing on
        // screen changes; only re-attach-without-network after a pan-back gets slower.
        images.totalCostLimit = critical ? 1 << 20 : Self.normalCacheBytes / 4
        if critical { images.removeAllObjects() }
        urlCache.memoryCapacity = 0
        urlCache.memoryCapacity = 1 << 20
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            self.images.totalCostLimit = Self.normalCacheBytes
            self.urlCache.memoryCapacity = 4 << 20
        }
    }

    func image(for url: URL) -> RadarTile? {
        images.object(forKey: url.absoluteString as NSString)
    }

    /// True if this tile failed recently (404/blank, or a transient failure still inside its back-off);
    /// callers treat it as "resolved for now" and ask again once this turns false.
    func recentlyFailed(_ url: URL) -> Bool {
        let key = url.absoluteString
        let now = Date()
        if let at = failures[key], now.timeIntervalSince(at) < Self.missingTTL { return true }
        if let t = transient[key], now.timeIntervalSince(t.at) < Self.backoff(attempts: t.attempts) { return true }
        return false
    }

    func load(_ url: URL, wanted: @escaping () -> Bool = { true },
              cancelled: @escaping () -> Void = {}, completion: @escaping (RadarTile?) -> Void) {
        let key = url.absoluteString
        if let hit = images.object(forKey: key as NSString) { return completion(hit) }
        let waiter = Waiter(wanted: wanted, completion: completion, cancelled: cancelled)
        if waiters[key] != nil {
            waiters[key]?.append(waiter)
            return
        }
        waiters[key] = [waiter]
        queue.append(url)
        pump()
    }

    /// At most `maxInFlight` downloads+decodes at once, in request order (the radar view asks for the
    /// visible frame first). Bounds transient memory (encoded + decoded buffers) during bursts.
    private var queue: [URL] = []
    private var inFlight = 0
    private let maxInFlight = 6

    private func pump() {
        while inFlight < maxInFlight, !queue.isEmpty {
            let url = queue.removeFirst()
            let key = url.absoluteString
            // Drop requests nobody needs any more (map collapsed, zoom changed, new scans), so stale
            // work can't starve the tiles that are on screen now.
            let all = waiters[key] ?? []
            let live = all.filter { $0.wanted() }
            if live.isEmpty {
                waiters[key] = nil
                all.forEach { $0.cancelled() }
                continue
            }
            waiters[key] = live
            all.filter { !$0.wanted() }.forEach { $0.cancelled() }
            inFlight += 1
            start(url)
        }
    }

    private func start(_ url: URL) {
        let key = url.absoluteString
        let session = self.session
        Task {
            let outcome = await Self.fetchDecoded(session: session, url: url)
            inFlight -= 1
            defer { pump() }
            var image: RadarTile?
            switch outcome {
            case .image(let decoded):
                image = decoded
                images.setObject(decoded, forKey: key as NSString, cost: decoded.heldBytes)
                failures[key] = nil
                transient[key] = nil
            case .missing:
                failures[key] = Date()
            case .transientFailure:
                // Not a hole: the tile exists, the network/server hiccupped. Ask again after a back-off.
                let attempts = (transient[key]?.attempts ?? 0) + 1
                transient[key] = (Date(), attempts)
                scheduleRetryTick(after: Self.backoff(attempts: attempts))
            }
            if failures.count + transient.count > 2_000 { pruneFailures() }
            let callbacks = waiters.removeValue(forKey: key) ?? []
            callbacks.forEach { $0.completion(image) }
        }
    }

    nonisolated private static func fetchDecoded(session: URLSession, url: URL) async -> Outcome {
        // Tile hosts come from responses (RainViewer's `host`): known servers only (L28).
        guard KnownHosts.isAllowed(url) else { return .missing }
        RequestStats.shared.note() // includes tiles served from the disk cache
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: url) } catch { return .transientFailure }
        guard let http = response as? HTTPURLResponse else { return .transientFailure }
        guard KnownHosts.isAllowed(http.url ?? url) else { return .missing }
        switch http.statusCode {
        case 200: break
        case 404, 410: return .missing
        default: return .transientFailure // 5xx, 429, odd redirects: retry later
        }
        // Decode inside an autorelease pool so ImageIO's temporaries are freed per tile, not per burst
        // (less heap growth/fragmentation while a loop of ~100 tiles decodes).
        let image: RadarTile? = autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
            // Build 42: 8-bit palette indices, pixel-identical, ~4× smaller (RadarTilePacker).
            let tile = RadarTilePacker.pack(decoded)
            RequestStats.shared.notePacked(tile.isPacked)
            return tile
        }
        return image.map(Outcome.image) ?? .missing
    }
}
