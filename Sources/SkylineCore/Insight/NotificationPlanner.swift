import Foundation

/// What the user turned on in Settings → Notifications (T8, L19). Everything is off by default: the
/// first switch turned on asks macOS for permission.
public struct NotificationPrefs: Codable, Equatable, Sendable {
    public var alerts = false
    public var minimumSeverity: AlertSeverity = .severe
    public var rain = false
    public var morningBriefing = false
    /// Minutes after local midnight (default 7:00 AM).
    public var briefingMinutes = 7 * 60
    public var quietHours = true
    public var quietStartMinutes = 22 * 60
    public var quietEndMinutes = 7 * 60

    public init() {}
    public var anyOn: Bool { alerts || rain || morningBriefing }

    // Tolerant decoding: a field added later (or removed) keeps the rest of the saved settings instead of
    // resetting every switch to off (Code Reviewer batch 4, NTH 5).
    enum CodingKeys: String, CodingKey {
        case alerts, minimumSeverity, rain, morningBriefing, briefingMinutes, quietHours, quietStartMinutes, quietEndMinutes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationPrefs()
        alerts = (try? c.decodeIfPresent(Bool.self, forKey: .alerts)) ?? d.alerts
        minimumSeverity = (try? c.decodeIfPresent(AlertSeverity.self, forKey: .minimumSeverity)) ?? d.minimumSeverity
        rain = (try? c.decodeIfPresent(Bool.self, forKey: .rain)) ?? d.rain
        morningBriefing = (try? c.decodeIfPresent(Bool.self, forKey: .morningBriefing)) ?? d.morningBriefing
        briefingMinutes = (try? c.decodeIfPresent(Int.self, forKey: .briefingMinutes)) ?? d.briefingMinutes
        quietHours = (try? c.decodeIfPresent(Bool.self, forKey: .quietHours)) ?? d.quietHours
        quietStartMinutes = (try? c.decodeIfPresent(Int.self, forKey: .quietStartMinutes)) ?? d.quietStartMinutes
        quietEndMinutes = (try? c.decodeIfPresent(Int.self, forKey: .quietEndMinutes)) ?? d.quietEndMinutes
    }
}

/// What was already sent, so nothing is repeated. Persisted by the app (small JSON in UserDefaults).
public struct NotificationState: Codable, Equatable, Sendable {
    public enum RainKind: String, Codable, Sendable { case start, stop }
    public struct RainNote: Codable, Equatable, Sendable {
        public var kind: RainKind
        public var sentAt: Date
    }
    /// Alert id → when it ends (forgotten after that).
    public var alerts: [String: Date] = [:]
    /// Location id → last rain notification.
    public var rain: [String: RainNote] = [:]
    /// Location id → local day ("2026-10-12") of the last morning briefing.
    public var briefingDay: [String: String] = [:]
    /// Alert key (id / VTEC event / referenced id) → highest severity already notified, so an update only
    /// notifies again when it gets more severe (QA batch 4, must-fix 1).
    public var alertSeverity: [String: AlertSeverity] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey { case alerts, rain, briefingDay, alertSeverity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alerts = (try? c.decodeIfPresent([String: Date].self, forKey: .alerts)) ?? [:]
        rain = (try? c.decodeIfPresent([String: RainNote].self, forKey: .rain)) ?? [:]
        briefingDay = (try? c.decodeIfPresent([String: String].self, forKey: .briefingDay)) ?? [:]
        alertSeverity = (try? c.decodeIfPresent([String: AlertSeverity].self, forKey: .alertSeverity)) ?? [:]
    }
}

public struct PlannedNotification: Equatable, Sendable {
    public enum Kind: String, Sendable { case alert, rainStart, rainStop, briefing }
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var locationID: String
    public var alertID: String?
    /// Delivered even in quiet hours / Focus where allowed (extreme warnings only).
    public var timeSensitive = false
}

/// Decides which notifications a fresh report should produce. Pure logic (formatting injected), so the
/// rules are unit-tested; the app only posts what this returns.
public enum NotificationPlanner {
    /// A storm-based warning must contain the point; zone-based alerts (and alerts without an outline)
    /// already cover it because they came from NWS's point query.
    public static func alertCovers(_ alert: WeatherAlert, _ point: Coordinate) -> Bool {
        guard !alert.outlineIsZone, !alert.polygons.isEmpty else { return true }
        return alert.polygons.contains { contains($0, point) }
    }

