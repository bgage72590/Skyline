import Foundation
import Testing
@testable import SkylineCore

struct RetainedPurgeTests {
    final class Broadcast: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private(set) var waiting = 0

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if open {
                    lock.unlock()
                    c.resume()
                    return
                }
                waiting += 1
                waiters.append(c)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            open = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    /// The in-flight fetch runs on the cooperative pool. A yield-only spin loses the race when
    /// other suites are decoding rasters at the same time, so wait on a short sleep instead.
    private func waitUntil(_ gate: Broadcast, atLeast n: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while gate.waiting < n, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return gate.waiting >= n
    }

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test(.rasterFixtures) func purgeAllZeroesCompressedBytes() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png")
        let wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        let rasters = RidgeRasterStore { url in url.pathExtension == "png" ? png : wld }
        _ = await rasters.raster(base: "https://a/1")
        #expect(await rasters.compressedBytes > 0)
        #expect(await rasters.count == 1)
        await rasters.purgeAll()
        #expect(await rasters.compressedBytes == 0)
        #expect(await rasters.count == 0)

        let filled = [UInt8](repeating: 1, count: 256 * 256)
        let masks = RadarQCMaskStore { _ in filled }
        _ = await masks.mask(template: "https://m/{z}/{x}/{y}.png", tile: .init(z: 6, x: 18, y: 23))
        #expect(await masks.compressedBytes > 0)
        #expect(await masks.cachedCount > 0)
        await masks.purgeAll()
        #expect(await masks.compressedBytes == 0)
        #expect(await masks.cachedCount == 0)
    }

    @Test(.rasterFixtures) func fetchLandingAfterPurgeStaysCompressedOnly() async throws {
        let png = try Self.fixture("OKX_N0B_202610161748", "png")
        let wld = try Self.fixture("OKX_N0B_202610161748", "wld")
        let rasterGate = Broadcast()
        let rasters = RidgeRasterStore { url in
            await rasterGate.wait()
            return url.pathExtension == "png" ? png : wld
        }
        let rasterTask = Task { await rasters.raster(base: "https://a/1") }
        #expect(await waitUntil(rasterGate, atLeast: 2))
        await rasters.purge()
        rasterGate.release()
        let landed = await rasterTask.value
        #expect(landed != nil)
        #expect(await rasters.count == 0)
        #expect(await rasters.compressedBytes > 0)
        #expect(await rasters.fetches == 1)

        let maskGate = Broadcast()
        let filled = [UInt8](repeating: 1, count: 256 * 256)
        let masks = RadarQCMaskStore { _ in
            await maskGate.wait()
            return filled
        }
        let maskTask = Task {
            await masks.mask(template: "https://m/{z}/{x}/{y}.png", tile: .init(z: 6, x: 18, y: 23))
        }
        #expect(await waitUntil(maskGate, atLeast: 9))
        await masks.purge()
        maskGate.release()
        _ = await maskTask.value
        #expect(await masks.cachedCount == 0)
        #expect(await masks.compressedBytes > 0)
    }
}
