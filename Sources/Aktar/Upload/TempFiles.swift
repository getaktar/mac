import Foundation

/// Aktar's own folders in the app's temporary directory. Each job or
/// request works in a folder of its own (a UUID) inside one of these, and
/// removes it when done; whatever a crash or a quit left behind goes at
/// the next launch.
enum TempFiles {
    static let clipboard = "AktarClipboard"
    static let localAPI = "AktarLocalAPI"
    static let zip = "AktarZip"
    static let processing = "AktarProcessing"
    static let metadata = "AktarMetadata"
    /// Files downloaded from a bucket to make their thumbnails.
    static let thumbnails = "AktarThumbnails"
    /// Files handed over by a Shortcuts action.
    static let intents = "AktarIntents"

    private static let owned = [clipboard, localAPI, zip, processing, metadata, thumbnails, intents]

    static func folder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// A new, empty folder of its own inside `name`.
    static func newFolder(in name: String) throws -> URL {
        let directory = folder(name).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Empties Aktar's temporary folders. Only called at launch, before any
    /// upload or request could be using them.
    static func purgeAtLaunch() {
        let manager = FileManager.default
        for name in owned {
            try? manager.removeItem(at: folder(name))
        }
        // Clipboard images of versions before 0.13 sat at the top level.
        let leftovers = (try? manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path)) ?? []
        for name in leftovers where name.hasPrefix("clipboard-") && name.hasSuffix(".png") {
            try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent(name))
        }
    }

    /// Deletes the file Aktar made for an upload (a clipboard image) along
    /// with its folder. Any other file is left alone.
    static func removeIfOwned(_ url: URL) {
        let root = folder(clipboard).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
