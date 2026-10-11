import Darwin
import Foundation

/// Hands free malloc pages back to the system after big transient work (decoding forecast JSON for
/// every location, a radar loop's worth of tiles, tearing down the window). Without this the heap
/// keeps those pages dirty as fragmentation (measured ~37 % of the default zone) and they count toward
/// the app's footprint. Cheap, coalesced, and runs off the main thread.
enum MemoryRelief {
    nonisolated(unsafe) private static var pending = false
    private static let queue = DispatchQueue(label: "Skyline.memory-relief", qos: .utility)

    static func soon(after seconds: Double = 3) {
        queue.async {
            guard !pending else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + seconds) {
                pending = false
                _ = malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}
