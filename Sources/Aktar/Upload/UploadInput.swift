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
    let originalFilename: String
    let source: UploadSource
    /// Uploads to exactly this key instead of one generated from the
    /// destination's object path template (used by the bucket browser).
    var objectKey: String? = nil
}
