import Foundation

/// PNG bytes for the last radar loop, kept while the window is closed. About 12 frames × 30 tiles
/// × ~10 KB. Oldest tiles drop first. Reopen decodes these instead of rebuilding from rasters and masks.
/// The cap is read once from `-SkylineRetainedTilesMB` (default 4). `0` stores nothing. Arguments only.
public struct EncodedTileCache: Sendable {
    public let budgetBytes: Int
    public private(set) var bytes = 0
    private var order: [String] = []
    private var blobs: [String: Data] = [:]

    public init(budgetBytes: Int? = nil, arguments: [String] = CommandLine.arguments) {
        if let budgetBytes {
            self.budgetBytes = max(0, budgetBytes)
        } else {
            let megabytes = LaunchArguments.int("SkylineRetainedTilesMB", arguments: arguments) ?? 4
            self.budgetBytes = max(0, megabytes) << 20
        }
    }

    public mutating func removeAll() {
        bytes = 0
        order.removeAll()
        blobs.removeAll()
    }

    public mutating func store(_ key: String, data: Data) {
        guard budgetBytes > 0, !data.isEmpty, data.count <= budgetBytes else { return }
        if let old = blobs[key] {
            bytes -= old.count
            order.removeAll { $0 == key }
        }
        blobs[key] = data
        order.append(key)
        bytes += data.count
        while bytes > budgetBytes, !order.isEmpty {
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
