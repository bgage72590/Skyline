import AppKit
import SwiftUI
import SkylineCore

/// Hidden QA hook: `-SkylineStressTest <seconds>` hammers the radar UI (expand/collapse, play/pause,
/// scrub, zoom, opacity, module panels, provider switches) at human-ish speed, logs progress to stdout,
/// and quits cleanly at the end. Used to verify the layout-loop crash fix; inert unless the argument is set.
@MainActor
enum StressTest {
    static func runIfRequested(store: WeatherStore) {
        let seconds = UserDefaults.standard.double(forKey: "SkylineStressTest")
        guard seconds > 0 else { return }
        Task { await run(store: store, seconds: seconds) }
    }

    /// Physical footprint (what Activity Monitor shows as "Memory"), in MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }

    private static func log(_ s: String) {
        print("[stress] \(s)")
        fflush(stdout)
    }

    static func run(store: WeatherStore, seconds: Double) async {
        // Seeded so runs are comparable (memory before/after); -SkylineStressSeed overrides.
        let seed = UInt64(max(1, UserDefaults.standard.integer(forKey: "SkylineStressSeed")))
        var rng = SplitMix64(seed: UserDefaults.standard.object(forKey: "SkylineStressSeed") == nil ? 42 : seed)
        var counts: [String: Int] = [:]
        let start = Date()
        var lastLog = start
        var peakMB = footprintMB()
        log("starting for \(Int(seconds))s")
        // The run randomises the persisted opacity; put the user's value back afterwards.
        let savedOpacity = UserDefaults.standard.object(forKey: RadarOpacity.key)
        // Wait for the first report so the radar card exists.
        while store.selectedLocation.flatMap({ store.reports[$0.id] }) == nil, Date().timeIntervalSince(start) < 60 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        var growth: [String: Int] = [:]   // MB of footprint growth attributed to each action kind
        while Date().timeIntervalSince(start) < seconds {
            let radar = store.radar
            let before = counts, m0 = footprintMB()
            let action = Int.random(in: 0..<100, using: &rng)
            switch action {
            case 0..<18:
                if store.radarExpanded { radar.setPlaying(false) }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                    store.activeModule = nil
                    store.radarExpanded.toggle()
                }
                counts["expand/collapse", default: 0] += 1
            case 18..<36:
                radar.togglePlay()
                counts["play/pause", default: 0] += 1
            case 36..<56:
                radar.crossfade = false
                for _ in 0..<Int.random(in: 3...10, using: &rng) {
                    radar.scrub(to: Int.random(in: 0..<max(radar.frames.count, 1), using: &rng))
                    try? await Task.sleep(for: .milliseconds(30))
                }
                radar.crossfade = true
                counts["scrub", default: 0] += 1
            case 56..<76:
                if store.radarExpanded, let zoom = radar.debugZoomHandler {
                    zoom([0.45, 0.6, 1.7, 2.2].randomElement(using: &rng)!)
                    counts["zoom", default: 0] += 1
                } else {
                    radar.setPlaying(true)
                    counts["play(card)", default: 0] += 1
                }
            case 76..<88:
                UserDefaults.standard.set(Double.random(in: RadarOpacity.range, using: &rng), forKey: RadarOpacity.key)
                counts["opacity", default: 0] += 1
            case 88..<96:
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    store.radarExpanded = false
                    store.activeModule = store.activeModule == nil
                        ? ModuleSelection(module: DetailModule.allCases.randomElement(using: &rng)!, day: nil) : nil
                }
                counts["module panel", default: 0] += 1
            default:
                if store.radarExpanded {
                    radar.switchProvider(radar.provider == .nexrad ? .rainViewer : .nexrad)
                    counts["provider", default: 0] += 1
                }
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 120...450, using: &rng)))
            let m1 = footprintMB()
            peakMB = max(peakMB, m1)
            if let kind = counts.first(where: { before[$0.key] != $0.value })?.key {
                growth[kind, default: 0] += m1 - m0
            }
            if Date().timeIntervalSince(lastLog) >= 15 {
                lastLog = Date()
                log("t=\(Int(Date().timeIntervalSince(start)))s mem=\(footprintMB())MB peak=\(peakMB)MB maps=\(RadarMapContainer.live) tiles=\(RadarLayerView.liveTiles) actions=\(counts.values.reduce(0, +)) frames=\(radar.frames.count) progress=\(radar.progress) expanded=\(store.radarExpanded) playing=\(radar.isPlaying)")
            }
        }
        if let savedOpacity { UserDefaults.standard.set(savedOpacity, forKey: RadarOpacity.key) }
        else { UserDefaults.standard.removeObject(forKey: RadarOpacity.key) }
        if store.radar.provider != .nexrad { store.radar.switchProvider(.nexrad) }
        log("done: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        log("growth by action (MB, net): " + growth.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        log("memory: end=\(footprintMB())MB peak=\(peakMB)MB")
        log("STRESS OK (no crash)")
        try? await Task.sleep(for: .seconds(1))
        if UserDefaults.standard.bool(forKey: "SkylineStressQuit") { NSApp.terminate(nil) }
    }

}

/// Tiny deterministic RNG for reproducible stress runs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
