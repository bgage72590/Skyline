import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something the radar tile cache can retire with `finishTasksAndInvalidate` (a URLSession, in the app).
public protocol RadarTileTransport: AnyObject {
    func finishTasksAndInvalidate()
}

extension URLSession: RadarTileTransport {}

/// The radar tile session and its disk-backed cache. Closing the window drops the in-memory cache
/// and swaps the session. The old session finishes work it already started. Disk entries stay.
public final class RadarSessionBox<Transport: RadarTileTransport>: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Transport
    public let cache: URLCache
    private let sharedCache: URLCache
    /// RAM capacity restored by `resume` (the cache's capacity at init).
    private let ramBytes: Int
    private var savedShared: Int?
    private let make: (URLCache) -> Transport

    public init(cache: URLCache, sharedCache: URLCache, memoryCapacity: Int, make: @escaping (URLCache) -> Transport) {
        self.cache = cache
        self.sharedCache = sharedCache
        self.ramBytes = memoryCapacity
        self.make = make
        self.session = make(cache)
    }

    public func current() -> Transport {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    /// RAM caches to zero, including the shared URLCache. Disk entries stay. The old session finishes
    /// what it already started (`finishTasksAndInvalidate`, not `invalidateAndCancel`), then goes away.
    public func suspend() {
        lock.lock()
        cache.memoryCapacity = 0
        if savedShared == nil { savedShared = sharedCache.memoryCapacity }
        let old = session
        session = make(cache)
        lock.unlock()
        sharedCache.memoryCapacity = 0
        old.finishTasksAndInvalidate()
    }

    public func resume() {
        lock.lock()
        cache.memoryCapacity = ramBytes
        let memory = savedShared
        lock.unlock()
        if let memory { sharedCache.memoryCapacity = memory }
    }
}
