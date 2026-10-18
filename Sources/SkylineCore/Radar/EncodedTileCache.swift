import Foundation

/// PNG bytes for the last radar loop, kept while the window is closed. About 12 frames × 30 tiles
/// × ~10 KB, capped at 4 MB. Oldest tiles drop first. Reopen decodes these instead of rebuilding
/// from rasters and masks.
public struct EncodedTileCache: Sendable {
    public static let budgetBytes = 4 << 20
    public private(set) var bytes = 0
    private var order: [String] = []
    private var blobs: [String: Data] = [:]

    public init() {}

    public mutating func store(_ key: String, data: Data) {
        guard !data.isEmpty, data.count <= Self.budgetBytes else { return }
        if let old = blobs[key] {
            bytes -= old.count
            order.removeAll { $0 == key }
        }
        blobs[key] = data
        order.append(key)
        bytes += data.count
        while bytes > Self.budgetBytes, !order.isEmpty {
            let oldest = order.removeFirst()
            if let dropped = blobs.removeValue(forKey: oldest) { bytes -= dropped.count }
        }
    }

    /// Marks `key` as most recently used and returns its PNG bytes.
    public mutating func touch(_ key: String) -> Data? {
        guard let data = blobs[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return data
    }
}
