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

    /// Type-to-jump in the sidebar (L17): the first name, in list order, starting with what was typed
    /// (case- and accent-insensitive), else the first containing it at a word start. Nil when nothing matches.
    public static func typeSelect(_ typed: String, in names: [String]) -> Int? {
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let i = names.firstIndex(where: { $0.range(of: q, options: opts.union(.anchored)) != nil }) { return i }
        return names.firstIndex { name in
            name.split(whereSeparator: { $0 == " " || $0 == "-" })
                .contains { $0.range(of: q, options: opts.union(.anchored)) != nil }
        }
    }
}
