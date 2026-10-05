import Foundation

/// "Use for" on a destination: the kinds of files and the extensions that
/// go there when an upload doesn't name a destination. The Windows and
/// mobile apps use the same kinds, lists and order; see
/// docs/destination-automation.md.
struct FileRouting: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case image
        case video
        case audio
        case document
        case archive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .image: return String(localized: "Images")
            case .video: return String(localized: "Videos")
            case .audio: return String(localized: "Audio")
            case .document: return String(localized: "Documents")
            case .archive: return String(localized: "Archives")
            }
        }
    }

    var kinds: [Kind] = []
    /// Lowercase, without the dot.
    var extensions: [String] = []

    var isEmpty: Bool { kinds.isEmpty && extensions.isEmpty }

    init(kinds: [Kind] = [], extensions: [String] = []) {
        self.kinds = kinds
        self.extensions = extensions
    }

    /// Lenient, like the rest of a destination: an unknown kind or an
    /// invalid extension is dropped rather than failing the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kinds = (try? container.decode([String].self, forKey: .kinds)) ?? []
        let extensions = (try? container.decode([String].self, forKey: .extensions)) ?? []
        self.init(
            kinds: FileRouting.orderedKinds(kinds.compactMap(Kind.init(rawValue:))),
            extensions: FileRouting.normalizedExtensions(extensions)
        )
    }

    static let extensionsByKind: [Kind: Set<String>] = [
        .image: ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico",
                 "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp", "mpg", "mpeg"],
        .audio: ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aif", "aiff", "wma"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "odt", "ods", "odp",
                    "rtf", "txt", "md", "csv", "json", "epub"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg"],
    ]

    static func kind(forExtension ext: String) -> Kind? {
        let ext = ext.lowercased()
        return Kind.allCases.first { extensionsByKind[$0]?.contains(ext) == true }
    }

    /// `raw` as a stored extension: trimmed, without leading dots,
    /// lowercase, 1 to 16 letters and digits. Nil when it isn't one.
    static func normalizedExtension(_ raw: String) -> String? {
        var ext = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard (1...16).contains(ext.count),
              ext.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return ext
    }

    /// Valid extensions, without duplicates, in the order given.
    static func normalizedExtensions(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap(normalizedExtension).filter { seen.insert($0).inserted }
    }

    /// The extensions typed in the form ("dmg, .zip pkg"), and the parts
    /// that aren't extensions, so the form can say which.
    static func parseExtensions(_ text: String) -> (extensions: [String], invalid: [String]) {
        let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let invalid = parts.filter { normalizedExtension($0) == nil }
        return (normalizedExtensions(parts), invalid)
    }

    /// Kinds in their fixed order, without duplicates.
    static func orderedKinds(_ kinds: [Kind]) -> [Kind] {
        Kind.allCases.filter(kinds.contains)
    }
}

/// Picks the destination for an upload that doesn't name one.
enum DestinationRouting {
    /// For a file named `filename`: a destination listing its extension,
    /// otherwise one listing its kind, otherwise the default. Among several
    /// at the same step, the default wins if it's one of them, otherwise
    /// the first in the list. Nil only when there are no destinations.
    static func destination(forFilename filename: String, destinations: [DestinationConfig], defaultID: UUID?) -> DestinationConfig? {
        let fallback = destinations.first { $0.id == defaultID } ?? destinations.first
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return fallback }
        let byExtension = destinations.filter { $0.useFor?.extensions.contains(ext) == true }
        if let match = pick(byExtension, defaultID: defaultID) { return match }
        if let kind = FileRouting.kind(forExtension: ext) {
            let byKind = destinations.filter { $0.useFor?.kinds.contains(kind) == true }
            if let match = pick(byKind, defaultID: defaultID) { return match }
        }
        return fallback
    }

    private static func pick(_ matches: [DestinationConfig], defaultID: UUID?) -> DestinationConfig? {
        matches.first { $0.id == defaultID } ?? matches.first
    }

    /// The panel's hint, such as "Images and videos go to Screenshots."
    /// for each other destination that takes some files. Nil when none do.
    /// The same, one short line per destination for the drop area:
    /// "Images, Videos → Demo".
    static func summary(destinations: [DestinationConfig], defaultID: UUID?) -> [String] {
        destinations.filter { $0.id != defaultID }.compactMap { destination in
            guard let routing = destination.useFor, !routing.isEmpty else { return nil }
            let types = (routing.kinds.map(\.label) + routing.extensions.map { "." + $0 }).joined(separator: ", ")
            return "\(types) \u{2192} \(destination.name)"
        }
    }

    static func hints(destinations: [DestinationConfig], defaultID: UUID?) -> [String] {
        destinations.filter { $0.id != defaultID }.compactMap { destination in
            guard let routing = destination.useFor, !routing.isEmpty else { return nil }
            let parts = routing.kinds.map(\.label) + routing.extensions.map { "." + $0 }
            let list = ListFormatter.localizedString(byJoining: parts)
            return String(localized: "\(list) go to \(destination.name).")
        }
    }
}
