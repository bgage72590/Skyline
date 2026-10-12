import Foundation

/// The key messages of the local NWS office's Area Forecast Discussion (T17): what the human forecasters
/// want you to know, extracted from the product text (no AI), plus a link to the full discussion.
public struct ForecasterNotes: Codable, Hashable, Sendable {
    public var office: String
    public var issued: Date
    /// "Key messages" bullets, or the synopsis / first discussion paragraph when an office doesn't write them.
    public var points: [String]
    /// The office's ".WHAT HAS CHANGED..." note, when present.
    public var whatChanged: String?
    /// True when `points` are real key messages (else a synopsis/discussion excerpt).
    public var areKeyMessages: Bool

    /// The full discussion as a readable web page on forecast.weather.gov.
    public var fullTextURL: URL { Self.fullTextURL(office: office) }

    public static func fullTextURL(office: String) -> URL {
        var u = URLComponents(string: "https://forecast.weather.gov/product.php")!
        u.queryItems = [.init(name: "site", value: office), .init(name: "issuedby", value: office),
                        .init(name: "product", value: "AFD"), .init(name: "format", value: "txt")]
        return u.url!
    }
}

public enum AFDParser {
    struct ListRaw: Decodable {
        struct Item: Decodable { var id: String; var issuanceTime: Date }
        var graph: [Item]
        enum CodingKeys: String, CodingKey { case graph = "@graph" }
    }
    struct ProductRaw: Decodable { var issuanceTime: Date; var productText: String }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    /// The newest product id in `/products/types/AFD/locations/{office}`.
    public static func latestID(_ data: Data) throws -> String? {
        try decoder().decode(ListRaw.self, from: data).graph.max { $0.issuanceTime < $1.issuanceTime }?.id
    }

    public static func notes(_ data: Data, office: String) throws -> ForecasterNotes {
        let raw = try decoder().decode(ProductRaw.self, from: data)
        return notes(text: raw.productText, office: office, issued: raw.issuanceTime)
    }

    public static func notes(text: String, office: String, issued: Date) -> ForecasterNotes {
        let sections = Self.sections(text)
        func section(_ prefix: String) -> String? {
            sections.first { $0.title.hasPrefix(prefix) }?.body
        }
        var points: [String] = []
        var keyMessages = false
        if let km = section("KEY MESSAGES") {
            points = bullets(km)
            keyMessages = !points.isEmpty
        }
        if points.isEmpty, let syn = section("SYNOPSIS") ?? section("DISCUSSION") ?? section("SHORT TERM") ?? section("NEAR TERM") {
            points = paragraphs(syn).prefix(1).map { clip($0, 400) }
        }
        let changed = section("WHAT HAS CHANGED").flatMap { paragraphs($0).first }.map { clip($0, 300) }
        return ForecasterNotes(office: office, issued: issued, points: Array(points.prefix(6)), whatChanged: changed,
                               areKeyMessages: keyMessages)
    }

    struct Section { var title: String; var body: String }

    /// Top-level sections: a line starting with "." and a capital letter (".KEY MESSAGES...") opens one;
    /// "&&" or the next header closes it. Sub-headers inside the discussion (".KEY MESSAGE 1...") stay
    /// in the body of their parent only if they don't look like a new top-level section; that's fine
    /// because only KEY MESSAGES / SYNOPSIS / WHAT HAS CHANGED / the first discussion paragraph are used.
    static func sections(_ text: String) -> [Section] {
        var out: [Section] = []
        var title: String?
        var body: [String] = []
        func close() {
            if let title { out.append(Section(title: title, body: body.joined(separator: "\n"))) }
            title = nil; body = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "&&" || line == "$$" { close(); continue }
            if line.hasPrefix("."), line.count > 2, line.dropFirst().first?.isUppercase == true, line.contains("...") {
                let head = line.dropFirst()
                let name = head.components(separatedBy: "...").first ?? String(head)
                // ".KEY MESSAGE 1..." inside DISCUSSION is a sub-header, not a new section.
                if title != nil, name.hasPrefix("KEY MESSAGE ") { body.append(line); continue }
                close()
                title = name.trimmingCharacters(in: .whitespaces)
                let rest = head.components(separatedBy: "...").dropFirst().joined(separator: "...")
                if !rest.trimmingCharacters(in: .whitespaces).isEmpty { body.append(rest) }
                continue
            }
            if title != nil { body.append(line) }
        }
        close()
        return out
    }

    /// "- text" / "* text" / "1) text" / "1. text" items, wrapped lines joined.
    static func bullets(_ body: String) -> [String] {
        var items: [String] = []
        var current: String?
        func flush() { if let c = current?.trimmingCharacters(in: .whitespaces), !c.isEmpty { items.append(tidy(c)) }; current = nil }
        let marker = try! NSRegularExpression(pattern: #"^(?:[-*•]|\d{1,2}[).])\s+"#)
        for line in body.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { flush(); continue }
            let ns = l as NSString
            if let m = marker.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                flush()
                current = ns.substring(from: m.range.length)
            } else if current != nil {
                current! += " " + l
            }
        }
        flush()
        return items
    }

    static func paragraphs(_ body: String) -> [String] {
        body.components(separatedBy: "\n\n")
            .map { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .map { tidy($0) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("issued at") }
    }

    /// Collapses whitespace; an ALL-CAPS paragraph (older offices) becomes sentence case.
    static func tidy(_ s: String) -> String {
        var t = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        let letters = t.filter(\.isLetter)
        if letters.count > 20, letters.allSatisfy({ $0.isUppercase }) {
            t = t.lowercased()
            if let f = t.first { t = f.uppercased() + t.dropFirst() }
        }
        return t
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = s.prefix(n)
        if let dot = cut.lastIndex(of: "."), cut.distance(from: cut.startIndex, to: dot) > n / 2 { return String(cut[...dot]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
