import Foundation

/// A share page (docs/share-pages.md): docs/share-page/template.html, filled
/// in with the head tags and the page data. A port of `buildPage` and
/// `headFor` in docs/share-page/reference.mjs; the Windows and mobile apps
/// fill the same template the same way.
struct SharePage: Equatable {
    enum Kind: String {
        case file, gallery, text, encrypted, request
    }

    struct File: Equatable {
        var name: String
        /// What the browser loads: the public URL, or a presigned GET.
        var url: String
        var size: Int64
        /// The Content-Type the file was uploaded with, without parameters.
        var type: String
        /// The bucket thumbnail's URL, when there is one.
        var thumb: String?
        /// For og:image only (see `SharePages.ogImage`); not in the data.
        var ogImage: String?
    }

    struct Encrypted: Equatable {
        var url: String
        var size: Int64
        var password: Bool
    }

    struct Request: Equatable {
        struct Slot: Equatable {
            /// Presigned PUTs for the file and its metadata.
            var file: String
            var meta: String
        }

        var title: String
        var note: String
        var maxBytes: Int64
        var conditional: Bool
        var slots: [Slot]
    }

    var kind: Kind
    var lang: String
    var created: Date
    var expires: Date?
    var files: [File]?
    var text: String?
    var syntax: String?
    var encrypted: Encrypted?
    var request: Request?
    /// Nil leaves it out of the data, which shows the "Shared with Aktar"
    /// footer; v1 never sets it.
    var brand: Bool?

    init(kind: Kind, lang: String, created: Date, expires: Date? = nil, files: [File]? = nil, text: String? = nil,
         syntax: String? = nil, encrypted: Encrypted? = nil, request: Request? = nil, brand: Bool? = nil) {
        self.kind = kind
        self.lang = lang
        self.created = created
        self.expires = expires
        self.files = files
        self.text = text
        self.syntax = syntax
        self.encrypted = encrypted
        self.request = request
        self.brand = brand
    }
}

enum SharePages {
    /// Sent with every page: it's rewritten on Replace File.
    static let cacheControl = "public, max-age=60"
    static let contentType = "text/html; charset=utf-8"
    /// The bundled copy of docs/share-page/template.html, byte for byte.
    static let templateResource = "template"

    private final class BundleToken {}

