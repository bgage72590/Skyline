import Foundation

/// Adding a city never fails silently (Brian, Oct 17): every state of the sidebar search says what
/// happened — too short, searching, nothing found, failed (with Try Again), or "pick one".
public enum PlaceSearch {
    /// A geocoder that hasn't answered by now is treated as failed (the spinner never spins forever).
    public static let timeout: TimeInterval = 15
    /// An empty answer is trusted this long, not the 30 days a real result is cached for.
    public static let emptyResultTTL: TimeInterval = 10 * 60

    public struct TimedOut: Error, Equatable, Sendable {}

    /// "Portland, OR" → ("Portland", "OR"). Open-Meteo's geocoder matches names only, so a "City,
    /// Region" query used to come back empty; the part after the comma ranks the results instead.
    public static func parse(_ query: String) -> (name: String, qualifier: String?) {
        let q = SearchSubmit.normalized(query)
        guard let comma = q.firstIndex(of: ",") else { return (q, nil) }
        let name = SearchSubmit.normalized(String(q[..<comma]))
        let rest = SearchSubmit.normalized(String(q[q.index(after: comma)...]))
        guard !name.isEmpty else { return (rest, nil) }
        return (name, rest.isEmpty ? nil : rest)
    }

    /// Results matching the qualifier (state or province, its US abbreviation, country, or country
    /// code) first; the rest keep their order. With no match at all, the order is unchanged.
    public static func ranked(_ results: [PlaceSearchResult], qualifier: String?) -> [PlaceSearchResult] {
        guard let qualifier, !qualifier.isEmpty else { return results }
        let parts = qualifier.split(separator: ",").map { SearchSubmit.normalized(String($0)) }.filter { !$0.isEmpty }
        func matches(_ r: PlaceSearchResult) -> Bool {
            parts.allSatisfy { part in
                let p = part.lowercased()
                let admin = r.admin1?.lowercased()
                return admin == p || admin == usStates[p.uppercased()]?.lowercased()
                    || r.country?.lowercased() == p || r.countryCode?.lowercased() == p
                    || (p == "usa" || p == "us") && r.countryCode == "US"
                    || (p == "uk") && r.countryCode == "GB"
            }
        }
        return results.filter(matches) + results.filter { !matches($0) }
    }

    /// What the sidebar shows above (or instead of) the results.
    public struct Status: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case hint, searching, noResults, failed, chooseOne }
        public var kind: Kind
        public var message: String
        public var detail: String?
        /// Show "Try Again".
        public var canRetry: Bool
    }

    /// - Parameters:
    ///   - resultsQuery: the query the shown results (possibly none) answered.
    ///   - nothingAdded: Return was pressed and found only places it can't add on its own (a country).
    public static func status(text: String, isSearching: Bool, resultCount: Int, resultsQuery: String?,
                              error: String?, nothingAdded: Bool = false) -> Status? {
        let q = SearchSubmit.normalized(text)
        if q.isEmpty { return nil }
        if q.count < 2 {
            return Status(kind: .hint, message: "Type at least 2 letters to search.", detail: nil, canRetry: false)
        }
        if let error, !isSearching {
            return Status(kind: .failed, message: error,
                          detail: "Your saved cities are unchanged. Check your connection, then try again.", canRetry: true)
        }
        let answered = resultsQuery.map { $0.caseInsensitiveCompare(q) == .orderedSame } ?? false
        if resultCount == 0 {
            if isSearching || !answered {
                return Status(kind: .searching, message: "Searching for “\(q)”…", detail: nil, canRetry: false)
            }
            let tip = parse(q).qualifier != nil
                ? "Try just the city name, like “\(parse(q).name)”."
                : "Check the spelling, or try a nearby town or an airport code."
            return Status(kind: .noResults, message: "No places found for “\(q)”.", detail: tip, canRetry: false)
        }
        if nothingAdded && answered {
            return Status(kind: .chooseOne, message: "Choose a place from the list to add it.", detail: nil, canRetry: false)
        }
        return nil
    }

    /// The failure line. Search has no automatic retry, so a back-off says "try again" rather than
    /// promising a retry time.
    public static func errorMessage(_ error: Error) -> String {
        switch error {
        case is TimedOut: return "Couldn’t search: the place search didn’t answer."
        case HTTPError.throttled, HTTPError.backingOff: return "Couldn’t search: the place search is busy. Try again in a minute."
        default: return "Couldn’t search. " + UserFacingError.message(error)
        }
    }

    /// Runs `operation`, throwing `TimedOut` after `seconds`.
    public static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }

    static let usStates: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming", "PR": "Puerto Rico",
    ]
}
