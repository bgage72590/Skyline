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

    /// One pressure-relief pass on the utility queue. Logs the footprint before and after.
    /// Called by `CloseReliefScheduler` after the window-close purge. Not a new allocator API:
    /// the walk is the same `malloc_zone_pressure_relief` `soon` uses.
    static func relieve(pass: Int) {
        queue.async {
            let before = footprintMB()
            _ = malloc_zone_pressure_relief(nil, 0)
            let after = footprintMB()
            print("[relief] pass=\(pass) before=\(before) after=\(after)")
            fflush(stdout)
        }
    }

    /// Same physical-footprint read as `StressTest.footprintMB`, without that type's main-actor isolation.
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }
}
