import Foundation

/// Saved-location list rules shared by the sidebar, the menu bar and their tests (T10, T19).
public enum LocationList {
    /// The location the menu bar shows. A city the user pinned in Settings wins while it still exists;
    /// otherwise My Location, else the first saved city. It no longer follows the sidebar selection.
    public static func menuBarLocation(current: WeatherLocation?, saved: [WeatherLocation],
                                       pinnedID: String?) -> WeatherLocation? {
        if let pinnedID {
            if pinnedID == WeatherLocation.currentLocationID, let current { return current }
            if let pinned = saved.first(where: { $0.id == pinnedID }) { return pinned }
        }
        return current ?? saved.first
    }

    /// `Array.move(fromOffsets:toOffset:)` semantics (SwiftUI's `.onMove`), without SwiftUI.
    public static func moving<T>(_ list: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let valid = source.filter { list.indices.contains($0) }
        guard !valid.isEmpty else { return list }
        let moved = valid.map { list[$0] }
        var rest: [T] = []
        var insertAt = 0
        for (i, item) in list.enumerated() where !valid.contains(i) {
            if i < destination { insertAt += 1 }
            rest.append(item)
        }
        rest.insert(contentsOf: moved, at: min(insertAt, rest.count))
        return rest
    }

    /// Puts a removed location back where it was (undo), without duplicating it.
    public static func restoring(_ location: WeatherLocation, at index: Int, into list: [WeatherLocation]) -> [WeatherLocation] {
        guard !list.contains(where: { $0.id == location.id }) else { return list }
        var out = list
        out.insert(location, at: min(max(index, 0), out.count))
        return out
    }
}
