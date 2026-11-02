import Foundation
import UniformTypeIdentifiers

enum ContentTypeResolver {
    static func resolve(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Plain text, Markdown and CSV files whose bytes are UTF-8 (all text
    /// Aktar saves from the clipboard is) are sent with that charset, so a
    /// browser doesn't guess another one and garble "ğ" or "é".
    static let charsetTypes: Set<String> = ["text/plain", "text/markdown", "text/csv", "text/x-markdown"]
    /// Bigger text files are sent without a charset rather than read whole.
    static let maxCharsetCheckBytes = 16 * 1024 * 1024

    /// The Content-Type an upload is sent with: `resolve(for:)`, plus
    /// `; charset=utf-8` for a text file that is UTF-8. History keeps the
    /// bare type.
    static func uploadContentType(for url: URL) -> String {
        let type = resolve(for: url)
        guard charsetTypes.contains(type) else { return type }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= maxCharsetCheckBytes,
              let data = try? Data(contentsOf: url),
              String(data: data, encoding: .utf8) != nil else { return type }
        return type + "; charset=utf-8"
    }

    /// Files a browser would run as a page or a script when the link is
    /// opened: HTML (also server-side include and web archive pages), SVG,
    /// XML with its XSLT stylesheets, and JavaScript.
    static let activeExtensions: Set<String> = [
        "html", "htm", "shtml", "xhtml", "xht", "mht", "mhtml", "svg", "svgz", "xml", "xsl", "xslt", "js", "mjs",
    ]
    static let activeContentTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml", "text/xml", "application/xml",
        "text/xsl", "application/xslt+xml", "multipart/related", "application/x-mimearchive",
        "text/javascript", "application/javascript",
    ]

    /// Whether an upload named `names` (the file and its key; any of them
    /// counts) with `contentType` is active content. Those are sent with
    /// `Content-Disposition: attachment`, so opening the link downloads the
    /// file instead of running it on the bucket's domain, while an <img>
    /// of an SVG still shows it.
    static func isActiveContent(names: [String], contentType: String) -> Bool {
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if activeContentTypes.contains(type) { return true }
        return names.contains { activeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// The Content-Disposition to send, or nil for none.
    static func contentDisposition(names: [String], contentType: String) -> String? {
        isActiveContent(names: names, contentType: contentType) ? "attachment" : nil
    }
}
