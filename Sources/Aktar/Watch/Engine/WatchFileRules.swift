import Darwin
import Foundation
import UniformTypeIdentifiers

/// What's known about a file on disk, gathered by `FileInspector`. Kept
/// separate from the rules so they can be checked without a disk.
struct FileFacts: Equatable, Sendable {
    var isRegularFile: Bool
    var isSymlink: Bool
    /// The hidden flag (dot-prefixed names are checked by name).
    var isHidden: Bool
    var size: Int64
    var modified: Date
    /// The inode, which survives a rename.
    var fileID: UInt64?
    /// An iCloud Drive file that's only in the cloud.
    var isCloudOnly: Bool
    /// macOS marked it as a screenshot or screen recording.
    var isScreenCapture: Bool
}

/// Why a file in a watched folder isn't uploaded.
enum FileRejection: Equatable, Sendable {
    case notRegularFile
    case symlink
    case hidden
    case empty
    case inUploadedFolder
    case inSubfolder
    case ignoredName
    case filteredOut
    case tooSmall
    case tooLarge
    case cloudOnly
}

/// The rules that decide which files of a watched folder are uploaded.
/// Everything here works on names and `FileFacts`, never on the disk.
enum WatchFileRules {
    /// Where "Move to Uploaded subfolder" puts files; never uploaded itself.
    static let uploadedFolderName = "Uploaded"

    /// Partial downloads, editor and sync tool temporaries, and system
    /// files, matched case-insensitively against the file's name.
    static let builtInIgnore = [
        "*.crdownload", "*.part", "*.partial", "*.download", "*.tmp", "*.temp",
        "~$*", "~WRL*.tmp", "~syncthing~*", ".syncthing.*", "*.icloud",
        "desktop.ini", "Thumbs.db", ".DS_Store", "*.swp", "*.lock",
    ]

    /// Checks the file at `relativePath` ("a/b/photo.png", "/" separators)
    /// in `folder`; nil means it's uploaded. `facts` nil checks only the
    /// name and place (an event for a path that's already gone).
    static func rejection(relativePath: String, facts: FileFacts?, folder: WatchedFolder) -> FileRejection? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return .notRegularFile }
        if components.contains(where: { $0.hasPrefix(".") }) { return .hidden }
        if components.count > 1 {
            if components[0].caseInsensitiveCompare(uploadedFolderName) == .orderedSame { return .inUploadedFolder }
            if folder.subfolders == .ignore { return .inSubfolder }
        }
        if builtInIgnore.contains(where: { matches($0, name: name, relativePath: relativePath) }) { return .ignoredName }

        let filter = folder.filter
        if filter.exclude.contains(where: { matches($0, name: name, relativePath: relativePath) }) { return .filteredOut }
        switch filter.kind {
        case .all, .screenshots:
            break
        case .images:
            if !conforms(name, to: .image) { return .filteredOut }
        case .videos:
            if !conforms(name, to: .movie) { return .filteredOut }
        case .custom:
            let patterns = filter.include.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !patterns.contains(where: { matches($0, name: name, relativePath: relativePath) }) { return .filteredOut }
        }

        guard let facts else { return nil }
        if facts.isSymlink { return .symlink }
        if !facts.isRegularFile { return .notRegularFile }
        if facts.isHidden { return .hidden }
        if facts.size == 0 { return .empty }
        if filter.kind == .screenshots, !facts.isScreenCapture { return .filteredOut }
        if let min = filter.minBytes, facts.size < min { return .tooSmall }
        if let max = filter.maxBytes, max > 0, facts.size > max { return .tooLarge }
        if facts.isCloudOnly, !folder.includeCloudOnly { return .cloudOnly }
        return nil
    }

    /// Whether nothing under the subfolder at `relativePath` can be
    /// uploaded, judged by its path alone: hidden folders (.git), the
    /// Uploaded folder, any subfolder when they're ignored, and folders an
    /// exclude pattern with "/" covers whole ("node_modules/*").
    static func isIgnoredDirectory(relativePath: String, folder: WatchedFolder) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }
        if folder.subfolders == .ignore { return true }
        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        if components[0].caseInsensitiveCompare(uploadedFolderName) == .orderedSame { return true }
        // A file name no pattern can be about: matching it means every file
        // in the folder matches.
        let probe = relativePath + "/\u{1}"
        return folder.filter.exclude.contains { $0.contains("/") && matches($0, name: "\u{1}", relativePath: probe) }
    }

    /// A glob (`*`, `?`, `[abc]`), case-insensitive. One without "/" is
    /// matched against the file's name, one with "/" against its path
    /// inside the folder.
    static func matches(_ pattern: String, name: String, relativePath: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        let subject = pattern.contains("/") ? relativePath : name
        return fnmatch(pattern, subject, FNM_CASEFOLD) == 0
    }

    /// Patterns typed into a field, one per line or separated by commas.
    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func conforms(_ name: String, to type: UTType) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let fileType = UTType(filenameExtension: ext) else { return false }
        return fileType.conforms(to: type)
    }
}

