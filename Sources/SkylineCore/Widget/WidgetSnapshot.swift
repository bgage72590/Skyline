import Foundation

/// What the desktop / Notification Center widgets show (T22): a small, self-contained copy of the
/// menu-bar city's latest report, written by the app and read by the sandboxed widget extension, which
/// has no network access of its own. Temperatures stay in °C; the widget formats with `units`.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    public static let fileName = "widget-snapshot.json"
    /// Under the real home directory (the widget's sandbox has a read-only exception for exactly this).
    public static let relativeDirectory = "Library/Application Support/com.briangage.Skyline/Widget"

    public struct Hour: Codable, Equatable, Sendable {
        public var time: Date
        public var temperature: Double
        public var weatherCode: Int
        public var isDay: Bool
        public var precipitationProbability: Double?
    }
    public struct Day: Codable, Equatable, Sendable {
        public var date: Date
        public var weatherCode: Int
        public var high: Double
        public var low: Double
        public var precipitationProbability: Double?
        public var snowfallSum: Double?
    }

    public var version = WidgetSnapshot.version
    public var writtenAt: Date
    /// When the weather data itself was fetched (an offline fallback can be older than `writtenAt`).
    public var dataTime: Date
    public var locationName: String
    public var timeZoneIdentifier: String
    public var temperature: Double
    public var weatherCode: Int
    public var isDay: Bool
    public var high: Double?
    public var low: Double?
    public var hours: [Hour]
    public var days: [Day]
    public var minutely: [MinutelyPrecipitation]
    /// "Tornado Warning" etc., most severe active alert (Moderate and up).
    public var alert: String?
    public var units: DisplayUnits

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
    public var condition: WeatherCondition { WeatherCondition(wmoCode: weatherCode) }

    /// Older than this, the widget says how old its data is.
    public static let staleAfter: TimeInterval = 2 * 3600

    public init(report: WeatherReport, locationName: String, units: DisplayUnits, now: Date = Date()) {
        writtenAt = now
        dataTime = report.fetchedAt
        self.locationName = locationName
        timeZoneIdentifier = report.timeZoneIdentifier
        temperature = report.current.temperature
        weatherCode = report.current.weatherCode
        isDay = report.current.isDay
        high = report.today?.high
        low = report.today?.low
        // The hour under way first (same rule as the app's strip), and a day's worth, so a widget the app
        // hasn't refreshed for a while still has hours to show (QA batch 6 W1/W2).
        hours = report.upcomingHours(from: now, count: 26).map {
            Hour(time: $0.time, temperature: $0.temperature, weatherCode: $0.weatherCode, isDay: $0.isDay,
                 precipitationProbability: $0.precipitationProbability)
        }
        days = report.daily.prefix(5).map {
            Day(date: $0.date, weatherCode: $0.weatherCode, high: $0.high, low: $0.low,
                precipitationProbability: $0.precipitationProbability, snowfallSum: $0.snowfallSum)
        }
        let horizon = now.addingTimeInterval(2.5 * 3600)
        minutely = report.minutely.filter { $0.time > now.addingTimeInterval(-900) && $0.time <= horizon }
        alert = report.activeAlerts(at: now).filter { $0.severity >= .moderate && !$0.isCancellation }
            .max(by: { $0.severity < $1.severity })?.event
        self.units = units
    }

    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(dataTime) > Self.staleAfter }

    /// The same next-2-hours line the app shows ("Rain starting in about 20 min"), at `now`, or a calm
    /// default when no rain is due.
    public func rainLine(at now: Date) -> String {
        if let s = Nowcast.summary(minutely, now: now, temperature: temperature) { return s }
        return minutely.contains(where: { $0.time > now }) ? "No rain in the next 2 hours" : ""
    }

    /// Hours from the one under way (it started less than an hour ago), like the app's
    /// `upcomingHours`, so the widget's first slot is the app's "Now".
    public func hours(from now: Date, count: Int) -> [Hour] {
        Array(hours.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(count))
    }

    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }

    /// Days from the city's current date on: after midnight a snapshot from yesterday rolls forward
    /// instead of calling yesterday "Today" (QA batch 6 W2).
    public func days(from now: Date) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return days.filter { calendar.startOfDay(for: $0.date) >= today }
    }

    /// "Today", "Tomorrow" or nil (use the weekday), by date in the city's zone, not by position.
    public func dayLabel(_ day: Day, now: Date) -> String? {
        let c = calendar
        let diff = c.dateComponents([.day], from: c.startOfDay(for: now), to: c.startOfDay(for: day.date)).day ?? 99
        return diff == 0 ? "Today" : diff == 1 ? "Tomorrow" : nil
    }

    /// Today's high/low at `now`: the snapshot's own while it's still the same date, else that date's row.
    public func highLow(at now: Date) -> (high: Double, low: Double)? {
        if calendar.isDate(now, inSameDayAs: dataTime) || calendar.isDate(now, inSameDayAs: writtenAt),
           let high, let low { return (high, low) }
        guard let d = days(from: now).first, calendar.isDate(d.date, inSameDayAs: now) else { return nil }
        return (d.high, d.low)
    }

    /// Timeline entries: now, then every 15 min for 2 h, so "starting in about 20 min" counts down
    /// without waking the app.
    public static func entryDates(from now: Date) -> [Date] {
        let quarter = (now.timeIntervalSince1970 / 900).rounded(.down) * 900
        return [now] + (1...8).map { Date(timeIntervalSince1970: quarter + Double($0) * 900) }
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    /// nil for a missing, unreadable or newer-format file (the widget then shows its placeholder).
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        guard let s = try? d.decode(WidgetSnapshot.self, from: data), s.version <= version else { return nil }
        return s
    }

    public static func fileURL(home: URL) -> URL {
        home.appendingPathComponent(relativeDirectory, isDirectory: true).appendingPathComponent(fileName)
    }
}

/// What "quit" means where (Brian, Oct 13): ⌘Q and closing the window only close the window, and Skyline
/// stays in the menu bar; the dropdown's "Quit Skyline", the app menu's "Quit Skyline Completely", the
/// Dock's Quit and logout/restart really exit.
public enum QuitPolicy {
    public enum Source: Sendable { case commandQ, closeButton, menuBarQuit, quitCompletely, dockOrSystem }
    public enum Action: Equatable, Sendable { case closeWindow, terminate }

    public static func action(for source: Source) -> Action {
        switch source {
        case .commandQ, .closeButton: .closeWindow
        case .menuBarQuit, .quitCompletely, .dockOrSystem: .terminate
        }
    }
}