    /// Ray casting on longitude/latitude (fine at warning-polygon scale).
    public static func contains(_ ring: [Coordinate], _ p: Coordinate) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func minutesOfDay(_ date: Date, _ tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    public static func isQuiet(_ date: Date, prefs: NotificationPrefs, timeZone: TimeZone) -> Bool {
        guard prefs.quietHours, prefs.quietStartMinutes != prefs.quietEndMinutes else { return false }
        let m = minutesOfDay(date, timeZone)
        let s = prefs.quietStartMinutes, e = prefs.quietEndMinutes
        return s < e ? (m >= s && m < e) : (m >= s || m < e)
    }

    /// "Unknown" severity counts as Minor, so "All alerts" really means all (QA batch 4).
    static func effectiveSeverity(_ alert: WeatherAlert) -> AlertSeverity {
        alert.severity == .unknown ? .minor : alert.severity
    }

    /// Don't repeat a rain notification of the same kind within this long.
    public static let rainRepeatAfter: TimeInterval = 2 * 3600

    /// - Parameters:
    ///   - timeZone: the Mac's zone for quiet hours (the user's night, wherever the city is).
    ///   - timeLabel: "4:10 PM" in the report's time zone.
    public static func plan(_ report: WeatherReport, locationName: String, prefs: NotificationPrefs,
                            state: inout NotificationState, now: Date, timeZone: TimeZone = .current,
                            timeLabel: (Date) -> String) -> [PlannedNotification] {
        var out: [PlannedNotification] = []
        let quiet = isQuiet(now, prefs: prefs, timeZone: timeZone)
        let locID = report.location.id
        state.alerts = state.alerts.filter { $0.value > now }
        state.alertSeverity = state.alertSeverity.filter { state.alerts[$0.key] != nil }

        if prefs.alerts {
            for alert in report.activeAlerts(at: now).sorted(by: { $0.severity > $1.severity })
            where Self.effectiveSeverity(alert) >= prefs.minimumSeverity && !alert.isCancellation
                && alertCovers(alert, report.location.coordinate) {
                // NWS re-issues a warning as an update with a new id: the VTEC key (else the references)
                // ties it to the one already sent. An upgrade (watch → warning) has a new key and is news.
                // Cancellations are never sent (Code Reviewer batch 4, M1/M2).
                let keys = [alert.id] + (alert.trackingKeys.isEmpty ? alert.references : alert.trackingKeys)
                let until = alert.endTime ?? now.addingTimeInterval(24 * 3600)
                let seen = keys.filter { state.alerts[$0] != nil }
                let sentSeverity = seen.compactMap { state.alertSeverity[$0] }.max()
                // Already sent: an update/extension stays silent unless it became more severe.
                if !seen.isEmpty, sentSeverity.map({ alert.severity <= $0 }) ?? true {
                    for k in keys { state.alerts[k] = max(state.alerts[k] ?? until, until) }
                    continue
                }
                // Quiet hours hold back all but extreme warnings; held ones go out after, if still active.
                if quiet && alert.severity < .extreme { continue }
                var body = alert.headline ?? alert.areaDescription ?? alert.event
                // NWS headlines usually say "until …" already; don't say it twice (QA batch 4).
                if let end = alert.endTime, !body.localizedCaseInsensitiveContains("until") {
                    body += (body.hasSuffix(".") ? "" : ".") + " Until \(timeLabel(end))."
                }
                out.append(PlannedNotification(id: "alert-\(alert.id)", kind: .alert,
                                               title: "\(alert.event) · \(locationName)",
                                               body: String(body.prefix(240)), locationID: locID, alertID: alert.id,
                                               timeSensitive: alert.severity == .extreme))
                for k in keys {
                    state.alerts[k] = until
                    state.alertSeverity[k] = max(state.alertSeverity[k] ?? alert.severity, alert.severity)
                }
            }
        }

        if prefs.rain, !quiet, let note = rainNote(report, locationName: locationName, state: state, now: now, timeLabel: timeLabel) {
            out.append(note.0)
            state.rain[locID] = NotificationState.RainNote(kind: note.1, sentAt: now)
        }
        return out
    }

    /// "Rain starting in about 20 minutes" / "Rain ending around 4:10 PM" from the 15-minute nowcast.
    /// Each value covers the 15 minutes ending at its time.
    static func rainNote(_ report: WeatherReport, locationName: String, state: NotificationState, now: Date,
                         timeLabel: (Date) -> String) -> (PlannedNotification, NotificationState.RainKind)? {
        let q = report.minutely.filter { $0.time > now }.sorted { $0.time < $1.time }
        guard let first = q.first, first.time.timeIntervalSince(now) <= 15 * 60 else { return nil }
        let kind = report.current.temperature <= 0 ? "Snow" : "Rain"
        let locID = report.location.id
        let last = state.rain[locID]
        // Hysteresis against showers flapping start/stop/start (Code Reviewer batch 4, M3): a new "starting"
        // waits 90 min after any rain notice (2 h after another "starting"); "ending" needs the rain to have
        // lasted about an hour since its "starting" notice, so a passing shower gets one notice, not two.
        func allowed(_ k: NotificationState.RainKind, at eventTime: Date) -> Bool {
            guard let last else { return true }
            let since = now.timeIntervalSince(last.sentAt)
            switch (k, last.kind) {
            case (.start, .start), (.stop, .stop): return since >= rainRepeatAfter
            case (.start, .stop): return since >= 90 * 60
            case (.stop, .start): return eventTime.timeIntervalSince(last.sentAt) >= 60 * 60
            }
        }
        // Same start/stop rule as the nowcast line and the briefing (`Nowcast.rainStart` / `rainEnd`).
        if !Nowcast.isWet(first) {
            guard let startsAt = Nowcast.rainStart(report.minutely, now: now) else { return nil }
            let minutes = Nowcast.minutes(until: startsAt, now: now)
            guard startsAt.timeIntervalSince(now) >= 2.5 * 60, minutes <= 60, allowed(.start, at: startsAt) else { return nil }
            return (PlannedNotification(id: "rain-start-\(locID)-\(Int(startsAt.timeIntervalSince1970))", kind: .rainStart,
                                        title: "\(kind) starting soon · \(locationName)",
                                        body: "\(kind) starting in about \(minutes) minutes.", locationID: locID), .start)
        }
        guard let endsAt = Nowcast.rainEnd(report.minutely, now: now) else { return nil }
        let minutes = endsAt.timeIntervalSince(now) / 60
        guard minutes >= 5, minutes <= 90, allowed(.stop, at: endsAt) else { return nil }
        return (PlannedNotification(id: "rain-stop-\(locID)-\(Int(endsAt.timeIntervalSince1970))", kind: .rainStop,
                                    title: "\(kind) ending · \(locationName)",
                                    body: "\(kind) ending around \(timeLabel(endsAt)).", locationID: locID), .stop)
    }

    /// The morning briefing (L19): once per local day, from the chosen time until 3 hours after it
    /// (a Mac asleep at 7:00 gets it on wake, not at lunchtime).
    public static func briefing(_ report: WeatherReport, locationName: String, summary: String, prefs: NotificationPrefs,
                                state: inout NotificationState, now: Date, timeZone: TimeZone = .current) -> PlannedNotification? {
        guard prefs.morningBriefing else { return nil }
        let m = minutesOfDay(now, timeZone)
        // The 3-hour window wraps past midnight (a 10 PM briefing still goes out at 12:30 AM), and the
        // day it belongs to is the day it was due (QA / Code Reviewer batch 4).
        let elapsed = (m - prefs.briefingMinutes + 1440) % 1440
        guard elapsed < 180 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-Double(elapsed) * 60))
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let locID = report.location.id
        guard state.briefingDay[locID] != day else { return nil }
        state.briefingDay[locID] = day
        return PlannedNotification(id: "briefing-\(locID)-\(day)", kind: .briefing,
                                   title: "Today in \(locationName)", body: summary, locationID: locID)
    }

    /// The next moment the briefing could be due (today's time if still ahead, else tomorrow's).
    public static func nextBriefing(after now: Date, prefs: NotificationPrefs, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let h = prefs.briefingMinutes / 60, m = prefs.briefingMinutes % 60
        // Wall-clock time (correct on DST-change days), today if still ahead, else tomorrow.
        if let today = cal.date(bySettingHour: h, minute: m, second: 0, of: now), today > now { return today }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
        return cal.date(bySettingHour: h, minute: m, second: 0, of: tomorrow) ?? tomorrow
    }
}
