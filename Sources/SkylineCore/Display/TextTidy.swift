import Foundation

/// Small text helpers that keep the forecast column from repeating itself or showing fragments
/// (UI/UX #8 and #18).
public enum TextTidy {
    /// Words whose trailing period never ends a sentence.
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "mt", "ft", "vs", "etc", "approx", "e.g", "i.e", "u.s"]
    /// Time abbreviations: end a sentence only when the next word starts with a capital.
    private static let timeAbbreviations: Set<String> = ["a.m", "p.m"]

    /// Splits prose into sentences without breaking on decimals ("0.5 in"), "a.m."/"p.m." mid-sentence,
    /// or common abbreviations. Sentences keep their closing punctuation and are trimmed.
    public static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                let atEnd = i + 1 >= chars.count
                let nextIsSpace = !atEnd && chars[i + 1].isWhitespace
                if atEnd || nextIsSpace {
                    var split = true
                    if c == "." {
                        // The word ending at this period.
                        var j = i - 1
                        while j >= start && !chars[j].isWhitespace { j -= 1 }
                        let word = String(chars[(j + 1)..<i]).lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
                        if abbreviations.contains(word) {
                            split = false
                        } else if timeAbbreviations.contains(word), !atEnd {
                            var k = i + 1
                            while k < chars.count && chars[k].isWhitespace { k += 1 }
                            split = k < chars.count && chars[k].isUppercase
                        }
                    }
                    if split {
                        let s = String(chars[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { out.append(s) }
                        start = i + 1
                    }
                }
            }
            i += 1
        }
        let rest = String(chars[min(start, chars.count)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// The hourly card's one-line summary: the first two whole sentences of the day's forecast text,
    /// else the nowcast. Nothing when it would be a fragment shorter than about 20 characters.
    public static func hourlyHeadline(summary: String?, nowcast: String?) -> String? {
        let candidates: [String?] = [summary, nowcast.map { $0.hasSuffix(".") ? $0 : $0 + "." }]
        for case let text? in candidates {
            let joined = sentences(text).prefix(2).joined(separator: " ")
            if joined.count >= 20 { return joined }
        }
        return nil
    }

    /// The alert banner's second line. NWS headlines usually restate the event, the times and the office
    /// that are already shown ("Coastal Flood Statement issued October 11 at 4:46PM EDT until … by NWS
    /// Upton NY"), so the headline is used only when it doesn't contain the event name; otherwise the first
    /// sentence of the description's first paragraph ("* WHAT...Up to one half foot of inundation…").
    public static func alertSubtitle(event: String, headline: String?, description: String?) -> String? {
        if let headline = headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty,
           headline.range(of: event, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return headline
        }
        guard let description else { return nil }
        let normalized = description.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var first = paragraphs.first else { return nil }
        if first.hasPrefix("*") { first = String(first.dropFirst()).trimmingCharacters(in: .whitespaces) }
        // Drop an all-caps lead-in like "WHAT..." / "IMPACTS...".
        if let dots = first.range(of: "..."),
           first[first.startIndex..<dots.lowerBound].allSatisfy({ $0.isUppercase || $0 == " " }),
           first.distance(from: first.startIndex, to: dots.lowerBound) <= 20 {
            first = String(first[dots.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        first = first.replacingOccurrences(of: "  ", with: " ")
        guard let sentence = sentences(first).first, !sentence.isEmpty else { return nil }
        let capped = sentence.count > 180 ? String(sentence.prefix(177)) + "…" : sentence
        return capped.prefix(1).uppercased() + capped.dropFirst()
    }

    /// True when `phrase` (e.g. the nowcast summary) is already said by `text` (e.g. the briefing),
    /// ignoring case and trailing punctuation.
    public static func isRepeated(_ phrase: String?, in text: String) -> Bool {
        guard let phrase else { return false }
        let p = phrase.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return !p.isEmpty && text.lowercased().contains(p)
    }
}
