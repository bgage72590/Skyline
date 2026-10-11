import Foundation

/// Tiny on-disk cache for API responses with per-entry TTL. Stale entries are kept and served
/// as a fallback when the network fails, so the app shows *something* offline.
public actor ResponseCache {
    public struct Entry: Codable, Sendable {
        public var storedAt: Date
        public var data: Data
    }

    private let directory: URL?
    private var memory: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    /// `directory == nil` gives a memory-only cache (used by tests).
    public init(directory: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.briangage.Skyline/responses", isDirectory: true)
    }

    /// Returns cached data younger than `maxAge`, else nil.
    public func fresh(_ key: String, maxAge: TimeInterval) -> Data? {
        guard let e = entry(key), now().timeIntervalSince(e.storedAt) < maxAge else { return nil }
        return e.data
    }

    /// Returns cached data of any age.
    public func stale(_ key: String) -> Data? { entry(key)?.data }

    /// Returns the cached entry (data plus when it was downloaded) if it's at most `maxAge` old.
    /// Used for the offline fallback, so the caller knows (and can show) how old the data really is.
    public func entry(_ key: String, maxAge: TimeInterval) -> Entry? {
        guard let e = entry(key), now().timeIntervalSince(e.storedAt) <= maxAge else { return nil }
        return e
    }

    public func store(_ data: Data, for key: String) {
        let e = Entry(storedAt: now(), data: data)
        memory[key] = e
        guard let url = fileURL(key) else { return }
        if let encoded = try? PropertyListEncoder().encode(e) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    private func entry(_ key: String) -> Entry? {
        if let e = memory[key] { return e }
        guard let url = fileURL(key), let raw = try? Data(contentsOf: url),
              let e = try? PropertyListDecoder().decode(Entry.self, from: raw) else { return nil }
        memory[key] = e
        return e
    }

    private func fileURL(_ key: String) -> URL? {
        directory?.appendingPathComponent(Self.hash(key) + ".plist")
    }

    /// FNV-1a 64-bit; stable across launches (unlike `hashValue`).
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
