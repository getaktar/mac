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
}
