import AppKit
import SwiftUI

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
}
