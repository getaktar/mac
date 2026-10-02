import Foundation

enum UploadSource {
    case finder
    case clipboard
    case dragDrop
    case filePicker
    case finderExtension
    /// Picked up from a watched folder, by its ID.
    case watchedFolder(UUID)
}

struct UploadInput: Sendable {
    let fileURL: URL
    var originalFilename: String
    let source: UploadSource
    /// Uploads to exactly this key instead of one generated from the
    /// destination's object path template (used by the bucket browser).
    var objectKey: String? = nil
    /// A file from a folder uploaded with its structure: its key, under the
    /// folder's own prefix. Unlike `objectKey`, "Delete after" still applies.
    var folderKey: String? = nil
    /// The folder upload this file belongs to, so the links are copied
    /// together once the last one is done.
    var group: UploadGroup? = nil
    /// A file from a watched folder: where it came from and that folder's
    /// rules. Its uploads skip the usual clipboard copy, notification and
    /// closing the panel; the folder decides those.
    var watch: WatchUploadContext? = nil
}

struct WatchUploadContext: Sendable {
    /// The watcher's ID for this upload; see `WatchUploading`.
    let requestID: UUID
    let folderID: UUID
    let folderName: String
    /// The folder's own Object Path, or nil for the destination's.
    let pathTemplate: String?
    /// {subpath}: the subfolders the file is in, when the folder keeps its
    /// structure.
    let subpath: String
    let keepStructure: Bool
    /// The file's SHA-256 when the watcher already read it; the upload
    /// doesn't read the file for it again.
    var sha256: String? = nil
    /// The folder reacts to changes: the upload hashes the file in the pass
    /// it makes anyway, for the ledger.
    var wantsContentHash = false
}

struct UploadGroup: Sendable, Hashable {
    let id: UUID
    let name: String
    let index: Int
    let count: Int
}