    /// The template as shipped in the app (or the test bundle).
    static func bundledTemplate() -> String? {
        guard let url = Bundle(for: BundleToken.self).url(forResource: templateResource, withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Filling the template

    /// The page: `{{LANG}}`, `{{TITLE}}`, `{{META}}` and `{{DATA}}` replaced
    /// once each, in that order. What goes in can't contain a placeholder
    /// (braces are escaped in the first three, and the data comes last).
    static func build(_ page: SharePage, template: String) -> String {
        let head = head(for: page)
        var html = template
        replaceFirst("{{LANG}}", with: escapeHTML(page.lang.isEmpty ? "en" : page.lang), in: &html)
        replaceFirst("{{TITLE}}", with: escapeHTML(head.title), in: &html)
        replaceFirst("{{META}}", with: head.meta, in: &html)
        replaceFirst("{{DATA}}", with: escapeJSON(dataJSON(page)), in: &html)
        return html
    }

    private static func replaceFirst(_ placeholder: String, with value: String, in html: inout String) {
        guard let range = html.range(of: placeholder) else { return }
        html.replaceSubrange(range, with: value)
    }

    /// `& < > " ' { }` as entities.
    static func escapeHTML(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            case "{": escaped += "&#123;"
            case "}": escaped += "&#125;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// JSON for inside `<script type="application/json">`: nothing in it can
    /// end the script element or start a comment.
    static func escapeJSON(_ json: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(json.utf8.count)
        for scalar in json.unicodeScalars {
            switch scalar {
            case "<": escaped += "\\u003c"
            case ">": escaped += "\\u003e"
            case "&": escaped += "\\u0026"
            case "\u{2028}": escaped += "\\u2028"
            case "\u{2029}": escaped += "\\u2029"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// The page data (version 1), keys in the reference's order.
    static func dataJSON(_ page: SharePage) -> String {
        var fields: [(String, JSJSON)] = [
            ("v", .int(1)),
            ("kind", .string(page.kind.rawValue)),
            ("lang", .string(page.lang.isEmpty ? "en" : page.lang)),
            ("created", .string(isoDate(page.created))),
            ("expires", page.expires.map { .string(isoDate($0)) } ?? .null),
        ]
        if let files = page.files {
            fields.append(("files", .array(files.map { file in
                .object([
                    ("name", .string(file.name)),
                    ("url", .string(file.url)),
                    ("size", .int(file.size)),
                    ("type", .string(file.type)),
                    ("thumb", file.thumb.map(JSJSON.string) ?? .null),
                ])
            })))
        }
        if page.kind == .text {
            fields.append(("text", .string(page.text ?? "")))
            fields.append(("syntax", page.syntax.map(JSJSON.string) ?? .null))
        }
        if page.kind == .encrypted, let encrypted = page.encrypted {
            fields.append(("encrypted", .object([
                ("url", .string(encrypted.url)),
                ("size", .int(encrypted.size)),
                ("password", .bool(encrypted.password)),
            ])))
        }
        if page.kind == .request, let request = page.request {
            fields.append(("request", .object([
                ("title", .string(request.title)),
                ("note", .string(request.note)),
                ("maxBytes", .int(request.maxBytes)),
                ("conditional", .bool(request.conditional)),
                ("slots", .array(request.slots.map { .object([("file", .string($0.file)), ("meta", .string($0.meta))]) })),
            ])))
        }
        if page.brand == false { fields.append(("brand", .bool(false))) }
        return JSJSON.object(fields).serialized
    }

    /// "2026-11-09T12:00:00Z".
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - Head

    /// The `<title>` and the tags in place of `{{META}}`, as `headFor` in
    /// reference.mjs. English on purpose: crawlers have no language.
    static func head(for page: SharePage) -> (title: String, meta: String) {
        var title: String
        var description: String
        var image: String?
        var video: SharePage.File?
        let files = page.files ?? []
        switch page.kind {
        case .encrypted:
            title = "Encrypted file"
            description = "Open the link to decrypt it in the browser."
        case .request:
            let request = page.request
            title = request?.title.isEmpty == false ? request!.title : "Send files"
            description = request?.note.isEmpty == false ? excerpt(request!.note) : "Upload files straight to the requester\u{2019}s storage."
        case .gallery:
            title = "\(files.first?.name ?? "") +\(max(0, files.count - 1))"
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            description = "\(files.count) files \u{00B7} \(formatSize(total))"
            image = files.first { $0.ogImage != nil }?.ogImage
        case .file, .text:
            let file = files.first
            title = file?.name ?? ""
            if page.kind == .text, let text = page.text, !text.isEmpty {
                description = excerpt(text)
            } else {
                description = [formatSize(file?.size ?? 0), extensionLabel(file?.name ?? "")]
                    .filter { !$0.isEmpty }
                    .joined(separator: " \u{00B7} ")
            }
            image = file?.ogImage
            if let file, file.type == "video/mp4" || file.type == "video/webm" { video = file }
        }
        var tags: [(String, String, String)] = []
        tags.append(("name", "description", description))
        tags.append(("property", "og:title", title))
        tags.append(("property", "og:description", description))
        tags.append(("property", "og:type", video != nil ? "video.other" : "website"))
        if let image {
            tags.append(("property", "og:image", image))
            tags.append(("property", "og:image:alt", title))
        }
        if let video {
            tags.append(("property", "og:video", video.url))
            tags.append(("property", "og:video:secure_url", video.url))
            tags.append(("property", "og:video:type", video.type))
        }
        tags.append(("name", "twitter:card", image != nil ? "summary_large_image" : "summary"))
        tags.append(("name", "twitter:title", title))
        let meta = tags.map { "<meta \($0.0)=\"\($0.1)\" content=\"\(escapeHTML($0.2))\">" }.joined(separator: "\n")
        return (title, meta)
    }

    /// "2.4 MB": decimal units, one decimal below 100, none for bytes. Halves
    /// round up, as JavaScript's `toFixed` does.
    static func formatSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var index = 0
        var divisor: Int64 = 1
        while index < units.count - 1, bytes / divisor >= 1000 {
            divisor *= 1000
            index += 1
        }
        let bytes = max(0, bytes)
        let wholePart = bytes / divisor
        if index == 0 || wholePart >= 100 {
            // Rounded half up to a whole number.
            let rounded = (bytes * 2 + divisor) / (divisor * 2)
            return "\(rounded) \(units[index])"
        }
        let tenths = (bytes * 20 + divisor) / (divisor * 2)
        return "\(tenths / 10).\(tenths % 10) \(units[index])"
    }

    private static func extensionLabel(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex, name.index(after: dot) < name.endIndex else { return "" }
        return String(name[name.index(after: dot)...]).uppercased()
    }

    /// JavaScript's `\s`.
    private static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// The text for og:description: whitespace collapsed, 200 code points
    /// at most, with an ellipsis when cut.
    static func excerpt(_ text: String) -> String {
        var flat: [Unicode.Scalar] = []
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if isJSWhitespace(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace, !flat.isEmpty { flat.append(" ") }
            pendingSpace = false
            flat.append(scalar)
        }
        var result = String.UnicodeScalarView()
        if flat.count > 200 {
            result.append(contentsOf: flat.prefix(199))
            result.append("\u{2026}")
        } else {
            result.append(contentsOf: flat)
        }
        return String(result)
    }

    // MARK: - What a page shows

    /// og:image for a file: the file itself for an image up to 8 MB that
    /// crawlers render (not SVG or HEIC), otherwise its bucket thumbnail.
    static func ogImage(type: String, size: Int64, url: String, thumb: String?) -> String? {
        let type = bareType(type)
        if type.hasPrefix("image/"), size <= 8_000_000,
           !["image/svg+xml", "image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence"].contains(type) {
            return url
        }
        return thumb
    }

    /// "text/plain; charset=utf-8" as "text/plain".
    static func bareType(_ contentType: String) -> String {
        (contentType.split(separator: ";").first.map(String.init) ?? contentType)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Text pages: at most this big.
    static let maxTextBytes = 256 * 1024

    static let textTypes: Set<String> = [
        "application/json", "application/xml", "application/javascript", "application/x-sh",
        "application/x-yaml", "application/toml",
    ]

    /// Whether a file of `contentType` is text for a text page (before the
    /// size and UTF-8 checks).
    static func isTextType(_ contentType: String) -> Bool {
        let type = bareType(contentType)
        return type.hasPrefix("text/") || textTypes.contains(type)
    }

    /// The text of a file for a text page: a text type, at most 256 KB, and
    /// valid UTF-8. Nil for anything else (a `file` page).
    static func pageText(of url: URL, contentType: String) -> String? {
        guard isTextType(contentType),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size <= maxTextBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(validatingUTF8Data: data)
    }

    static let syntaxNames: Set<String> = [
        "swift", "kotlin", "java", "js", "ts", "jsx", "tsx", "json", "python", "ruby", "go", "rust", "c", "cpp",
        "csharp", "php", "shell", "bash", "zsh", "powershell", "sql", "html", "css", "scss", "xml", "yaml", "toml",
        "ini", "markdown", "dockerfile", "makefile", "r", "perl", "lua", "dart", "scala", "elixir", "text",
    ]

    private static let syntaxByExtension: [String: String] = [
        "swift": "swift", "kt": "kotlin", "kts": "kotlin", "java": "java",
        "js": "js", "mjs": "js", "cjs": "js", "ts": "ts", "mts": "ts", "cts": "ts", "jsx": "jsx", "tsx": "tsx",
        "json": "json", "py": "python", "pyw": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "cs": "csharp", "php": "php", "sh": "shell", "bash": "bash", "zsh": "zsh", "ps1": "powershell", "psm1": "powershell",
        "sql": "sql", "html": "html", "htm": "html", "css": "css", "scss": "scss", "xml": "xml", "plist": "xml",
        "svg": "xml", "yaml": "yaml", "yml": "yaml", "toml": "toml", "ini": "ini", "cfg": "ini", "conf": "ini",
        "md": "markdown", "markdown": "markdown", "r": "r", "pl": "perl", "pm": "perl", "lua": "lua",
        "dart": "dart", "scala": "scala", "sc": "scala", "ex": "elixir", "exs": "elixir",
    ]

    /// The highlighter's language for a file name, lowercase; `text` for
    /// .txt, .log, .csv and anything unknown.
    static func syntax(forFilename filename: String) -> String {
        let name = (filename as NSString).lastPathComponent
        switch name.lowercased() {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        default: break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "dockerfile" { return "dockerfile" }
        return syntaxByExtension[ext] ?? "text"
    }

    // MARK: - Keys

    /// A share page next to its file: `2026/11/x7Kp2.png.html`. Under the
    /// same `tmp/{N}d/` prefix as the file, so Delete after removes both.
    static func pageKey(forFileKey key: String) -> String { key + ".html" }

    /// A gallery, at the first successful file's key.
    static func galleryKey(forFirstFileKey key: String) -> String { key + ".gallery.html" }

    /// An encrypted file: the path template is ignored (names and
    /// extensions would leak), only the expiry prefix stays.
    static func encryptedKey(expiryDays: Int?, code: String = ShortCode.make(length: 22)) -> String {
        UploadExpiry.key("e/" + code, days: expiryDays)
    }

    /// Whether `key` is one Aktar writes for pages, which the bucket view
    /// and duplicate checks can tell apart from uploads.
    static func isPageKey(_ key: String) -> Bool { key.hasSuffix(".html") }

    /// The page's link when only the file's link and both keys are known:
    /// the file's URL with its key swapped for the page's. Nil when the URL
    /// doesn't end in the key.
    static func pageURL(fileURL: String, fileKey: String, pageKey: String) -> URL? {
        let encodedFile = encodePath(fileKey)
        guard fileURL.hasSuffix(encodedFile) else { return nil }
        return URL(string: String(fileURL.dropLast(encodedFile.count)) + encodePath(pageKey))
    }

    /// As `PublicURLResolver` encodes a key.
    static func encodePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    // MARK: - Warnings

    /// The public base URL is on `*.r2.dev`.
    static func isR2Dev(publicBaseURL: String) -> Bool {
        guard let host = host(publicBaseURL) else { return false }
        return host == "r2.dev" || host.hasSuffix(".r2.dev")
    }

    /// The bucket is reached path-style: the public base URL's path starts
    /// with `/<bucket>` (MinIO, B2's friendly URLs), so pages share one web
    /// origin with everything else on that server.
    static func isPathStyle(publicBaseURL: String, bucket: String) -> Bool {
        let bucket = bucket.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty, let components = components(publicBaseURL) else { return false }
        let segments = components.percentEncodedPath.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        // B2's friendly URLs are /file/<bucket>.
        return segments.first == bucket || (segments.count > 1 && segments[0] == "file" && segments[1] == bucket)
    }

    /// The origin (`https://cdn.example.com`) of an address, for CORS.
    static func origin(of address: String) -> String? {
        guard let components = components(address), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = components.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
            origin += ":\(port)"
        }
        return origin
    }

    private static func components(_ address: String) -> URLComponents? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    private static func host(_ address: String) -> String? {
        components(address)?.host?.lowercased()
    }
}

/// Writing pages to a bucket; kept apart from the upload manager so the
/// integration tests can use it.
enum SharePagePublisher {
    /// A plain PUT (the file's key was free, so this one is too), served
    /// inline as HTML with a short cache time.
    static func write(_ page: SharePage, key: String, provider: any StorageBackend, template: String) async throws {
        let html = SharePages.build(page, template: template)
        try await provider.putObject(data: Data(html.utf8), objectKey: key, contentType: SharePages.contentType, cacheControl: SharePages.cacheControl)
    }

    /// After a file is deleted: its page, unless another upload still
    /// points at it. One that's gone already is fine.
    static func delete(pageKey: String, stillUsed: Bool, provider: any StorageBackend) async {
        guard !stillUsed else { return }
        try? await provider.delete(objectKey: pageKey)
    }
}

private extension String {
    /// Nil unless `data` is valid UTF-8 (Foundation's decoder would replace
    /// invalid bytes).
    init?(validatingUTF8Data data: Data) {
        var iterator = data.makeIterator()
        var decoder = UTF8()
        var scalars = String.UnicodeScalarView()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}

/// JSON written the way JavaScript's `JSON.stringify` writes it (keys in
/// the given order, `/` and non-ASCII as they are), so pages and the
/// encrypted files' metadata come out byte for byte as in reference.mjs.
indirect enum JSJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSJSON])
    case object([(String, JSJSON)])

    static func == (lhs: JSJSON, rhs: JSJSON) -> Bool { lhs.serialized == rhs.serialized }

    var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .string(let value): Self.writeString(value, to: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, field) in fields.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(field.0, to: &out)
                out += ":"
                field.1.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
