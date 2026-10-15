import AppKit
import SwiftUI
import SkylineCore

/// Hidden measurement hooks (CPU/memory before/after comparisons). Inert unless the arguments are set.
/// * `-SkylinePlayRadar YES`: start radar playback once the window is up (with `-SkylineOpenRadar YES`).
/// * `-SkylineCloseMainWindowAfter <seconds>`: close the main window after that delay (menu bar keeps running).
@MainActor
enum MeasureHooks {
    static func runIfRequested(store: WeatherStore) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "SkylinePlayRadar") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                store.radar.setPlaying(true)
                print("[measure] radar play requested"); fflush(stdout)
                for _ in 0..<6 {
                    try? await Task.sleep(for: .seconds(8))
                    print("[measure] packed=\(RequestStats.shared.packCounts) liveTiles=\(RadarLayerView.liveTiles) added=\(RadarLayerView.addedTiles) requests=\(RequestStats.shared.total) frames=\(store.radar.frames.count) progress=\(store.radar.progress)"); fflush(stdout)
                }
            }
        }
        if defaults.bool(forKey: "SkylineRadarSiteTest") { radarSiteTest(store: store) }
        if defaults.bool(forKey: "SkylinePanTest") { panTest(store: store) }
        if defaults.bool(forKey: "SkylineFullScreen") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.frame.width > 600 }) {
                    w.toggleFullScreen(nil)
                    print("[measure] full screen \(w.screen?.frame.size ?? .zero)"); fflush(stdout)
                }
            }
        }
        let swapAfter = defaults.double(forKey: "SkylineScanSwapAfter")
        if swapAfter > 0 {
            // A new frame set mid-loop (range change = new frame IDs, the same path as fresh scans), then back.
            Task { @MainActor in
                let radar = store.radar
                let original = radar.range
                try? await Task.sleep(for: .seconds(swapAfter))
                // A range change pauses on purpose (user action); a fresh scan doesn't, so resume to
                // measure the swap with the loop playing, then log that the clock keeps stepping.
                @MainActor func swap(to r: RadarRange, _ label: String) async {
                    radar.setRange(r)
                    radar.setPlaying(true)
                    print("[measure] \(label) (range \(r.rawValue)) playing=\(radar.isPlaying)"); fflush(stdout)
                    for t in stride(from: 5, through: 25, by: 5) {
                        try? await Task.sleep(for: .seconds(5))
                        print("[measure] +\(t)s playing=\(radar.isPlaying) index=\(radar.index)/\(radar.frames.count) progress=\(radar.progress)"); fflush(stdout)
                    }
                }
                await swap(to: original == .oneHour ? .twoHours : .oneHour, "scan swap")
                await swap(to: original, "scan swap back")
            }
        }
        let closeAfter = defaults.double(forKey: "SkylineCloseMainWindowAfter")
        if closeAfter > 0 {
            Task {
                try? await Task.sleep(for: .seconds(closeAfter))
                for window in NSApp.windows where window.title == "Skyline" || window.identifier?.rawValue.hasPrefix(SceneID.main) == true {
                    window.close()
                }
                print("[measure] main window closed"); fflush(stdout)
            }
        }
    }

    /// `-SkylinePanTest YES` (with `-SkylineOpenRadar YES -SkylinePlayRadar YES`): review test 8. While the
    /// loop plays, pans the map in 60 steps at 60 Hz (right, then back), sampling on-screen holes in the
    /// frame being shown at every step; writes ~/Library/Logs/skyline-pan-test.txt.
    static func panTest(store: WeatherStore) {
        Task { @MainActor in
            let radar = store.radar
            try? await Task.sleep(for: .seconds(45))
            guard let pan = radar.debugPanHandler, let stats = radar.debugRadarStats else {
                print("[measure] pan test: no expanded map"); fflush(stdout); return
            }
            var lines = ["before: \(stats())"]
            var worst = 0, stepsWithHoles = 0
            for leg in [0.004, -0.004] {
                for _ in 0..<60 {
                    pan(leg, leg / 2)
                    try? await Task.sleep(for: .milliseconds(16))
                    let s = stats()
                    worst = max(worst, s.holes)
                    if s.holes > 0 { stepsWithHoles += 1 }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            lines.append("during pan: steps with on-screen holes \(stepsWithHoles)/120, worst \(worst) tiles")
            lines.append("settled: \(stats())")
            let text = lines.joined(separator: "\n")
            print("[measure] pan test\n" + text); fflush(stdout)
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/skyline-pan-test.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `-SkylineRadarSiteTest YES` (with `-SkylineOpenRadar YES`): checks nearest-site, composite and a
    /// manual site load real frames, writes ~/Library/Logs/skyline-radar-site-test.txt, restores the
    /// saved choice and quits.
    static func radarSiteTest(store: WeatherStore) {
        Task { @MainActor in
            let radar = store.radar
            let saved = UserDefaults.standard.string(forKey: "radarSite")
            var lines: [String] = [], ok = true
            func wait() async { try? await Task.sleep(for: .seconds(10)) }
            @MainActor func check(_ label: String, expect: String) {
                let url = radar.frames.first?.urlTemplate ?? "-"
                let pass = !radar.frames.isEmpty && url.contains(expect)
                ok = ok && pass
                lines.append("\(label): station=\(radar.station?.icao ?? "composite") frames=\(radar.frames.count) progress=\(String(format: "%.2f", radar.progress)) url=\(url) \(pass ? "ok" : "FAIL")")
            }
            await wait()
            radar.setSiteChoice(.auto)
            await wait()
            if let near = radar.nearestStation {
                check("auto", expect: "ridge::\(near.id)-N0B-")
            } else { lines.append("auto: selected city outside CONUS (provider \(radar.provider.rawValue))") }
            radar.setSiteChoice(.composite); await wait()
            check("composite", expect: "ridge::USCOMP-N0Q-")
            radar.setSiteChoice(.site("DIX")); await wait()
            check("manual", expect: "ridge::DIX-N0B-")
            radar.setSiteChoice(RadarSiteChoice(stored: saved))
            if saved == nil { UserDefaults.standard.removeObject(forKey: "radarSite") }
            lines.append("[radar-site-test] \(ok ? "PASS" : "FAIL")")
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/skyline-radar-site-test.txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
