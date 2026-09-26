import AppKit
import Foundation

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

    static func store(sourceURL: URL, for id: UUID) {
        guard let image = NSImage(contentsOf: sourceURL) else { return }
        let targetSize = NSSize(width: 160, height: 160)
        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        thumbnail.unlockFocus()

        guard let tiff = thumbnail.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return }

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
