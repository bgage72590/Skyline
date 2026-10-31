import Foundation

/// After the close purge finishes, runs one relief pass and a second about `delay` later.
/// A reopen bumps the generation, so the second pass does not run. A close that arrives while
/// a schedule is already active joins that schedule instead of starting another.
/// The relief function is injected (the app uses `MemoryRelief` on a utility queue). The clock
/// and sleep are injected so tests don't wait on the wall clock.
public final class CloseReliefScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let relief: @Sendable (Int) -> Void
    private var generation = 0
    private var isOpen = true
    private var scheduleActive = false

    public init(delay: TimeInterval = 2,
                clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                },
                relief: @escaping @Sendable (Int) -> Void) {
        self.delay = delay
        self.clock = clock
        self.sleep = sleep
        self.relief = relief
    }

    /// Window opened. Cancels a second pass that has not run yet.
    public func noteOpened() {
        lock.lock()
        isOpen = true
        generation += 1
        lock.unlock()
    }

    /// Window closed. Waits for `chain` (the purge), then relieves. A second call while that
    /// schedule is still active does not start another.
    public func noteClosed(chain: @escaping @Sendable () async -> Void) {
        lock.lock()
        if !isOpen, scheduleActive {
            lock.unlock()
            return
        }
        isOpen = false
        generation += 1
        let scheduled = generation
        scheduleActive = true
        lock.unlock()
        Task {
            await chain()
            await self.relieve(scheduled)
        }
    }

    private func relieve(_ generation: Int) async {
        guard stillClosed(generation) else {
            finish(generation)
            return
        }
        relief(1)
        let started = clock()
        await sleep(delay)
        guard stillClosed(generation), clock().timeIntervalSince(started) + 0.05 >= delay else {
            finish(generation)
            return
        }
        relief(2)
        finish(generation)
    }

    private func stillClosed(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && !isOpen
    }

    private func finish(_ generation: Int) {
        lock.lock()
        if self.generation == generation { scheduleActive = false }
        lock.unlock()
    }
}
