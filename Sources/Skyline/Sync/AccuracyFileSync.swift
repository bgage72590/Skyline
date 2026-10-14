import Foundation
import SkylineCore

/// Shares the accuracy learning through `iCloud Drive/Skyline/accuracy.json` (build 32, code review H1/H2).
///
/// Runs entirely off the main thread (this actor plus the verifier actor). Cost:
/// * one `stat` per call (sync.json's checks: launch, activation, wake, forecast refresh);
/// * the file is read and merged only when another Mac changed it;
/// * it is written only when this Mac verified new pairs (at most every 3 h, the issue interval) or
///   reset its accuracy data, and only if the merge holds something the file lacks.
actor AccuracyFileSync {
    static let minPushInterval: TimeInterval = ForecastVerifier.issueInterval

    let url: URL
    let verifier: ForecastVerifier
    private var lastFileDate: Date?
    private var lastPush: Date?

    init(url: URL, verifier: ForecastVerifier) {
        self.url = url
        self.verifier = verifier
    }

    private var gate = CoalescingGate()

    /// Returns true when this Mac's accuracy history changed (the scorecards should refresh).
    /// One sync at a time (build-32 review M1): the actor is re-entrant at each `await`, so a call that
    /// arrives while one is running is folded into a single follow-up pass instead of overlapping it
    /// (overlapping passes could both mark the same unsynced pairs as synced).
    func run(force: Bool) async -> Bool {
        guard gate.begin(force: force) else { return false }
        var changed = await runOnce(force: force)
        while let f = gate.next() { changed = await runOnce(force: f) || changed }
        return changed
    }

    private func runOnce(force: Bool) async -> Bool {
        let date = modificationDate()
        let remoteChanged = date == nil ? false : date != lastFileDate
        let unsynced = await verifier.unsyncedPairCount
        let resetPending = await verifier.hasUnsyncedReset
        let pushDue = lastPush.map { Date().timeIntervalSince($0) >= Self.minPushInterval } ?? true
        let wantPush = force || resetPending || (unsynced > 0 && pushDue) || (date == nil && unsynced > 0)
        guard remoteChanged || wantPush else { return false }

        let local = await verifier.syncFile()
        guard let result = mergeAndMaybeWrite(local, write: wantPush) else { return false }
        if result.wrote || !result.hasNew {
            // The file now has everything `local` had.
            await verifier.markSynced(pairs: unsynced, reset: local.reset)
        }
        if result.wrote { lastPush = Date() }
        lastFileDate = modificationDate()
        return await verifier.absorb(result.file)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private struct Result { var file: AccuracyFile; var hasNew: Bool; var wrote: Bool }

    /// One coordinated read-merge-(write), like sync.json: iCloud conflict versions are merged in and
    /// resolved. Nil when the file can't be read yet (still downloading) or is from a newer Skyline.
    private func mergeAndMaybeWrite(_ local: AccuracyFile, write: Bool) -> Result? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var result: Result?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            let now = Date()
            let fileDate = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
            var remote: AccuracyFile?
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: u) ?? []
            for v in conflicts {
                if let data = try? Data(contentsOf: v.url), let f = AccuracyFile.decode(data) {
                    remote = remote.map { AccuracyFile.merge(local: $0, remote: f, now: now, remoteFileDate: v.modificationDate).file } ?? f
                }
            }
            if fm.fileExists(atPath: u.path) {
                guard let data = try? Data(contentsOf: u) else { return }
                guard let f = AccuracyFile.decode(data) else {
                    let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                    if let status, status != .current { try? fm.startDownloadingUbiquitousItem(at: u); return }
                    // Newer format: leave it alone. Damaged: rewritten from this Mac's pairs below (it holds
                    // only accuracy pairs, which every Mac also keeps locally).
                    if let peek = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let v = peek["v"] as? Int, v > AccuracyFile.currentFormat { return }
                    let merged = AccuracyFile.merge(local: local, remote: remote, now: now, remoteFileDate: fileDate)
                    result = Result(file: merged.file, hasNew: true, wrote: write && Self.write(merged.file, to: u))
                    return
                }
                remote = remote.map { AccuracyFile.merge(local: $0, remote: f, now: now, remoteFileDate: fileDate).file } ?? f
            } else {
                let placeholder = u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".icloud")
                if fm.fileExists(atPath: placeholder.path) { try? fm.startDownloadingUbiquitousItem(at: u); return }
            }
            let merged = AccuracyFile.merge(local: local, remote: remote, now: now, remoteFileDate: fileDate)
            let needsWrite = merged.hasNew || !conflicts.isEmpty
            let wrote = write && needsWrite && Self.write(merged.file, to: u)
            if wrote, !conflicts.isEmpty {
                for v in conflicts { v.isResolved = true }
                try? NSFileVersion.removeOtherVersionsOfItem(at: u)
            }
            result = Result(file: merged.file, hasNew: merged.hasNew, wrote: wrote)
        }
        if coordError != nil { return nil }
        return result
    }

    private static func write(_ file: AccuracyFile, to u: URL) -> Bool {
        var file = file
        file.writtenAt = Date()
        guard let data = try? file.encoded() else { return false }
        return (try? data.write(to: u, options: .atomic)) != nil
    }
}
