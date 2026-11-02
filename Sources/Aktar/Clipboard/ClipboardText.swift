import Foundation

/// Copied text, as an upload: a link to download, or text saved as a file
/// (docs/capture-and-instant-links.md, "Clipboard text and links"). Apart
/// from AppKit so it can be tested.
enum ClipboardText {
    /// Longer text isn't taken for a link.
    static let maxLinkLength = 8 * 1024
    /// Bigger text isn't parsed to tell whether it's JSON.
    static let maxJSONCheckBytes = 8 * 1024 * 1024

    /// The http(s) link `text` is, when all of it (trimmed) is one link:
    /// one word with a host, nothing else around it.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLinkLength,
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    enum Kind: Equatable {
        case plain
        case markdown
        case json

        var fileExtension: String {
            switch self {
            case .plain: return "txt"
            case .markdown: return "md"
            case .json: return "json"
            }
        }
    }

    /// JSON when the whole text is an object or an array, Markdown when it
    /// has enough of its marks (a heading, a code block, a link, a table, a
    /// list...), plain text otherwise.
    static func kind(of text: String) -> Kind {
        if isJSON(text) { return .json }
        if looksLikeMarkdown(text) { return .markdown }
        return .plain
    }

    static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              trimmed.utf8.count <= maxJSONCheckBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return false }
        return object is [Any] || object is [String: Any]
    }

    /// A fenced code block alone is enough; otherwise marks add up, and
    /// it takes two (a heading, a link, a table, or two list items).
    static func looksLikeMarkdown(_ text: String) -> Bool {
        var score = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(5_000) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.dropFirst(hashes).first == " " { score += 2 }
            }
            if trimmed.hasPrefix("- [ ] ") || trimmed.lowercased().hasPrefix("- [x] ") {
                score += 2
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || isOrderedListItem(trimmed) {
                score += 1
            }
            if trimmed.hasPrefix("> ") { score += 1 }
            if trimmed.hasPrefix("|"), trimmed.contains("---") { score += 2 }
            if score >= 2 { return true }
        }
        if text.range(of: #"\[[^\]\n]+\]\((https?://|/|#|\./)[^)\s]*\)"#, options: .regularExpression) != nil { score += 2 }
        if text.range(of: #"\*\*[^*\n]+\*\*"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil { score += 1 }
        return score >= 2
    }

    /// "1. " to "999. " (or "1) ").
    private static func isOrderedListItem(_ line: String) -> Bool {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// Whether `text` is worth uploading: not empty or only spaces.
    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
