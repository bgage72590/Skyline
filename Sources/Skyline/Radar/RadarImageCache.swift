import CoreGraphics
import Foundation
import ImageIO
import SkylineCore

/// Decoded radar tiles shared by every radar map. Downloads go through a disk-backed URLCache
/// (tile servers send `max-age`), decoding happens off the main thread, and concurrent requests
/// for the same tile are coalesced.
@MainActor
final class RadarImageCache {
    static let shared = RadarImageCache()

    private let session: URLSession
    private let images = NSCache<NSString, CGImage>()
    private struct Waiter {
        /// Still needed? (false once the requesting map/zoom/frame set is gone) — checked before starting.
        let wanted: () -> Bool
        let completion: (CGImage?) -> Void
        let cancelled: () -> Void
    }
    private var waiters: [String: [Waiter]] = [:]
    private var failures: [String: Date] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.briangage.Skyline/radar-tiles", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 300 << 20, directory: dir)
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": URLSessionHTTPClient.userAgent]
        session = URLSession(configuration: config)
        images.totalCostLimit = 32 << 20 // decoded RGBA bytes; live tiles are held by their layers anyway
    }

    func image(for url: URL) -> CGImage? {
        images.object(forKey: url.absoluteString as NSString)
    }

    /// True if this tile failed recently (404/blank); callers treat it as "resolved, nothing to draw".
    func recentlyFailed(_ url: URL) -> Bool {
        guard let at = failures[url.absoluteString] else { return false }
        return Date().timeIntervalSince(at) < 120
    }

    func load(_ url: URL, wanted: @escaping () -> Bool = { true },
              cancelled: @escaping () -> Void = {}, completion: @escaping (CGImage?) -> Void) {
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
            let image = await Self.fetchDecoded(session: session, url: url)
            inFlight -= 1
            defer { pump() }
            if let image {
                images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                failures[key] = nil
            } else {
                failures[key] = Date()
            }
            let callbacks = waiters.removeValue(forKey: key) ?? []
            callbacks.forEach { $0.completion(image) }
        }
    }

    nonisolated private static func fetchDecoded(session: URLSession, url: URL) async -> CGImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}
