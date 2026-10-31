import Foundation
import Testing
@testable import SkylineCore

struct EncodedTileCacheTests {
    @Test func budgetZeroStoresNothing() {
        var cache = EncodedTileCache(budgetBytes: 0)
        cache.store("a", data: Data([1, 2, 3]))
        #expect(cache.bytes == 0)
        #expect(cache.touch("a") == nil)

        var fromArgument = EncodedTileCache(arguments: ["skyline", "-SkylineRetainedTilesMB", "0"])
        #expect(fromArgument.budgetBytes == 0)
        fromArgument.store("b", data: Data([4, 5]))
        #expect(fromArgument.bytes == 0)
        #expect(fromArgument.touch("b") == nil)

        var defaulted = EncodedTileCache(arguments: ["skyline"])
        #expect(defaulted.budgetBytes == 0)
        defaulted.store("c", data: Data([6]))
        #expect(defaulted.bytes == 0)
    }

    @Test func argumentOfFourMegabytesStillStores() {
        var cache = EncodedTileCache(arguments: ["skyline", "-SkylineRetainedTilesMB", "4"])
        #expect(cache.budgetBytes == 4 << 20)
        let blob = Data(repeating: 1, count: 100)
        cache.store("a", data: blob)
        #expect(cache.bytes == 100)
        #expect(cache.touch("a")?.count == 100)
    }

    @Test func evictsOldestFirst() {
        var cache = EncodedTileCache(budgetBytes: 250)
        let blob = Data(repeating: 1, count: 100)
        cache.store("a", data: blob)
        cache.store("b", data: blob)
        cache.store("c", data: blob)
        #expect(cache.bytes == 200)
        #expect(cache.touch("a") == nil)
        #expect(cache.touch("b")?.count == 100)
        #expect(cache.touch("c")?.count == 100)
    }
}
