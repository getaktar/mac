import Foundation
import UniformTypeIdentifiers

enum ContentTypeResolver {
    static func resolve(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Files a browser would run as a page or a script when the link is
    /// opened: HTML, SVG, XML and JavaScript.
    static let activeExtensions: Set<String> = ["html", "htm", "xhtml", "xht", "svg", "svgz", "xml", "js", "mjs"]
    static let activeContentTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml", "text/xml", "application/xml",
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
