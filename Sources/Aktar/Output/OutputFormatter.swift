import Foundation
import UniformTypeIdentifiers

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case url, markdown, html, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .url: return "URL"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .custom: return "Custom"
        }
    }
}

enum OutputFormatter {
    static func format(
        publicURL: URL,
        mode: OutputMode,
        filename: String,
        customTemplate: String = "![{filename}]({url})"
    ) -> String {
        switch mode {
        case .url:
            return publicURL.absoluteString
        case .markdown:
            return isImage(filename)
                ? "![](\(publicURL.absoluteString))"
                : "[\(escapedMarkdown(filename))](\(publicURL.absoluteString))"
        case .html:
            return isImage(filename)
                ? "<img src=\"\(publicURL.absoluteString)\" alt=\"\">"
                : "<a href=\"\(publicURL.absoluteString)\">\(escapedHTML(filename))</a>"
        // A custom template is the user's own markup, so nothing in it is
        // escaped: {filename} goes in exactly as it is.
        case .custom:
            return apply(template: customTemplate, publicURL: publicURL, filename: filename)
        }
    }

    /// `text` safe inside an HTML element or a quoted attribute.
    static func escapedHTML(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// `text` as Markdown link text that can't end the link early or start
    /// another one.
    static func escapedMarkdown(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\[]()".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Image files still get embed markup (`![]()`, `<img>`); anything else
    /// gets a plain link, since embedding a PDF or zip as an "image" would
    /// just render as a broken icon wherever it's pasted.
    private static func isImage(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    static func formatBatch(
        entries: [(publicURL: URL, filename: String)],
        mode: OutputMode,
        customTemplate: String = "![{filename}]({url})"
    ) -> String {
        entries
            .map { format(publicURL: $0.publicURL, mode: mode, filename: $0.filename, customTemplate: customTemplate) }
            .joined(separator: "\n")
    }

    private static func apply(template: String, publicURL: URL, filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return template
            .replacingOccurrences(of: "{url}", with: publicURL.absoluteString)
            .replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{ext}", with: ext)
    }
}
