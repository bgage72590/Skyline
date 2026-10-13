import SwiftUI
import WidgetKit
import SkylineCore

/// Reads the app's snapshot. The widget is sandboxed with no network access; its only file access is a
/// read-only exception for the snapshot folder, addressed through the *real* home directory (inside the
/// sandbox `homeDirectoryForCurrentUser` is the container).
enum SnapshotStore {
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: WidgetSnapshot.fileURL(home: realHome)) else { return nil }
        return WidgetSnapshot.decode(data)
    }
}

struct SkylineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SkylineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SkylineEntry { SkylineEntry(date: Date(), snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (SkylineEntry) -> Void) {
        completion(SkylineEntry(date: Date(), snapshot: SnapshotStore.load()))
    }

    /// One entry per quarter hour for 2 h (the rain countdown and the hourly strip move on their own),
    /// then WidgetKit asks again; the app also reloads the widget whenever it writes a new snapshot.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SkylineEntry>) -> Void) {
        let snap = SnapshotStore.load()
        let entries = WidgetSnapshot.entryDates(from: Date()).map { SkylineEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .after(entries.last?.date ?? Date().addingTimeInterval(7200))))
    }
}

struct SkylineWeatherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkylineWeather", provider: SkylineProvider()) { entry in
            SkylineWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetSky(snapshot: entry.snapshot) }
        }
        .configurationDisplayName("Skyline Weather")
        .description("The menu-bar city: now, the next two hours of rain, and the next days.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SkylineWidgets: WidgetBundle {
    var body: some Widget { SkylineWeatherWidget() }
}
