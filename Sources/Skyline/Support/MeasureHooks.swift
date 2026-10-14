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
                    print("[measure] liveTiles=\(RadarLayerView.liveTiles) added=\(RadarLayerView.addedTiles) requests=\(RequestStats.shared.total) frames=\(store.radar.frames.count) progress=\(store.radar.progress)"); fflush(stdout)
                }
            }
        }
        if defaults.bool(forKey: "SkylineRadarSiteTest") { radarSiteTest(store: store) }
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
