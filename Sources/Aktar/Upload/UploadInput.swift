import Foundation

enum UploadSource {
    case finder
    case clipboard
    case dragDrop
    case filePicker
    case finderExtension
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
}

struct UploadGroup: Sendable, Hashable {
    let id: UUID
    let name: String
    let index: Int
    let count: Int
}
