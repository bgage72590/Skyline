import AppKit
import Foundation
import SkylineCore

/// Keeps saved cities and settings the same on all of Brian's Macs through `iCloud Drive/Skyline/sync.json`
/// (see `SyncDocument` for why a file and how merging works).
///
/// Cost: no timers and no file watching. It writes ~2 s after a synced setting or the city list changes,
/// and checks the file's date (one `stat`) at launch, when the app becomes active, after wake and on
/// each forecast refresh. A different date means another Mac wrote it: read, merge, apply.
@MainActor
final class SyncCoordinator {
    static private(set) var shared: SyncCoordinator?

    /// UserDefaults keys worth carrying between Macs. Window state, notification history, the last GPS
    /// fix and caches stay per-Mac.
    static let settingKeys = ["unitPreference", "unit.temperature", "unit.speed", "unit.precipitation", "unit.pressure",
                              "unit.distance", "clockStyle", "refreshMinutes", "menuBarLocationID",
                              "notifications.prefs.v1", "notifications.locations.v1"]

    private unowned let store: WeatherStore
    private let defaults: UserDefaults
    let fileURL: URL?
    private let stateURL: URL
    private let device = Host.current().localizedName ?? "Mac"
    /// What this Mac last wrote or applied (the "previous" for spotting local changes).
    private var last: SyncDocument?
    private var lastFileDate: Date?
    private var pushTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var lastSynced: Date?
    private(set) var lastError: String?

    static func iCloudFolder() -> URL? {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docs.path) else { return nil }
        return docs.appendingPathComponent("Skyline", isDirectory: true)
    }

    static func start(store: WeatherStore, defaults: UserDefaults = .standard) {
        // QA hook: `-SkylineSyncFile <path>` syncs through another file (tests two "Macs" on one).
        let override = defaults.string(forKey: "SkylineSyncFile").map { URL(fileURLWithPath: $0) }
        let url = override ?? iCloudFolder()?.appendingPathComponent("sync.json")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.briangage.Skyline", isDirectory: true)
        let state = support.appendingPathComponent(override == nil ? "sync-state.json" : "sync-state-test.json")
        shared = SyncCoordinator(store: store, defaults: defaults, fileURL: url, stateURL: state)
        shared?.begin()
    }

    private init(store: WeatherStore, defaults: UserDefaults, fileURL: URL?, stateURL: URL) {
        self.store = store
        self.defaults = defaults
        self.fileURL = fileURL
        self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL) { last = SyncDocument.decode(data) }
    }

    private func begin() {
        guard fileURL != nil else { lastError = "iCloud Drive is off on this Mac; cities stay on this Mac."; return }
        if last == nil {
            // First run with sync (migration): everything this Mac has is kept and merged in.
            last = SyncDocument.migrating(locations: store.savedLocations, settings: currentSettings(), now: Date())
            pushNow()
        } else {
            pullIfChanged(force: true)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePush() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullIfChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullIfChanged() }
        })
    }

    func currentSettings() -> [String: String] {
        var out: [String: String] = [:]
        for key in Self.settingKeys {
            if let v = SyncValue.encode(defaults.object(forKey: key)) { out[key] = v }
        }
        return out
    }

    /// Local change: write soon (coalesces bursts, e.g. a reorder or several settings).
    private func schedulePush() {
        guard fileURL != nil, let last else { return }
        let changed = SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: last, now: Date())
        guard !changed.sameContent(as: last) else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    /// Fold in local changes, merge with the file, write it, and apply anything that came from elsewhere.
    func pushNow() {
        guard let fileURL, let previous = last else { return }
        var local = SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: previous, now: Date())
        local.writtenBy = device
        let remote = readFile()
        if remote == nil && fileExistsSomewhere(fileURL) {
            // There is a file (or an iCloud placeholder) we couldn't read yet: never overwrite it with
            // only this Mac's cities. Try again on the next check.
            requestDownload(fileURL)
            lastError = "Waiting for iCloud Drive to download the sync file."
            return
        }
        var merged = remote.map { SyncDocument.merge(local: local, remote: $0) } ?? local
        merged.writtenBy = device
        merged.writtenAt = Date()
        if remote == nil || !merged.sameContent(as: remote!) {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(merged, to: fileURL)
            } catch {
                lastError = "Couldn’t write the sync file: \(error.localizedDescription)"
                return
            }
        }
        apply(merged)
    }

    /// Another Mac wrote the file since we last looked: merge it in.
    func pullIfChanged(force: Bool = false) {
        guard let fileURL else { return }
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if date == nil { requestDownload(fileURL) }
        guard force || date != lastFileDate else { return }
        pushNow()
    }

    private func readFile() -> SyncDocument? {
        guard let fileURL else { return nil }
        var result: SyncDocument?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &error) { url in
            if let data = try? Data(contentsOf: url) { result = SyncDocument.decode(data) }
        }
        return result
    }

    private func write(_ doc: SyncDocument, to url: URL) throws {
        let data = try doc.encoded()
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    private func fileExistsSomewhere(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    /// iCloud may have the file only in the cloud (a `.sync.json.icloud` placeholder): ask for it.
    private func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private func apply(_ doc: SyncDocument) {
        last = doc
        lastSynced = Date()
        lastError = nil
        if let url = fileURL {
            lastFileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        if let data = try? doc.encoded() {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
        // Settings first (units affect how cities render), then the list. Unchanged values aren't touched.
        var settingsChanged = false
        for key in Self.settingKeys {
            let want = doc.settings[key]
            if SyncValue.encode(defaults.object(forKey: key)) == want { continue }
            if let want, let value = SyncValue.decode(want) { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            settingsChanged = true
        }
        if settingsChanged { store.reloadSyncedSettings() }
        if doc.locations != store.savedLocations { store.applySyncedLocations(doc.locations) }
    }
}
