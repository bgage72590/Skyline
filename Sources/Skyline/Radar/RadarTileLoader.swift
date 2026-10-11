import Foundation
import CoreGraphics
import ImageIO
import SkylineCore

/// Loads radar tiles through a dedicated URLSession with a disk-backed URLCache (servers send
/// `max-age`, so replaying the loop costs no network). Beyond a provider's native max zoom it
/// over-zooms: fetches the parent tile and crops/upscales the relevant quadrant.
final class RadarTileLoader: @unchecked Sendable {
    static let shared = RadarTileLoader()

    private let session: URLSession
    private let derived = NSCache<NSString, NSData>()

    private init() {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.briangage.Skyline/radar-tiles", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20, directory: dir)
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": URLSessionHTTPClient.userAgent]
        session = URLSession(configuration: config)
        derived.totalCostLimit = 48 << 20
    }

    func load(frame: RadarFrame, z: Int, x: Int, y: Int, maxNativeZoom: Int,
              completion: @escaping @Sendable (Data?, Error?) -> Void) {
        guard z > maxNativeZoom else {
            guard let url = frame.url(z: z, x: x, y: y) else { return completion(nil, URLError(.badURL)) }
            fetch(url, completion: completion)
            return
        }
        let dz = z - maxNativeZoom
        let key = "\(frame.id)|\(z)/\(x)/\(y)"
        if let cached = cachedTile(key) { return completion(cached as Data, nil) }
        let px = x >> dz, py = y >> dz
        guard let url = frame.url(z: maxNativeZoom, x: px, y: py) else { return completion(nil, URLError(.badURL)) }
        let subX = x - (px << dz), subY = y - (py << dz)
        fetch(url) { [self] data, error in
            guard let data else { return completion(nil, error) }
            let out = Self.crop(data, dz: dz, subX: subX, subY: subY)
            if let out { storeTile(out, key) }
            completion(out, out == nil ? URLError(.cannotDecodeContentData) : nil)
        }
    }

    private func cachedTile(_ key: String) -> Data? { derived.object(forKey: key as NSString) as Data? }
    private func storeTile(_ data: Data, _ key: String) { derived.setObject(data as NSData, forKey: key as NSString, cost: data.count) }

    private func fetch(_ url: URL, completion: @escaping @Sendable (Data?, Error?) -> Void) {
        session.dataTask(with: url) { data, response, error in
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(nil, error ?? URLError(.badServerResponse))
            } else {
                completion(data, error)
            }
        }.resume()
    }

    /// Crops the (subX, subY) cell of a 2^dz × 2^dz grid out of a tile and scales it to 256 px.
    static func crop(_ data: Data, dz: Int, subX: Int, subY: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let cell = image.width >> dz
        guard cell > 0,
              let cropped = image.cropping(to: CGRect(x: subX * cell, y: subY * cell, width: cell, height: cell)),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? output as Data : nil
    }
}
