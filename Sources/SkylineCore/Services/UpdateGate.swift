import Foundation

/// Whether "Update Skyline…" must refuse another click while a download or install is in progress.
public enum UpdateGate {
    /// `ourPID` is this app process. A marker left for ourselves does not count once this process is
    /// idle (we failed to clear it). Another live pid, or the installer's lock, does.
    public static func updateInProgress(
        ourPID: Int32,
        phaseBusy: Bool,
        markerPID: Int32?,
        markerAlive: Bool,
        lockPID: Int32?,
        lockAlive: Bool
    ) -> Bool {
        if phaseBusy { return true }
        if let markerPID, markerPID > 0, markerPID != ourPID, markerAlive { return true }
        if let lockPID, lockPID > 0, lockAlive { return true }
        return false
    }

    public static func downloadingTitle(build: Int) -> String {
        "Downloading build \(build)…"
    }
}
