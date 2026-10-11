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
    private var waiters: [String: [(CGImage?) -> Void]] = [:]
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
        images.totalCostLimit = 220 << 20 // decoded RGBA bytes
    }

    func image(for url: URL) -> CGImage? {
        images.object(forKey: url.absoluteString as NSString)
    }

    /// True if this tile failed recently (404/blank); callers treat it as "resolved, nothing to draw".
    func recentlyFailed(_ url: URL) -> Bool {
        guard let at = failures[url.absoluteString] else { return false }
        return Date().timeIntervalSince(at) < 120
    }

    func load(_ url: URL, completion: @escaping (CGImage?) -> Void) {
        let key = url.absoluteString
        if let hit = images.object(forKey: key as NSString) { return completion(hit) }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        let session = self.session
        Task {
            let image = await Self.fetchDecoded(session: session, url: url)
            if let image {
                images.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                failures[key] = nil
            } else {
                failures[key] = Date()
            }
            let callbacks = waiters.removeValue(forKey: key) ?? []
            callbacks.forEach { $0(image) }
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
