import AppKit
import SwiftUI
import SkylineCore

/// Hidden memory measurement hook (inert unless `-SkylineMemTest` is set). It runs from the window
/// content, which a manual launch opens. A `-SkylineLaunchKind login` run needs `-SkylineSlimMode NO`
/// or this never starts. Logs `[mem] …` lines with
/// the physical footprint (Activity Monitor's "Memory") and quits at the end.
/// * `-SkylineMemTest radar`: New York, expanded radar on the OKX site at `-SkylineMemZoom` (10),
///   playing; samples every 2 s for `-SkylineMemSeconds` (150).
/// * `-SkylineMemTest cycles`: `-SkylineMemCycles` (20) rounds of radar expand → play 6 s → collapse,
///   next city, refresh (the selected city forced; every 5th round the main window is closed and
///   reopened), then settles with the window open and closed.
/// Selection, radar site and play state are put back afterwards. Never adds or removes cities.
@MainActor
enum MemoryTest {
    static func runIfRequested(store: WeatherStore) {
        guard let mode = UserDefaults.standard.string(forKey: "SkylineMemTest") else { return }
        Task { await run(mode, store: store) }
    }

    static func log(_ s: String) { print("[mem] \(s)"); fflush(stdout) }
    static func mb() -> Int { StressTest.footprintMB() }

    static func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    static func run(_ mode: String, store: WeatherStore) async {
        let d = UserDefaults.standard
        let savedSelection = store.selectedID
        let savedSite = d.string(forKey: "radarSite")
        let radar = store.radar
        let start = Date()
        while store.selectedLocation.flatMap({ store.reports[$0.id] }) == nil, Date().timeIntervalSince(start) < 60 { await sleep(0.25) }
        if let ny = store.allLocations.first(where: { !$0.isCurrentLocation && $0.name == "New York" }) { store.selectedID = ny.id }
        radar.setSiteChoice(.site("OKX"))
        await sleep(3)
        log("start mode=\(mode) mem=\(mb()) cities=\(store.allLocations.count)")
        switch mode {
        case "radar":
            store.radarExpanded = true
            await sleep(6)
            await zoom(to: { let v = d.integer(forKey: "SkylineMemZoom"); return v > 0 ? v : 10 }(), radar: radar)
            radar.setPlaying(true)
            let seconds = { let v = d.double(forKey: "SkylineMemSeconds"); return v > 0 ? v : 150 }()
            var samples: [Int] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < seconds {
                await sleep(2)
                let m = mb()
                samples.append(m)
                let z = radar.debugRadarZoom?() ?? -1
                log("t=\(Int(Date().timeIntervalSince(t0)))s mem=\(m) z=\(z) frames=\(radar.frames.count) progress=\(String(format: "%.2f", radar.progress)) playing=\(radar.isRunning) held=\(radar.debugRadarStats?().held ?? -1)")
            }
            let steady = samples.suffix(max(1, samples.count * 2 / 3))
            log("RESULT radar steady min=\(steady.min()!) max=\(steady.max()!) avg=\(steady.reduce(0, +) / steady.count) peak=\(samples.max()!) z=\(radar.debugRadarZoom?() ?? -1)")
        default:
            let n = { let v = d.integer(forKey: "SkylineMemCycles"); return v > 0 ? v : 20 }()
            let cities = store.allLocations
            var perCycle: [Int] = []
            for i in 1...n {
                store.radarExpanded = true
                await sleep(2)
                radar.setPlaying(true)
                await sleep(6)
                radar.setPlaying(false)
                store.radarExpanded = false
                await sleep(2)
                store.selectedID = cities[i % cities.count].id
                await sleep(3)
                if let sel = store.selectedLocation { await store.load(sel, force: true) }
                if i % 5 == 0 {
                    closeMainWindow()
                    await sleep(4)
                    AppExit.showMainWindow()
                    await sleep(4)
                }
                await sleep(1)
                perCycle.append(mb())
                log("cycle \(i) mem=\(perCycle.last!) maps=\(RadarMapContainer.live) engines=\(RadarMapContainer.liveMaps) liveTiles=\(RadarLayerView.liveTiles)")
            }
            store.selectedID = savedSelection
            await sleep(30)
            let open = mb()
            closeMainWindow()
            await sleep(45)
            log("RESULT cycles first=\(perCycle.first!) last=\(perCycle.last!) max=\(perCycle.max()!) settledOpen=\(open) settledClosed=\(mb()) maps=\(RadarMapContainer.live) engines=\(RadarMapContainer.liveMaps)")
        }
        radar.setPlaying(false)
        store.radarExpanded = false
        store.selectedID = savedSelection
        if let savedSite { d.set(savedSite, forKey: "radarSite"); radar.setSiteChoice(RadarSiteChoice(stored: savedSite)) }
        log("done cities=\(store.allLocations.count)")
        await sleep(1)
        if d.bool(forKey: "SkylineMemQuit") { NSApp.terminate(nil) }
    }

    static func closeMainWindow() {
        for window in NSApp.windows where window.title == "Skyline" || window.identifier?.rawValue.hasPrefix(SceneID.main) == true {
            window.close()
        }
    }

    /// Steps the expanded map's zoom until the radar renders at tile zoom `z`.
    static func zoom(to z: Int, radar: RadarPlayback) async {
        for _ in 0..<12 {
            guard let current = radar.debugRadarZoom?(), current > 0, current != z, let zoom = radar.debugZoomHandler else { break }
            zoom(current < z ? 0.6 : 1.6)
            await sleep(1.5)
        }
        log("zoom now \(radar.debugRadarZoom?() ?? -1)")
    }
}
