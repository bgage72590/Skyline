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
}