/// The {folder} and {subpath} path variables and where a kept folder
/// structure goes in a key.
enum WatchKeys {
    /// The folder's name as a single path segment.
    static func sanitizedFolderName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The directory of `relativePath` inside the watched folder ("" for a
    /// file at its top), or "" when the folder flattens subfolders.
    static func subpath(relativePath: String, mode: SubfolderMode) -> String {
        guard mode == .keepStructure else { return "" }
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    /// With the folder structure kept but no {subpath} in the template,
    /// the subfolders go in front of the key's last component:
    /// "2026/10/shot.png" and "trip/day1" give "2026/10/trip/day1/shot.png".
    static func insertingSubpath(_ subpath: String, into key: String) -> String {
        guard !subpath.isEmpty else { return key }
        let directory = (key as NSString).deletingLastPathComponent
        let name = (key as NSString).lastPathComponent
        return collapsingEmptySegments(directory.isEmpty ? "\(subpath)/\(name)" : "\(directory)/\(subpath)/\(name)")
    }

    /// "a//b" becomes "a/b", without a leading slash, so an empty {folder}
    /// or {subpath} leaves no trace.
    static func collapsingEmptySegments(_ key: String) -> String {
        let trailingSlash = key.hasSuffix("/")
        let collapsed = key.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return trailingSlash && !collapsed.isEmpty ? collapsed + "/" : collapsed
    }
}

/// Folders that can't be watched, and why.
enum ForbiddenFolderReason: Equatable, Sendable {
    case root
    case home
    case system
    case appData
    case containsWatched(String)
    case insideWatched(String)

    var message: String {
        switch self {
        case .root:
            return String(localized: "A whole disk can't be watched. Pick a folder on it instead.")
        case .home:
            return String(localized: "Your home folder can't be watched. Pick a folder inside it, such as Desktop or Downloads.")
        case .system:
            return String(localized: "System folders can't be watched.")
        case .appData:
            return String(localized: "Aktar's own folders can't be watched.")
        case .containsWatched(let name):
            return String(localized: "This folder contains \u{201C}\(name)\u{201D}, which is already watched.")
        case .insideWatched(let name):
            return String(localized: "This folder is inside \u{201C}\(name)\u{201D}, which is already watched.")
        }
    }
}

enum ForbiddenFolders {
    static let systemFolders = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/cores", "/opt"]

    /// Paths are compared as given, so pass them resolved (see
    /// `canonicalPath`). `existing` is the watched folders as (name, path).
    static func reason(
        for path: String,
        home: String,
        appDataFolders: [String],
        existing: [(name: String, path: String)],
        isVolumeRoot: Bool = false
    ) -> ForbiddenFolderReason? {
        let path = normalized(path)
        if path == "/" || isVolumeRoot || isUnderVolumes(path) { return .root }
        if same(path, normalized(home)) { return .home }
        for folder in existing {
            let other = normalized(folder.path)
            if same(path, other) || contains(other, path) { return .insideWatched(folder.name) }
            if contains(path, other) { return .containsWatched(folder.name) }
        }
        if systemFolders.contains(where: { same(path, $0) || contains($0, path) }) { return .system }
        if appDataFolders.map(normalized).contains(where: { same(path, $0) || contains($0, path) || contains(path, $0) }) {
            return .appData
        }
        return nil
    }

    /// "/Volumes/Disk" itself, the root of another disk.
    private static func isUnderVolumes(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count == 2 && parts[0] == "Volumes"
    }

    /// The path with symlinks resolved ("/var" is "/private/var"), so two
    /// spellings of one folder compare equal. A path that doesn't exist is
    /// returned standardized.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return normalized((path as NSString).standardizingPath)
        }
        defer { free(resolved) }
        return normalized(String(cString: resolved))
    }

    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Volumes are usually case-insensitive, so "Desktop" and "desktop" are
    /// the same folder.
    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Whether `child` is strictly inside `parent`.
    static func contains(_ parent: String, _ child: String) -> Bool {
        let prefix = parent == "/" ? "/" : parent + "/"
        return child.count > prefix.count && child.lowercased().hasPrefix(prefix.lowercased())
    }
}
