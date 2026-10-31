import Foundation

/// Counts writes a close/reopen would make. The window transition is not one of them.
public final class CountingDocumentWriter: @unchecked Sendable {
    public private(set) var locationWrites = 0
    public private(set) var settingsWrites = 0
    public private(set) var syncWrites = 0

    public init() {}

    public func writeLocations(_ locations: [WeatherLocation]) {
        locationWrites += 1
        _ = locations
    }

    public func writeSettings(_ settings: [String: String]) {
        settingsWrites += 1
        _ = settings
    }

    public func writeSync(_ data: Data) {
        syncWrites += 1
        _ = data
    }
}

/// Closing and reopening the main window does not persist cities, units, or sync.json.
/// A document whose cities and settings are unchanged is left byte-for-byte as it was.
public enum WindowReopenPersistence {
    public static func closeAndReopen(locations: [WeatherLocation], settings: [String: String], syncBytes: Data,
                                      writer: CountingDocumentWriter, now: Date = Date())
    -> (locations: [WeatherLocation], settings: [String: String], syncBytes: Data) {
        guard case .document(let previous) = SyncDocument.read(syncBytes) else {
            return (locations, settings, syncBytes)
        }
        let noted = SyncDocument.noting(locations: locations, settings: settings, previous: previous, now: now)
        guard !noted.sameContent(as: previous) else {
            return (locations, settings, syncBytes)
        }
        writer.writeLocations(locations)
        writer.writeSettings(settings)
        let bytes = (try? noted.encoded()) ?? syncBytes
        writer.writeSync(bytes)
        return (noted.locations, noted.settings, bytes)
    }
}
