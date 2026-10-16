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
    /// accuracy.json next to sync.json (nil without iCloud Drive or a verifier).
    @ObservationIgnored private var accuracySync: AccuracyFileSync?
    @ObservationIgnored private var lastLegacyFingerprint: LegacyAccuracyFingerprint?

    static func iCloudFolder() -> URL? {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: docs.path) else { return nil }
        return docs.appendingPathComponent("Skyline", isDirectory: true)
    }

    /// Item 1: `env` comes from `SyncEnvironment.resolve` (real bundle only, or the isolated
    /// `-SkylineSyncFile` override); no environment means no sync.
    static func start(store: WeatherStore, defaults: UserDefaults, env: SyncEnvironment) {
        shared = SyncCoordinator(store: store, defaults: defaults, fileURL: env.fileURL, stateURL: env.stateURL,
                                 deletions: DeletionLog(url: env.deletionsURL), isOverride: env.isOverride)
        shared?.begin()
    }

    /// The user's deletes (item 1), the only source of tombstones.
    let deletions: DeletionLog
    private let isOverride: Bool

    private init(store: WeatherStore, defaults: UserDefaults, fileURL: URL?, stateURL: URL,
                 deletions: DeletionLog, isOverride: Bool) {
        self.store = store
        self.deletions = deletions
        self.isOverride = isOverride
        self.defaults = defaults
        self.fileURL = fileURL
        self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL) { last = SyncDocument.decode(data) }
        if let fileURL, let verifier = store.service.verifier {
            let name = fileURL.lastPathComponent == "sync.json" ? "accuracy.json"
                : fileURL.deletingPathExtension().lastPathComponent + "-accuracy.json"
            accuracySync = AccuracyFileSync(url: fileURL.deletingLastPathComponent().appendingPathComponent(name), verifier: verifier)
        }
    }

    private func begin() {
        guard fileURL != nil else { lastError = "iCloud Drive is off on this Mac; cities stay on this Mac."; return }
        if last == nil {
            // First run with sync (migration): everything this Mac has is kept and merged in.
            last = SyncDocument.migrating(locations: store.savedLocations, settings: currentSettings(), now: Date())
            pushNow()
            syncAccuracy(force: true)
        } else {
            reconcileAtLaunch()
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

    /// Item 1: a city that was synced but isn't in this Mac's defaults at launch wasn't removed by the
    /// user, so put it back instead of letting the next push record it as a removal. Then, once, bring
    /// back cities an earlier wipe tombstoned (batch removals) and any from the legacy "Skyline" domain.
    private func reconcileAtLaunch() {
        guard let previous = last else { return }
        // The legacy "Skyline" domain (unbundled runs) only supplies names; never in override (QA) runs.
        let legacy = isOverride ? [] : UserDefaults(suiteName: "Skyline")?.data(forKey: "savedLocations.v1")
            .flatMap { try? JSONDecoder().decode([WeatherLocation].self, from: $0) } ?? []
        let plan = LaunchSync.plan(local: store.savedLocations, last: previous, deletions: deletions.entries,
                                   legacy: legacy, defaults: defaults)
        if plan.cities != store.savedLocations { store.applySyncedLocations(plan.cities) }
        if !plan.recovered.isEmpty { store.nameRecoveredLocations(plan.recovered) }
    }

    /// Called by the delete action before anything else: written to disk synchronously.
    func recordDeletion(_ id: String) { deletions.record(id) }
    /// A re-add (search, undo) cancels this Mac's delete.
    func forgetDeletion(_ id: String) { deletions.forget(id) }

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
        let changed = SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: last, now: Date(), deletions: deletions.entries)
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
        var local = SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: previous, now: Date(), deletions: deletions.entries)
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
                                                snapshot: snapshot, onto: doc, now: Date(),
                                                deletions: deletions.entries)
            if current.sameContent(as: doc) {
                apply(doc)
            } else {
                // `last` must be what is actually in the file (doc), not the unwritten rebase; otherwise a
                // failed follow-up push leaves the edits recorded as "synced" and schedulePush never sends
                // them until relaunch / another Mac writes.
                remember(doc)
                applyToStore(current)
                pushAgain = true
            }
            lastError = note
            absorbLegacyAccuracy(from: doc)
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
        syncAccuracy(force: force)
        // M4: a push that failed (iCloud offline, coordination error) left local edits unsent; retry them on
        // the next check (refresh, activation, wake) even though the file date hasn't changed.
        guard force || date != lastFileDate || hasUnsentLocalChanges() else { return }
        pushNow()
    }

    /// Cities or settings differ from what was last written or applied (cheap: cities and settings only).
    private func hasUnsentLocalChanges() -> Bool {
        guard let last, !pushing else { return false }
        return !SyncDocument.noting(locations: store.savedLocations, settings: currentSettings(), previous: last, now: Date(), deletions: deletions.entries)
            .sameContent(as: last)
    }

    // MARK: Accuracy learning (build 32: accuracy.json, see AccuracyFileSync)

    /// Reads accuracy.json when another Mac changed it and writes it when this Mac has new pairs, all off
    /// the main thread (H1/H2). Then refreshes the scorecards if the local history changed.
    private func syncAccuracy(force: Bool = false) {
        guard let accuracySync else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard await accuracySync.run(force: force) else { return }
            await self?.refreshAllAccuracy()
        }
    }

    /// While a build-31 Mac still shares pairs through sync.json, fold them into this Mac's history (off
    /// main, in the verifier) so the Macs' learning doesn't split (build-32 review N-H1). A build-31 reset
    /// counts as generation 1.
    private func absorbLegacyAccuracy(from doc: SyncDocument) {
        guard let verifier = store.service.verifier, doc.accuracy != nil || doc.accuracyResetAt != nil else { return }
        // Only when the build-31 data changed since the last absorb (build-34 review L2).
        let fingerprint = LegacyAccuracyFingerprint(doc)
        guard fingerprint != lastLegacyFingerprint else { return }
        lastLegacyFingerprint = fingerprint
        // A build-31 reset is generation 0, so it never undoes a reset made on build 32+ (QA build-34 SF-A).
        let file = AccuracyFile(reset: doc.accuracyResetAt.map { AccuracyReset(generation: 0, at: $0) }, pairs: doc.accuracy ?? [])
        Task.detached(priority: .utility) { [weak self] in
            guard await verifier.absorb(file) else { return }
            await self?.refreshAllAccuracy()
        }
    }

    private func refreshAllAccuracy() async {
        for location in store.allLocations { await store.refreshAccuracy(for: location) }
    }

    /// Persist the merged document as "last written" (state file + stamps) without touching the store.
    private func remember(_ doc: SyncDocument) {
        last = doc
        lastSynced = Date()
        if let url = fileURL {
            lastFileDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        // Encode and write off the main thread (H2); one serial queue keeps the writes in order.
        let url = stateURL
        Self.stateQueue.async {
            guard let data = try? doc.encoded() else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let stateQueue = DispatchQueue(label: "com.briangage.Skyline.sync-state", qos: .utility)

    private func apply(_ doc: SyncDocument) {
        remember(doc)
        applyToStore(doc)
    }

    /// Push `doc`'s settings and cities into UserDefaults / the store (does not touch `last`).
    private func applyToStore(_ doc: SyncDocument) {
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
