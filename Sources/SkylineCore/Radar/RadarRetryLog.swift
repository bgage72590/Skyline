import Foundation
#if os(macOS)
import os
#endif

/// One debug line per retry or back-off burst, so a reopen trace shows which path stalled.
/// `os_log` at `.debug`: subsystem `com.briangage.Skyline`, category `radar`.
public enum RadarRetryLog {
    #if os(macOS)
    private static let log = OSLog(subsystem: "com.briangage.Skyline", category: "radar")
    #endif
    private static let gate = Gate()

    /// `path` is `provisional` (mask not ready, 5 s), `transient` (tile fetch failed, 5 s),
    /// or `raster` (scan fetch still inside its 10 s back-off).
    public static func backoff(path: String, seconds: Double) {
        guard gate.shouldLog(path, now: Date()) else { return }
        #if os(macOS)
        os_log("radar retry path=%{public}@ delay=%d s", log: log, type: .debug, path, Int(seconds.rounded()))
        #endif
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private var at = Date.distantPast
        func shouldLog(_ path: String, now: Date) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if self.path == path, now.timeIntervalSince(at) < 2 { return false }
            self.path = path
            self.at = now
            return true
        }
    }
}
