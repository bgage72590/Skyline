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

    /// True when `candidate` is the same place as `existing`: same id, or the same name+region+country
    /// (case- and accent-insensitive), or within about 1 km (QA #5). Used when adding a search result
    /// so "Boston, MA" from two geocoders doesn't appear twice.
    public static func isDuplicate(_ candidate: WeatherLocation, of existing: WeatherLocation) -> Bool {
        if candidate.id == existing.id { return true }
        // QA L2: a true distance, not grid rounding (28 m across a cell edge was "different", 1.4 km in
        // the same cell "the same").
        if NexradStation.distanceKm(candidate.coordinate, existing.coordinate) < 1 { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let nameOK = candidate.name.compare(existing.name, options: opts) == .orderedSame
        let regionOK = (candidate.region ?? "").compare(existing.region ?? "", options: opts) == .orderedSame
        let countryOK = (candidate.country ?? "").compare(existing.country ?? "", options: opts) == .orderedSame
            || (candidate.countryCode != nil
                && candidate.countryCode?.uppercased() == existing.countryCode?.uppercased())
        return nameOK && regionOK && countryOK && !candidate.name.isEmpty
    }

    public static func existingDuplicate(of candidate: WeatherLocation, in list: [WeatherLocation]) -> WeatherLocation? {
        list.first { isDuplicate(candidate, of: $0) }
    }
}
