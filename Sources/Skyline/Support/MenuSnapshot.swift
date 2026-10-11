import AppKit
import SwiftUI
import SkylineCore

/// Hidden QA hook: `-SkylineSnapshotMenu <path.png>` waits for the menu-bar location's first load (or
/// failure), then renders the menu-bar dropdown and the status-item label off-screen to PNGs and logs the
/// staleness state to stdout. Lets the dropdown be checked without clicking the menu bar. Inert unless set.
@MainActor
enum MenuSnapshot {
    static func runIfRequested(store: WeatherStore) {
        guard let path = UserDefaults.standard.string(forKey: "SkylineSnapshotMenu"), !path.isEmpty else { return }
        Task {
            let start = Date()
            while Date().timeIntervalSince(start) < 45 {
                if let loc = store.menuBarLocation, !store.isLoading(loc),
                   store.reports[loc.id] != nil || store.errors[loc.id] != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(1))
            let loc = store.menuBarLocation
            let report = loc.flatMap { store.reports[$0.id] }
            print("[snapshot] location=\(loc?.name ?? "-") report=\(report != nil) "
                  + "error=\(loc.flatMap { store.errors[$0.id] } ?? "-") "
                  + "offlineFallback=\(report?.isOfflineFallback ?? false) "
                  + "stale=\(report.map { store.isStale($0) } ?? false) "
                  + "dataAgeMin=\(report.map { Int($0.dataAge() / 60) } ?? -1) "
                  + "updated=\(report.map { DataAge.updatedText($0) } ?? "-") "
                  + "alerts=\(report?.activeAlerts().map(\.event) ?? [])")
            write(MenuBarContentView().environment(store), to: path)
            let label = MenuBarLabel(store: store).padding(6).background(Color.white)
            write(label, to: path.replacingOccurrences(of: ".png", with: "-label.png"))
            fflush(stdout)
            if UserDefaults.standard.bool(forKey: "SkylineStressQuit") { NSApp.terminate(nil) }
        }
    }

    private static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("[snapshot] render failed for \(path)"); return
        }
        do { try png.write(to: URL(fileURLWithPath: path)); print("[snapshot] wrote \(path)") }
        catch { print("[snapshot] write failed: \(error)") }
    }
}
