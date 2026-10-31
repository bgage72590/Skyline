import Foundation
import Testing
@testable import SkylineCore

struct CloseReliefSchedulerTests {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if open {
                    lock.unlock()
                    c.resume()
                    return
                }
                continuation = c
                lock.unlock()
            }
        }
        func release() {
            lock.lock()
            open = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    final class Log: @unchecked Sendable {
        var passes: [Int] = []
        var times: [TimeInterval] = []
        var chains = 0
    }

    private func waitUntil(_ ready: @Sendable () -> Bool) async {
        for _ in 0..<200 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func scheduler(clock: Clock, log: Log, chain: Gate, delay: Gate, reliefDelay: TimeInterval = 2) -> CloseReliefScheduler {
        CloseReliefScheduler(delay: reliefDelay, clock: { clock.now }, sleep: { seconds in
            await delay.wait()
            clock.advance(seconds)
        }, relief: { pass in
            log.passes.append(pass)
            log.times.append(clock.now.timeIntervalSince1970)
        })
    }

    @Test func reliefRunsAfterTheChainCompletes() async {
        let clock = Clock(), log = Log(), chain = Gate(), delay = Gate()
        let scheduler = scheduler(clock: clock, log: log, chain: chain, delay: delay)
        scheduler.noteClosed {
            log.chains += 1
            await chain.wait()
        }
        await waitUntil { log.chains == 1 }
        #expect(log.passes.isEmpty)
        chain.release()
        await waitUntil { log.passes == [1] }
        #expect(log.passes == [1])
        #expect(log.times == [1_000])
        delay.release()
        await waitUntil { log.passes.count == 2 }
        #expect(log.passes == [1, 2])
        #expect(log.times == [1_000, 1_002])
    }

    @Test func reopenBeforeTheDelayCancelsTheSecondPass() async {
        let clock = Clock(), log = Log(), chain = Gate(), delay = Gate()
        let scheduler = scheduler(clock: clock, log: log, chain: chain, delay: delay)
        scheduler.noteClosed { await chain.wait() }
        chain.release()
        await waitUntil { log.passes == [1] }
        scheduler.noteOpened()
        delay.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(log.passes == [1])
    }

    @Test func doubleCloseYieldsOneSchedule() async {
        let clock = Clock(), log = Log(), chain = Gate(), delay = Gate()
        let scheduler = scheduler(clock: clock, log: log, chain: chain, delay: delay)
        scheduler.noteClosed {
            log.chains += 1
            await chain.wait()
        }
        scheduler.noteClosed {
            log.chains += 1
            await chain.wait()
        }
        await waitUntil { log.chains >= 1 }
        #expect(log.chains == 1)
        chain.release()
        delay.release()
        await waitUntil { log.passes.count == 2 }
        #expect(log.passes == [1, 2])
        #expect(log.chains == 1)
    }

    @Test func nothingRunsWhenOpen() async {
        let clock = Clock(), log = Log(), chain = Gate(), delay = Gate()
        let scheduler = scheduler(clock: clock, log: log, chain: chain, delay: delay)
        scheduler.noteOpened()
        scheduler.noteClosed { await chain.wait() }
        scheduler.noteOpened()
        chain.release()
        delay.release()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(log.passes.isEmpty)
    }
}
