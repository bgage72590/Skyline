import Foundation

/// Tiny on-disk cache for API responses with per-entry TTL. Stale entries are kept and served
/// as a fallback when the network fails, so the app shows *something* offline.
public actor ResponseCache {
    public struct Entry: Codable, Sendable {
        public var storedAt: Date
        public var data: Data
    }

    private let directory: URL?
    /// Recently used entries (the disk holds the rest). Capped so a long session can't grow it forever.
    private var memory: [String: Entry] = [:]
    private var recency: [String] = []
    public static let memoryLimit = 48
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

    /// Deletes entries older than `maxAge` (default 14 days) so old "My Location" responses don't pile
    /// up as a timestamped location trail. Unreadable files are deleted too. Call once at launch.
    /// The disk scan runs off the actor (awaiting it frees the actor), so forecast fetches made during
    /// the sweep aren't stuck behind it.
    public func prune(olderThan maxAge: TimeInterval = 14 * 86400) async {
        let cutoff = now().addingTimeInterval(-maxAge)
        memory = memory.filter { $0.value.storedAt >= cutoff }
        recency.removeAll { memory[$0] == nil }
        guard let directory else { return }
        sweepWrites = []
        defer { sweepWrites = nil }
        let candidates = await Task.detached(priority: .utility) { Self.pruneCandidates(in: directory, cutoff: cutoff) }.value
        deleteStale(candidates, cutoff: cutoff)
    }

    /// Off-actor scan: files that were old or unreadable when read. Nothing is deleted here.
    nonisolated static func pruneCandidates(in directory: URL, cutoff: Date) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { url in
            guard url.pathExtension == "plist" else { return false }
            guard let raw = try? Data(contentsOf: url),
                  let e = try? PropertyListDecoder().decode(Entry.self, from: raw) else { return true }
            return e.storedAt < cutoff
        }
    }

    /// Files written while a sweep is scanning (nil when no sweep is running).
    private var sweepWrites: Set<String>?

    /// Back on the actor (no `store` can interleave): skip any candidate rewritten during the scan.
    func deleteStale(_ candidates: [URL], cutoff: Date) {
        let rewritten = sweepWrites ?? []
        for url in candidates where !rewritten.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Number of entries held in memory (for tests).
    public var memoryCount: Int { memory.count }

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
        remember(e, for: key)
        guard let url = fileURL(key) else { return }
        sweepWrites?.insert(url.lastPathComponent)
        if let encoded = try? PropertyListEncoder().encode(e) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    private func entry(_ key: String) -> Entry? {
        if let e = memory[key] { touch(key); return e }
        guard let url = fileURL(key), let raw = try? Data(contentsOf: url),
              let e = try? PropertyListDecoder().decode(Entry.self, from: raw) else { return nil }
        remember(e, for: key)
        return e
    }

    private func remember(_ e: Entry, for key: String) {
        memory[key] = e
        touch(key)
        // Memory-only caches (tests) have nowhere else to keep entries, so only disk-backed ones evict.
        while directory != nil, recency.count > Self.memoryLimit {
            memory[recency.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        if let i = recency.lastIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
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
