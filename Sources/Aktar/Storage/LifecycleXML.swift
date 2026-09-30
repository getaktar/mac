import Foundation

/// Bucket lifecycle configuration handled as XML text rather than decoded
/// into typed rules. Providers don't all write rules the way the AWS model
/// expects (R2's default multipart-abort rule has no `Filter`, which a typed
/// decoder rejects), and a PUT replaces the whole configuration, so every
/// rule that isn't Aktar's is sent back exactly as the bucket returned it.
enum LifecycleXML {
    struct Rule: Equatable {
        let id: String?
        /// `Filter/Prefix`, or the legacy top-level `Prefix`.
        let prefix: String?
        let status: String?
        let expirationDays: Int?
        /// The rule's inner XML, as returned.
        let raw: String
    }

    static func rules(in xml: String) -> [Rule] {
        blocks("Rule", in: xml).map { raw in
            let filter = blocks("Filter", in: raw).first
            let expiration = blocks("Expiration", in: raw).first
            return Rule(
                id: value("ID", in: raw),
                prefix: filter.map { value("Prefix", in: $0) } ?? value("Prefix", in: raw),
                status: value("Status", in: raw),
                expirationDays: expiration.flatMap { value("Days", in: $0) }.flatMap(Int.init),
                raw: raw
            )
        }
    }

    /// The rules of a GET ?lifecycle response, or nil when it doesn't read
    /// as a lifecycle configuration whose every rule could be parsed: a
    /// proxy's HTML page, a provider answering with something else, or
    /// elements this parser doesn't follow (namespace prefixes). Writing
    /// Aktar's rules on top of a misread configuration would replace the
    /// bucket's own rules, so nothing is written then.
    static func configurationRules(in xml: String) -> [Rule]? {
        guard blocks("LifecycleConfiguration", in: xml).count == 1 else { return nil }
        let parsed = rules(in: xml)
        var opened = 0
        var rest = xml[...]
        while let open = rest.range(of: "<Rule", options: .literal) {
            rest = rest[open.upperBound...]
            if isTagEnd(rest) { opened += 1 }
        }
        return parsed.count == opened ? parsed : nil
    }

    /// Whether all of Aktar's rules are in `rules`, exactly as installed.
    static func isInPlace(_ rules: [Rule]) -> Bool {
        missingDurations(rules).isEmpty
    }

    /// The durations whose rule isn't in place yet.
    static func missingDurations(_ rules: [Rule]) -> [Int] {
        UploadExpiry.options.filter { days in
            !rules.contains {
                $0.id == UploadExpiry.ruleID(days: days) && $0.prefix == UploadExpiry.prefix(days: days)
                    && $0.expirationDays == days && $0.status == "Enabled"
            }
        }
    }

    /// The configuration to PUT: the bucket's other rules untouched, then
    /// Aktar's expiry rules (replacing older versions of them). Nil when all
    /// of Aktar's rules are already in place, so nothing needs writing.
    static func merged(_ existing: [Rule]) -> String? {
        if isInPlace(existing) { return nil }

        let aktarIDs = Set(UploadExpiry.options.map(UploadExpiry.ruleID(days:)))
        let kept = existing.filter { !aktarIDs.contains($0.id ?? "") }.map(\.raw)
        let ours = UploadExpiry.options.map { days in
            "<ID>\(UploadExpiry.ruleID(days: days))</ID>"
                + "<Filter><Prefix>\(UploadExpiry.prefix(days: days))</Prefix></Filter>"
                + "<Status>Enabled</Status>"
                + "<Expiration><Days>\(days)</Days></Expiration>"
        }
        return document(kept + ours)
    }

    /// Aktar's rules taken out: nil when there are none to remove, an empty
    /// string when no rules would be left (the configuration is deleted
    /// then, since S3 doesn't accept an empty one), otherwise the XML to PUT.
    static func removingAktarRules(_ existing: [Rule]) -> String? {
        let aktarIDs = Set(UploadExpiry.options.map(UploadExpiry.ruleID(days:)))
        let kept = existing.filter { !aktarIDs.contains($0.id ?? "") }
        guard kept.count < existing.count else { return nil }
        guard !kept.isEmpty else { return "" }
        return document(kept.map(\.raw))
    }

    private static func document(_ rules: [String]) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?>"#
            + #"<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
            + rules.map { "<Rule>\($0)</Rule>" }.joined()
            + "</LifecycleConfiguration>"
    }

    /// The `Code` and `Message` of an S3 error response.
    static func error(in xml: String) -> (code: String?, message: String?) {
        (value("Code", in: xml), value("Message", in: xml))
    }

    /// The inner XML of each `<tag>…</tag>` (or `<tag attr="…">…</tag>`)
    /// directly or indirectly inside `xml`. Lifecycle elements don't nest
    /// within themselves, so the first closing tag always ends the block.
    private static func blocks(_ tag: String, in xml: String) -> [String] {
        var result: [String] = []
        var rest = xml[...]
        while let open = rest.range(of: "<\(tag)", options: .literal) {
            let afterName = rest[open.upperBound...]
            // `<Rules>` isn't a `<Rule>`.
            guard isTagEnd(afterName) else {
                rest = afterName
                continue
            }
            guard let tagEnd = afterName.firstIndex(of: ">") else { break }
            if tagEnd > afterName.startIndex, afterName[afterName.index(before: tagEnd)] == "/" {
                // `<Filter/>`: empty.
                result.append("")
                rest = afterName[afterName.index(after: tagEnd)...]
                continue
            }
            let content = afterName[afterName.index(after: tagEnd)...]
            guard let close = content.range(of: "</\(tag)>", options: .literal) else { break }
            result.append(String(content[..<close.lowerBound]))
            rest = content[close.upperBound...]
        }
        return result
    }

    private static func isTagEnd(_ rest: Substring) -> Bool {
        guard let next = rest.first else { return false }
        return next == ">" || next == "/" || next.isWhitespace
    }

    private static func value(_ tag: String, in xml: String) -> String? {
        blocks(tag, in: xml).first.map(unescape)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
