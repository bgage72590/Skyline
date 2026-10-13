import Foundation
import SkylineCore
import WidgetKit

/// Writes the menu-bar city's snapshot for the widget (T22) and asks WidgetKit to reload, only when what
/// the widget shows actually changed (WidgetKit budgets reloads for apps in the background).
@MainActor
final class WidgetPublisher {
    private var lastContent: Data?
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    var fileURL: URL { WidgetSnapshot.fileURL(home: home) }

    func publish(_ report: WeatherReport, name: String, units: DisplayUnits, now: Date = Date()) {
        guard !UserDefaults.standard.bool(forKey: "SkylineSimulateOffline") else { return }
        var snap = WidgetSnapshot(report: report, locationName: name, units: units, now: now)
        // Compare without the write time, so an identical forecast doesn't spend a reload.
        var probe = snap; probe.writtenAt = .distantPast
        let content = try? probe.encoded()
        guard content != lastContent else { return }
        snap.writtenAt = now
        guard let data = try? snap.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastContent = content
            WidgetCenter.shared.reloadTimelines(ofKind: "SkylineWeather")
        } catch {
            NSLog("Skyline: widget snapshot not written: %@", error.localizedDescription)
        }
    }
}
