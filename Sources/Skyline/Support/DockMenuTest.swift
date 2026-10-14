import AppKit

/// Hidden QA hook: `-SkylineDockMenuTest YES` with Show-in-Dock off checks the app owns the menu bar
/// while the main window is open (.regular), drops back to .accessory after ⌘Q-to-menu-bar, and that
/// Update Skyline… is in the app menu. Writes `~/Library/Logs/skyline-dock-test.txt` and quits.
@MainActor
enum DockMenuTest {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "SkylineDockMenuTest") else { return }
        UserDefaults.standard.set(false, forKey: DockIcon.key)
        Task {
            try? await Task.sleep(for: .seconds(3))
            AppExit.showMainWindow()
            try? await Task.sleep(for: .seconds(1.5))
            let openPolicy = NSApp.activationPolicy()
            let hasUpdate = NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.title.hasPrefix("Update Skyline") } == true
            AppExit.perform(.commandQ)
            try? await Task.sleep(for: .seconds(1.5))
            let closedPolicy = NSApp.activationPolicy()
            let ok = openPolicy == .regular && closedPolicy == .accessory && hasUpdate
            let line = "[dock-test] open=\(openPolicy.rawValue) closed=\(closedPolicy.rawValue) updateItem=\(hasUpdate) " + (ok ? "PASS" : "FAIL")
            print(line)
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/skyline-dock-test.txt")
            try? (line + "\n").write(to: log, atomically: true, encoding: .utf8)
            UserDefaults.standard.removeObject(forKey: DockIcon.key) // restore default (Dock on)
            NSApp.terminate(nil)
        }
    }
}
