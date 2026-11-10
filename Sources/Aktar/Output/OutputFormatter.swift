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
    /// `publicURL` is the upload's own link (public or temporary). With a
    /// `shortURL`, that's what URL, Markdown, HTML and a custom template's
    /// {url} use; a custom template also has {shortUrl} (the short link,
    /// or the long one without it) and {longUrl}.
    ///
    /// `fileURL` is the file's own link when `publicURL` is its share page
    /// (docs/share-pages.md): Markdown and HTML embed images, videos and
    /// audio from it, and a custom template has it as {file}.
    static func format(
        publicURL longURL: URL,
        shortURL: URL? = nil,
        mode: OutputMode,
        filename: String,
        customTemplate: String = "![{filename}]({url})",
        fileURL: URL? = nil
    ) -> String {
        var publicURL = shortURL ?? longURL
        if let fileURL, mode == .markdown || mode == .html, isMedia(filename) {
            publicURL = fileURL
        }
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
            return apply(template: customTemplate, publicURL: publicURL, longURL: longURL, fileURL: fileURL ?? longURL, filename: filename)
        }
    }

    /// A gallery's one link, never embedded: named after its first file
    /// for Markdown (`[a.png +2](url)`) and HTML (`<a href>`), the URL
    /// alone otherwise.
    static func formatGallery(link: URL, title: String, mode: OutputMode) -> String {
        switch mode {
        case .url, .custom: return link.absoluteString
        case .markdown: return "[\(escapedMarkdown(title))](\(link.absoluteString))"
        case .html: return "<a href=\"\(link.absoluteString)\">\(escapedHTML(title))</a>"
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

    /// Images, videos and audio: what Markdown and HTML embed from the
    /// file's own link rather than its page.
    static func isMedia(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
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

    private static func apply(template: String, publicURL: URL, longURL: URL, fileURL: URL, filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return template
            .replacingOccurrences(of: "{url}", with: publicURL.absoluteString)
            .replacingOccurrences(of: "{shortUrl}", with: publicURL.absoluteString)
            .replacingOccurrences(of: "{longUrl}", with: longURL.absoluteString)
            .replacingOccurrences(of: "{file}", with: fileURL.absoluteString)
            .replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{ext}", with: ext)
    }
}
