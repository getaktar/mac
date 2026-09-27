import AppKit
import Foundation
import ImageIO

/// History is metadata-first: the original uploaded file is never copied
/// permanently, only a small local thumbnail.
enum ThumbnailCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Longest side of a stored thumbnail, in pixels. History rows show
    /// them at up to 96pt, so this stays sharp on Retina displays.
    private static let maxPixelSize = 320

    static func store(sourceURL: URL, for id: UUID) {
        // Image I/O decodes straight to a downscaled bitmap that keeps the
        // aspect ratio and honors EXIF orientation, without loading the
        // full-size image first.
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let pngData = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) else { return }

        try? pngData.write(to: fileURL(for: id))
    }

    static func image(for id: UUID) -> NSImage? {
        NSImage(contentsOf: fileURL(for: id))
    }

    static func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }
}
