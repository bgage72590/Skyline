import Foundation

/// Return in the city search adds the first result only when those results are for the text in the
/// field now. During the 300 ms debounce they can belong to an older query ("Port" while "Portland"
/// is typed), so then the caller searches again first (QA full-app #1).
public enum SearchSubmit {
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func pick<R>(results: [R], resultsQuery: String, currentText: String) -> R? {
        let current = normalized(currentText)
        guard !current.isEmpty, current.caseInsensitiveCompare(resultsQuery) == .orderedSame else { return nil }
        return results.first
    }

    /// Place search: a 3-letter query is probably an airport code ("SXM", "JFK"), so airports go
    /// first; otherwise the service's order is kept. Stable.
    public static func ranked(_ results: [PlaceSearchResult], query: String) -> [PlaceSearchResult] {
        let q = normalized(query)
        guard q.count == 3, q.allSatisfy({ $0.isLetter && $0.isASCII }) else { return results }
        return results.filter(\.isAirport) + results.filter { !$0.isAirport }
    }

    /// What Return adds: the first ranked result, but never a whole country or territory. Then
    /// nothing is added and the list stays open to choose from.
    public static func pick(results: [PlaceSearchResult], resultsQuery: String, currentText: String) -> PlaceSearchResult? {
        let current = normalized(currentText)
        guard !current.isEmpty, current.caseInsensitiveCompare(resultsQuery) == .orderedSame else { return nil }
        return autoAdd(ranked(results, query: current))
    }

    public static func autoAdd(_ ranked: [PlaceSearchResult]) -> PlaceSearchResult? {
        guard let first = ranked.first, !first.isCountryLevel else { return nil }
        return first
    }
}
