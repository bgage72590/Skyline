import AppKit
import Darwin
import Foundation
import Observation
import SkylineCore

/// In-memory "an update click is already in progress" flag the menus observe. The on-disk marker and
/// the installer's lock cover a second process; this covers a second click in this one.
@MainActor
@Observable
final class UpdateActivity {
    static let shared = UpdateActivity()

    enum Phase: Equatable {
        case idle
        case confirming
        case downloading(Int)
        case installing
    }

    var phase: Phase = .idle

    var isPending: Bool { phase != .idle }

    /// Set while iCloud is still materializing the zip. Nil the rest of the time, so idle menu titles stay put.
    var downloadingTitle: String? {
        if case .downloading(let build) = phase {
            return UpdateGate.downloadingTitle(build: build)
        }
        return nil
    }

    private init() {}
}

/// "Update Skyline…" (polish 2): installs the newest build from `iCloud Drive/Skyline/Skyline.zip`,
/// which `build-app.sh` on the build Mac puts there with `Skyline.version`. The work is done by the
/// verified installer inside this (signed) app: it checks the new app is signed by the build Mac's
/// certificate and newer than this one, then replaces /Applications/Skyline.app and relaunches.
/// Nothing runs in the background; the iCloud folder is read only when the menu item is chosen.
@MainActor
enum Updater {
    private static let downloadTimeout: TimeInterval = 300

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
        clearStaleMarker()
        if updateAlreadyRunning() {
            alreadyRunningAlert()
            return
        }
        UpdateActivity.shared.phase = .confirming
        let alert = NSAlert()
        guard let zip = zipURL else {
            UpdateActivity.shared.phase = .idle
            alert.messageText = "iCloud Drive is off"
            alert.informativeText = "Skyline updates come from iCloud Drive/Skyline/Skyline.zip, which the build Mac puts there."
            alert.runModal(); return
        }
        // Start the download while the confirm dialog is up, so a local zip is ready when they click Update.
        kickDownload(of: zip)
        let available = availableBuild()
        guard let available, available > installedBuild else {
            UpdateActivity.shared.phase = .idle
            alert.messageText = "Skyline is up to date"
            alert.informativeText = "This Mac has build \(installedBuild)" + (available.map { "; iCloud Drive has build \($0)." } ?? ".")
                + " New builds appear after ./build-app.sh runs on the build Mac."
            alert.runModal(); return
        }
        alert.messageText = "Update Skyline to build \(available)?"
        alert.informativeText = "This Mac has build \(installedBuild). Skyline checks the new app is signed by your build Mac, then installs it and relaunches (a few seconds)."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UpdateActivity.shared.phase = .idle
            return
        }
        if !zipIsLocal(zip) {
            UpdateActivity.shared.phase = .downloading(available)
            writeMarker(pid: ProcessInfo.processInfo.processIdentifier)
            switch waitUntilLocal(zip, build: available) {
            case .ready:
                break
            case .cancelled:
                clearMarker(ifPID: ProcessInfo.processInfo.processIdentifier)
                UpdateActivity.shared.phase = .idle
                return
            case .timedOut:
                clearMarker(ifPID: ProcessInfo.processInfo.processIdentifier)
                UpdateActivity.shared.phase = .idle
                fail("Skyline.zip didn't download from iCloud within 5 minutes. Check iCloud Drive, then try again. Nothing changed.")
                return
            }
        }
        UpdateActivity.shared.phase = .installing
        install(zip: zip)
    }

    private static func install(zip: URL) {
        guard let script = Bundle.main.url(forResource: "install-verified", withExtension: "sh") else {
            clearMarker(ifPID: ProcessInfo.processInfo.processIdentifier)
            UpdateActivity.shared.phase = .idle
            fail("This copy of Skyline has no installer inside. Install once with the one-line command in the README.")
            return
        }
        let log = newResultLogURL()
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Detached so it outlives this process: the installer quits Skyline, replaces it and reopens it.
        // On failure the log is left in place and Skyline is reopened; showUpdateResultIfNeeded reads it (U2).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", UpdateScript.command(installer: script.path, newerThan: installedBuild, zip: zip.path, resultLog: log.path)]
        do {
            try p.run()
        } catch {
            clearMarker(ifPID: ProcessInfo.processInfo.processIdentifier)
            UpdateActivity.shared.phase = .idle
            fail(error.localizedDescription)
            return
        }
        // The shell we just spawned holds the install until it finishes. A relaunch sees this pid (and the
        // script's lock) and will not start a second one.
        writeMarker(pid: p.processIdentifier)
        AppExit.perform(.quitCompletely)
    }

    /// After a failed Update Skyline… the installer leaves a log; show the newest one and remove them (U2).
    static func showUpdateResultIfNeeded() {
        clearStaleMarker()
        let logs = failureLogURLs()
        guard !logs.isEmpty else { return }
        let body = logs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        logs.forEach { try? FileManager.default.removeItem(at: $0) }
        guard let body else { return }
        let a = NSAlert()
        a.messageText = "Couldn’t update Skyline"
        a.informativeText = body
        a.runModal()
    }

    private static func alreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "Skyline is already updating"
        alert.informativeText = "Another Skyline update is already running; nothing changed."
        alert.runModal()
    }

    private static func fail(_ message: String) {
        let a = NSAlert(); a.messageText = "Couldn’t update Skyline"; a.informativeText = message; a.runModal()
    }

    private static func updateAlreadyRunning() -> Bool {
        let our = ProcessInfo.processInfo.processIdentifier
        let marker = readPID(at: markerURL)
        let lock = readPID(at: installLockURL.appendingPathComponent("pid"))
        return UpdateGate.updateInProgress(
            ourPID: our,
            phaseBusy: UpdateActivity.shared.isPending,
            markerPID: marker,
            markerAlive: marker.map(processAlive) ?? false,
            lockPID: lock,
            lockAlive: lock.map(processAlive) ?? false)
    }

    private static func kickDownload(of zip: URL) {
        let fm = FileManager.default
        try? fm.startDownloadingUbiquitousItem(at: zip)
        let sha = zip.deletingLastPathComponent().appendingPathComponent("Skyline.sha256")
        try? fm.startDownloadingUbiquitousItem(at: sha)
    }

    /// A ubiquitous item counts as local only once iCloud says the bytes are current. Anything else
    /// (a normal file, or a ubiquitous item with no status) is local when it has a non-zero size.
    static func zipIsLocal(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
        let size = values.fileSize ?? 0
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus {
            // `.current` is the downloaded state. `.notDownloaded` is still a placeholder. Any other
            // status (including the older "downloaded") is local only when the file has bytes.
            if status == .notDownloaded { return false }
            if status == .current { return size > 0 }
            return size > 0
        }
        return size > 0
    }

    private enum DownloadWait {
        case ready, cancelled, timedOut
    }

    /// Pumps the run loop so the "Downloading build N…" sheet can show a Cancel button. Returns only
    /// once the zip is local, the user cancels, or five minutes pass. The app is still running.
    private static func waitUntilLocal(_ zip: URL, build: Int) -> DownloadWait {
        if zipIsLocal(zip) { return .ready }
        kickDownload(of: zip)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = UpdateGate.downloadingTitle(build: build)
        alert.informativeText = "Waiting for iCloud Drive to finish downloading Skyline.zip. Skyline will quit and install it once the file is on this Mac."
        alert.addButton(withTitle: "Cancel")
        let host = progressHost()
        defer { if host.owned { host.window.close() } }
        var outcome: DownloadWait?
        alert.beginSheetModal(for: host.window) { _ in
            if outcome == nil { outcome = .cancelled }
        }
        let deadline = Date().addingTimeInterval(downloadTimeout)
        while outcome == nil {
            if zipIsLocal(zip) {
                outcome = .ready
                host.window.endSheet(alert.window)
                break
            }
            if Date() >= deadline {
                outcome = .timedOut
                host.window.endSheet(alert.window)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return outcome ?? .timedOut
    }

    private struct ProgressHost {
        var window: NSWindow
        var owned: Bool
    }

    private static func progressHost() -> ProgressHost {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            return ProgressHost(window: window, owned: false)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Skyline"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        return ProgressHost(window: window, owned: true)
    }

    private static var markerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.briangage.Skyline/update-in-progress")
    }

    /// Same path install-verified.sh locks (`${TMPDIR:-/tmp}/skyline-install.lock`).
    private static var installLockURL: URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("skyline-install.lock")
    }

    private static func writeMarker(pid: Int32) {
        let url = markerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    private static func clearMarker(ifPID pid: Int32) {
        guard readPID(at: markerURL) == pid else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func clearStaleMarker() {
        guard let pid = readPID(at: markerURL) else { return }
        let ours = pid == ProcessInfo.processInfo.processIdentifier
        if (ours && !UpdateActivity.shared.isPending) || !processAlive(pid) {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    private static func readPID(at url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Int32(line.trimmingCharacters(in: .whitespaces))
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func newResultLogURL() -> URL {
        let token = UUID().uuidString
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent(UpdateScript.resultLogFileName(token: token))
    }

    private static func failureLogURLs() -> [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let logs = files.filter { UpdateScript.isFailureLogName($0.lastPathComponent) }
        return logs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }
}
