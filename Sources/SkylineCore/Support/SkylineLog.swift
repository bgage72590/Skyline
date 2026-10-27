import Foundation
#if canImport(os)
import os
#endif

/// Shared os_log loggers for refresh scheduling and Open-Meteo quota events.
/// City ids and coordinates are `.private`; ordinal, role, age, and reason are `.public`.
public enum SkylineLog {
    public static let subsystem = "com.briangage.Skyline"

    #if canImport(os)
    public static let refresh = Logger(subsystem: subsystem, category: "refresh")
    public static let quota = Logger(subsystem: subsystem, category: "quota")
    #endif

    public static func refreshSummary(dueFresh: Int, dueBackground: Int, windowVisible: Bool) {
        #if canImport(os)
        refresh.info("plan dueFresh=\(dueFresh, privacy: .public) dueBackground=\(dueBackground, privacy: .public) visible=\(windowVisible, privacy: .public)")
        #endif
    }

    public static func refreshCity(ordinal: Int, role: String, ageMinutes: Int?, reason: String) {
        #if canImport(os)
        let age = ageMinutes.map(String.init) ?? "none"
        refresh.info("city ordinal=\(ordinal, privacy: .public) role=\(role, privacy: .public) ageMin=\(age, privacy: .public) reason=\(reason, privacy: .public)")
        #endif
    }

    public static func refreshEnqueue(count: Int) {
        #if canImport(os)
        refresh.info("enqueue count=\(count, privacy: .public)")
        #endif
    }

    public static func refreshDequeue(ordinal: Int?) {
        #if canImport(os)
        let o = ordinal.map(String.init) ?? "?"
        refresh.info("dequeue ordinal=\(o, privacy: .public)")
        #endif
    }

    public static func refreshHide(kept: Int, dropped: Int) {
        #if canImport(os)
        refresh.info("hide kept=\(kept, privacy: .public) dropped=\(dropped, privacy: .public)")
        #endif
    }

    public static func refreshDropdown(ordinals: [Int]) {
        #if canImport(os)
        let s = ordinals.map(String.init).joined(separator: ",")
        refresh.info("dropdown ordinals=\(s, privacy: .public)")
        #endif
    }

    public static func quotaDailyLimit(host: String, until: Date?) {
        #if canImport(os)
        let u = until.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"
        quota.info("dailyLimit host=\(host, privacy: .public) until=\(u, privacy: .public)")
        #endif
    }

    public static func quotaThrottled(host: String, until: Date?) {
        #if canImport(os)
        let u = until.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"
        quota.info("throttled host=\(host, privacy: .public) until=\(u, privacy: .public)")
        #endif
    }
}
