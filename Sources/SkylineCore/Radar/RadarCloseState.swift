import Foundation

/// Close/reopen bookkeeping for the radar tile cache: load epoch, waiter drain, the suspended flag,
/// the retry generation, and one task that runs a close's purge before the next reopen's prewarm.
/// Decoded images stay in the app cache. A completion whose epoch is stale must not store or complete.
@MainActor
public final class RadarCloseState<Payload> {
    public struct Waiter {
        public var wanted: () -> Bool
        public var completion: (Payload?) -> Void
        public var cancelled: () -> Void

        public init(wanted: @escaping () -> Bool = { true },
                    completion: @escaping (Payload?) -> Void,
                    cancelled: @escaping () -> Void = {}) {
            self.wanted = wanted
            self.completion = completion
            self.cancelled = cancelled
        }
    }

    public private(set) var epoch = 0
    public private(set) var retryGeneration = 0
    public private(set) var suspended = false
    public var retryScheduled = false

    private var waiters: [String: [Waiter]] = [:]
    private var queue: [String] = []
    private var pending: Task<Void, Never>?

    public init() {}

    public var queued: [String] { queue }

    /// The first waiter for `key` is queued. Further waiters join that request.
    @discardableResult
    public func add(key: String, _ waiter: Waiter) -> Bool {
        if waiters[key] != nil {
            waiters[key, default: []].append(waiter)
            return false
        }
        waiters[key] = [waiter]
        queue.append(key)
        return true
    }

    public func dequeue(_ key: String) {
        if let index = queue.firstIndex(of: key) { queue.remove(at: index) }
    }

    /// Splits waiters still needed from ones the caller should cancel. Each waiter is in one list.
    public func liveWaiters(for key: String) -> (live: [Waiter], dropped: [Waiter]) {
        let all = waiters[key] ?? []
        var live: [Waiter] = []
        var dropped: [Waiter] = []
        live.reserveCapacity(all.count)
        for waiter in all {
            if waiter.wanted() { live.append(waiter) } else { dropped.append(waiter) }
        }
        if live.isEmpty { waiters[key] = nil } else { waiters[key] = live }
        return (live, dropped)
    }

    /// nil when `started` is not the current epoch: do not store a tile and do not call a waiter.
    public func claim(epoch started: Int, key: String) -> [Waiter]? {
        guard started == epoch else { return nil }
        return waiters.removeValue(forKey: key) ?? []
    }

    public func close(purge: @escaping @Sendable () async -> Void) {
        suspended = true
        epoch += 1
        retryGeneration += 1
        retryScheduled = false
        queue.removeAll()
        let dropped = waiters
        waiters.removeAll()
        let previous = pending
        pending = Task {
            await previous?.value
            await purge()
        }
        for list in dropped.values {
            for waiter in list { waiter.cancelled() }
        }
    }

    public func reopen(prewarm: @escaping @Sendable () async -> Void) {
        suspended = false
        let previous = pending
        pending = Task {
            await previous?.value
            await prewarm()
        }
    }

    public func waitForChain() async {
        await pending?.value
    }
}
