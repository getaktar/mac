import Foundation

enum ObjectKeyGenerator {
    /// `hashes` fills {md5} and {sha256}; see `ContentHasher`. Left empty,
    /// those variables are dropped. `folder` and `subpath` fill {folder} and
    /// {subpath} for a file from a watched folder (its name, and the
    /// subfolders it's in); they're empty for every other upload. Empty
    /// segments collapse, so "{folder}/{filename}" is just the name then.
    static func generate(
        template: String,
        originalFilename: String,
        date: Date = .now,
        hashes: ContentHashes = ContentHashes(),
        folder: String = "",
        subpath: String = ""
    ) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timeString = timeFormatter.string(from: date)

        let ext = removingUnsafeCharacters((originalFilename as NSString).pathExtension)
        let nameWithoutExt = sanitizedFilename((originalFilename as NSString).deletingPathExtension)
        let uuid = UUID().uuidString.lowercased()
        let random = String(UUID().uuidString.prefix(8)).lowercased()

        let replacements: [(String, String)] = [
            ("{year}", year),
            ("{month}", month),
            ("{day}", day),
            ("{date}", dateString),
            ("{time}", timeString),
            ("{filename}", nameWithoutExt),
            ("{uuid}", uuid),
            ("{random}", random),
            ("{ext}", ext),
            ("{md5}", hashes.md5 ?? ""),
            ("{sha256}", hashes.sha256 ?? ""),
            ("{folder}", WatchKeys.sanitizedFolderName(folder)),
            ("{subpath}", subpath),
        ]

        var result = template
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return WatchKeys.collapsingEmptySegments(result)
    }

    /// {filename} as one safe path segment: no slashes, backslashes, NUL or
    /// other control characters, and never empty, "." or "..".
    static func sanitizedFilename(_ name: String) -> String {
        let cleaned = removingUnsafeCharacters(name)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    private static func removingUnsafeCharacters(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !isControl(scalar)
        }.map(Character.init))
    }

    /// NUL and the other C0/C1 control characters (not format characters
    /// such as the joiner inside an emoji).
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }

    /// Whether every key `template` makes is new: it has a random part
    /// ({uuid}, {random}) or one that only repeats for the same contents
    /// ({md5}, {sha256}). Otherwise a key it makes can be taken already.
    static func hasUniqueToken(_ template: String) -> Bool {
        ["{uuid}", "{random}", "{md5}", "{sha256}"].contains { template.contains($0) }
    }

    /// Why a key, prefix, folder name or move target the user typed can't
    /// be used, or nil when it can. `.` and `..` segments (which some
    /// clients and servers resolve), empty segments in the middle ("a//b"),
    /// control characters and a leading "/" are refused; a trailing "/"
    /// is fine when `allowsTrailingSlash` (a folder).
    static func problem(withUserKey key: String, allowsTrailingSlash: Bool = false) -> UserKeyProblem? {
        if key.unicodeScalars.contains(where: isControl) { return .controlCharacter }
        if key.hasPrefix("/") { return .leadingSlash }
        var segments = key.split(separator: "/", omittingEmptySubsequences: false)
        if allowsTrailingSlash, segments.count > 1, segments.last == "" { segments.removeLast() }
        if segments.contains(where: { $0 == "." || $0 == ".." }) { return .dotSegment }
        if segments.contains(where: \.isEmpty), !key.isEmpty { return .emptySegment }
        return nil
    }

    /// Which content hashes `template` needs, so they're only computed
    /// when used.
    static func usesMD5(_ template: String) -> Bool { template.contains("{md5}") }
    static func usesSHA256(_ template: String) -> Bool { template.contains("{sha256}") }
}

enum UserKeyProblem: Error, Equatable, LocalizedError {
    case controlCharacter
    case leadingSlash
    case dotSegment
    case emptySegment

    var errorDescription: String? {
        switch self {
        case .controlCharacter:
            return String(localized: "A name or path can\u{2019}t contain control characters.")
        case .leadingSlash:
            return String(localized: "A name or path can\u{2019}t start with \u{201C}/\u{201D}.")
        case .dotSegment:
            return String(localized: "A name or path can\u{2019}t have \u{201C}.\u{201D} or \u{201C}..\u{201D} as a folder or file name.")
        case .emptySegment:
            return String(localized: "A path can\u{2019}t have an empty folder name (\u{201C}//\u{201D}).")
        }
    }
}
