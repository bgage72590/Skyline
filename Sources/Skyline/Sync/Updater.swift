import AppKit
import Foundation

/// "Update Skyline…" (polish 2): installs the newest build from `iCloud Drive/Skyline/Skyline.zip`,
/// which `build-app.sh` on the build Mac puts there with `Skyline.version`. The work is done by the
/// verified installer inside this (signed) app: it checks the new app is signed by the build Mac's
/// certificate and newer than this one, then replaces /Applications/Skyline.app and relaunches.
/// Nothing runs in the background; the iCloud folder is read only when the menu item is chosen.
@MainActor
enum Updater {
    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static var zipURL: URL? { SyncCoordinator.iCloudFolder()?.appendingPathComponent("Skyline.zip") }

    /// The build waiting in iCloud Drive, if its number file is there.
    static func availableBuild() -> Int? {
        guard let folder = SyncCoordinator.iCloudFolder() else { return nil }
        let file = folder.appendingPathComponent("Skyline.version")
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func checkForUpdates() {
        NSApp.activate()
        let alert = NSAlert()
        guard let zip = zipURL else {
            alert.messageText = "iCloud Drive is off"
            alert.informativeText = "Skyline updates come from iCloud Drive/Skyline/Skyline.zip, which the build Mac puts there."
            alert.runModal(); return
        }
        let available = availableBuild()
        guard let available, available > installedBuild else {
            alert.messageText = "Skyline is up to date"
            alert.informativeText = "This Mac has build \(installedBuild)" + (available.map { "; iCloud Drive has build \($0)." } ?? ".")
                + " New builds appear after ./build-app.sh runs on the build Mac."
            alert.runModal(); return
        }
        alert.messageText = "Update Skyline to build \(available)?"
        alert.informativeText = "This Mac has build \(installedBuild). Skyline checks the new app is signed by your build Mac, then installs it and relaunches (a few seconds)."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(zip: zip)
    }

    private static func install(zip: URL) {
        guard let script = Bundle.main.url(forResource: "install-verified", withExtension: "sh") else {
            fail("This copy of Skyline has no installer inside. Install once with the one-line command in the README.")
            return
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("skyline-update.log")
        // Detached so it outlives this process: the installer quits Skyline, replaces it and reopens it.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        p.arguments = ["-c", "sleep 1; /bin/bash \(q(script.path)) --newer-than \(installedBuild) \(q(zip.path)) > \(q(log.path)) 2>&1 || open -a Skyline"]
        do {
            try p.run()
        } catch {
            fail(error.localizedDescription); return
        }
        AppExit.perform(.quitCompletely)
    }

    private static func fail(_ message: String) {
        let a = NSAlert(); a.messageText = "Couldn’t update Skyline"; a.informativeText = message; a.runModal()
    }
}
