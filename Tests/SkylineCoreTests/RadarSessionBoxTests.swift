import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SkylineCore

struct RadarSessionBoxTests {
    final class FakeSession: RadarTileTransport, @unchecked Sendable {
        var finished = false
        func finishTasksAndInvalidate() { finished = true }
    }

    private func makeBox(cache: URLCache, shared: URLCache, made: Made) -> RadarSessionBox<FakeSession> {
        RadarSessionBox(cache: cache, sharedCache: shared, memoryCapacity: 4 << 20) { _ in
            let session = FakeSession()
            made.sessions.append(session)
            return session
        }
    }

    final class Made: @unchecked Sendable {
        var sessions: [FakeSession] = []
    }

    private static func cache(memory: Int) -> URLCache {
        #if os(Linux)
        URLCache(memoryCapacity: memory, diskCapacity: 0, diskPath: nil)
        #else
        URLCache(memoryCapacity: memory, diskCapacity: 0)
        #endif
    }

    @Test func suspendZeroesRamCachesAndSwapsSession() {
        let cache = Self.cache(memory: 4 << 20)
        let shared = Self.cache(memory: 8 << 20)
        let made = Made()
        let box = makeBox(cache: cache, shared: shared, made: made)
        let first = box.current()
        #expect(made.sessions.count == 1)
        box.suspend()
        #expect(cache.memoryCapacity == 0)
        #expect(shared.memoryCapacity == 0)
        #expect(first.finished)
        let second = box.current()
        #expect(second !== first)
        #expect(made.sessions.count == 2)
        #expect(!second.finished)
    }

    @Test func resumeRestoresCapacities() {
        let cache = Self.cache(memory: 4 << 20)
        let shared = Self.cache(memory: 8 << 20)
        let box = makeBox(cache: cache, shared: shared, made: Made())
        box.suspend()
        #expect(cache.memoryCapacity == 0)
        #expect(shared.memoryCapacity == 0)
        box.resume()
        #expect(cache.memoryCapacity == 4 << 20)
        #expect(shared.memoryCapacity == 8 << 20)
    }
}
