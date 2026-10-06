import AppKit
import ImageIO
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A thumbnail ready to keep, here and in the bucket: WebP, which is a
/// tenth the size of a PNG of the same picture. PNG only if WebP couldn't
/// be encoded, and then it stays on this Mac.
struct GeneratedThumbnail: Sendable {
    let data: Data

    var isWebP: Bool { ThumbnailGenerator.isWebP(data) }
}

/// Makes thumbnails the way Finder does. Photos are decoded straight to a
/// small bitmap with Image I/O; everything else (videos, PDFs, RAW photos,
/// Office and iWork documents, fonts, 3D models, text) goes through Quick
/// Look, which runs outside the app, so a damaged or huge file can't take
/// Aktar down. A file Quick Look only has an icon for gets no thumbnail.
enum ThumbnailGenerator {
    /// Longest side of a thumbnail, in pixels: sharp in rows on Retina
    /// displays, and up to 256 pt wide where a file's details show one.
    static let maxPixelSize = 512
    /// Quick Look gets this long per file; a stuck generator is cancelled.
    static let timeout: Duration = .seconds(15)
    private static let webpQuality: Float = 80

    static func make(from url: URL) async -> GeneratedThumbnail? {
        guard !FolderUpload.isFolder(url), canHaveThumbnail(filename: url.lastPathComponent) else { return nil }
        if let thumbnail = imageIOThumbnail(url) { return thumbnail }
        return await quickLookThumbnail(url)
    }

    /// Whether a file of this name could have a thumbnail at all; archives,
    /// disk images and apps only ever have icons.
    static func canHaveThumbnail(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        let iconOnly: [UTType] = [.archive, .diskImage, .executable, .application, .applicationBundle, .folder]
        return !iconOnly.contains { type.conforms(to: $0) }
    }

    /// Image I/O decodes straight to a downscaled bitmap that keeps the
    /// aspect ratio and honors EXIF orientation, without loading the
    /// full-size image first. An image too large to decode safely here is
    /// left to Quick Look.
    private static func imageIOThumbnail(_ url: URL) -> GeneratedThumbnail? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              !ImagePixelLimit.isTooLarge(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    /// Quick Look's generator and request aren't Sendable, but both are
    /// safe to use from any thread; this lets the timeout task cancel the
    /// request (older Swift compilers refuse the plain captures).
    private struct QuickLookJob: @unchecked Sendable {
        let generator: QLThumbnailGenerator
        let request: QLThumbnailGenerator.Request
    }

    private static func quickLookThumbnail(_ url: URL) async -> GeneratedThumbnail? {
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Only a real thumbnail: `.icon` would hand back the file's icon.
        let job = QuickLookJob(
            generator: QLThumbnailGenerator.shared,
            request: QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 1, representationTypes: .thumbnail)
        )
        let finished = OSAllocatedUnfairLock(initialState: false)
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            if !finished.withLock({ $0 }) { job.generator.cancel(job.request) }
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            job.generator.generateBestRepresentation(for: job.request) { representation, _ in
                finished.withLock { $0 = true }
                continuation.resume(returning: representation.flatMap { encode($0.cgImage) })
            }
        }
    }

    /// Never larger than `maxPixelSize`, whatever the generator returned.
    private static func encode(_ image: CGImage) -> GeneratedThumbnail? {
        guard let image = ImageProcessor.resize(image, longestSide: maxPixelSize) else { return nil }
        if let webp = ImageProcessor.encodeWebP(image, quality: webpQuality) { return GeneratedThumbnail(data: webp) }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]).map(GeneratedThumbnail.init)
    }

    /// "RIFF", a length, then "WEBP".
    static func isWebP(_ data: Data) -> Bool {
        data.count > 12 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WEBP".utf8)
    }
}
