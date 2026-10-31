import Foundation
import Testing
@testable import SkylineCore

@MainActor
struct RadarCloseStateTests {
    final class Counts: @unchecked Sendable {
        var cancelled = 0
        var completed = 0
    }

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

    final class Order: @unchecked Sendable {
        var items: [String] = []
    }

    private func waiter(_ counts: Counts) -> RadarCloseState<Int>.Waiter {
        .init(completion: { _ in counts.completed += 1 }, cancelled: { counts.cancelled += 1 })
    }

    @Test func closeDropsDecodedQueuesWaitersAndBumpsEpoch() {
        let book = RadarCloseState<Int>()
        let counts = Counts()
        book.noteDecoded("a")
        book.noteDecoded("b")
        for key in ["a", "b", "c"] {
            book.add(key: key, waiter(counts))
        }
        let epoch = book.epoch
        #expect(book.queued == ["a", "b", "c"])
        book.close {}
        #expect(book.epoch == epoch + 1)
        #expect(book.retryGeneration == 1)
        #expect(book.suspended)
        #expect(book.decoded.isEmpty)
        #expect(book.queued.isEmpty)
        #expect(counts.cancelled == 3)
        #expect(counts.completed == 0)
        book.close {}
        #expect(counts.cancelled == 3)
        #expect(counts.completed == 0)
    }

    @Test func lateCompletionAfterCloseIsIgnored() {
        let book = RadarCloseState<Int>()
        let counts = Counts()
        book.add(key: "tile", waiter(counts))
        let epoch = book.epoch
        book.close {}
        #expect(book.claim(epoch: epoch, key: "tile") == nil)
        #expect(book.deliver(epoch: epoch, key: "tile", retain: true) == false)
        #expect(book.decoded.isEmpty)
        #expect(book.retained.isEmpty)
        #expect(counts.cancelled == 1)
        #expect(counts.completed == 0)
    }

    @Test func reopenAfterCloseWaitsForPurge() async {
        let book = RadarCloseState<Int>()
        let gate = Gate()
        let order = Order()
        book.close {
            await gate.wait()
            order.items.append("purge")
        }
        book.reopen {
            order.items.append("prewarm")
        }
        for _ in 0..<30 {
            await Task.yield()
            #expect(!order.items.contains("prewarm"))
        }
        gate.release()
        await book.waitForChain()
        #expect(order.items == ["purge", "prewarm"])
        #expect(!book.suspended)
    }
}
