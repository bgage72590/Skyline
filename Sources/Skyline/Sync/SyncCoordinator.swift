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
@Observable
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

    /// Fold in local changes, then merge with the file and write it on a background queue (file
    /// coordination can block for seconds with iCloud), and apply the result back here.
    func pushNow() {
        guard let fileURL, let previous = last else { return }
        if pushing { pushAgain = true; return }
        var local = SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: previous, now: Date())
        local.writtenBy = device
        pushing = true
        inFlight = local
        let io = SyncFileIO(url: fileURL, device: device)
        Task.detached(priority: .utility) { [weak self] in
            let outcome = io.mergeAndWrite(local)
            guard let self else { return }
            await self.finishPush(outcome)
        }
    }

    private var pushing = false
    private var pushAgain = false
    /// The local document handed to the background merge (to rebase edits made while it ran).
    private var inFlight: SyncDocument?

    private func finishPush(_ outcome: SyncFileIO.Outcome) {
        pushing = false
        switch outcome {
        case .synced(let doc, let note):
            // The user may have changed cities or settings while the merge ran. Applying `doc` as-is
            // would revert those edits and the follow-up push would see nothing to send (lost edit).
            let snapshot = inFlight ?? doc
            let current = SyncDocument.rebasing(locations: store.savedLocations, settings: currentSettings(),
                                                snapshot: snapshot, onto: doc, now: Date())
            if !current.sameContent(as: doc) { pushAgain = true }
            apply(current)
            lastError = note
        case .waiting(let message), .failed(let message):
            lastError = message
        }
        inFlight = nil
        if pushAgain { pushAgain = false; pushNow() }
    }

    /// Another Mac wrote the file since we last looked: merge it in.
    func pullIfChanged(force: Bool = false) {
        guard let fileURL else { return }
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if date == nil { try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL) }
        guard force || date != lastFileDate else { return }
        pushNow()
    }

    /// Persist the merged document as "last written" (state file + stamps) without touching the store.
    private func remember(_ doc: SyncDocument) {
        last = doc
        lastSynced = Date()
        if let url = fileURL {
            lastFileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        if let data = try? doc.encoded() {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func apply(_ doc: SyncDocument) {
        remember(doc)
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

/// The sync file's read-merge-write, done in ONE coordinated write (`.forMerging`) so no other process
/// can write between the read and the write, and iCloud's conflict versions (two Macs that wrote while
/// offline) are merged in and then resolved, so neither Mac's change is lost (Code Reviewer MF4/MF5).
/// Runs off the main thread.
struct SyncFileIO: Sendable {
    let url: URL
    let device: String

    enum Outcome: Sendable {
        /// Merged (and written if anything changed). `note` is a message to show (e.g. a corrupt file
        /// was set aside), else nil.
        case synced(SyncDocument, note: String?)
        /// Nothing written: the file is still downloading, or it's from a newer Skyline.
        case waiting(String)
        case failed(String)
    }

    func mergeAndWrite(_ local: SyncDocument) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var outcome: Outcome = .failed("Couldn’t open the sync file.")
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            outcome = mergeLocked(local, at: u)
        }
        if let coordError { return .failed("Couldn’t open the sync file: \(coordError.localizedDescription)") }
        return outcome
    }

    private func mergeLocked(_ local: SyncDocument, at u: URL) -> Outcome {
        let fm = FileManager.default
        var merged = local
        var note: String?
        // 1. iCloud conflict versions: merge every one in.
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: u) ?? []
        for v in conflicts {
            if let data = try? Data(contentsOf: v.url), case .document(let d) = SyncDocument.read(data) {
                merged = SyncDocument.merge(local: merged, remote: d)
            }
        }
        // 2. The current file.
        var remote: SyncDocument?
        let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
        if fm.fileExists(atPath: u.path) {
            guard let data = try? Data(contentsOf: u) else { return .waiting("Waiting for iCloud Drive to download the sync file.") }
            switch SyncDocument.read(data) {
            case .document(let d):
                remote = d
            case .newerFormat(let n):
                return .waiting("Another Mac uses a newer Skyline (sync format \(n)). Choose Update Skyline… to keep syncing.")
            case .unreadable:
                let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                if let status, status != .current {
                    try? fm.startDownloadingUbiquitousItem(at: u)
                    return .waiting("Waiting for iCloud Drive to download the sync file.")
                }
                // Fully downloaded but not a Skyline sync file (corrupt/truncated): keep a copy, rewrite.
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let aside = u.deletingLastPathComponent().appendingPathComponent("sync.corrupt-\(stamp).json")
                try? fm.moveItem(at: u, to: aside)
                note = "The sync file was damaged; it was set aside as \(aside.lastPathComponent) and rewritten from this Mac."
            }
        } else if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: u)
            return .waiting("Waiting for iCloud Drive to download the sync file.")
        }
        if let remote { merged = SyncDocument.merge(local: merged, remote: remote) }
        merged.writtenBy = device
        if remote == nil || !merged.sameContent(as: remote!) || !conflicts.isEmpty {
            merged.writtenAt = Date()
            do {
                try merged.encoded().write(to: u, options: .atomic)
            } catch {
                return .failed("Couldn’t write the sync file: \(error.localizedDescription)")
            }
        }
        // 3. Conflicts are folded in: resolve them so iCloud stops keeping both.
        if !conflicts.isEmpty {
            for v in conflicts { v.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: u)
        }
        return .synced(merged, note: note)
    }
}
