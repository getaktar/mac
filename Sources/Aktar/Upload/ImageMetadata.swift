import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What happens to a photo's metadata before it's uploaded. Set per
/// destination in its Upload Defaults; nil there means `.default`.
enum ImageMetadataPolicy: String, CaseIterable, Identifiable, Codable {
    /// Drops GPS coordinates and keeps everything else (camera, date,
    /// orientation, color profile). The default, so a shared photo never
    /// gives away where it was taken.
    case removeLocation
    /// Drops EXIF, GPS, IPTC and XMP. Orientation and the color profile
    /// stay, so the image still looks the same.
    case removeAll
    case keepAll

    static let `default` = ImageMetadataPolicy.removeLocation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .removeLocation: return String(localized: "Remove location")
        case .removeAll: return String(localized: "Remove all")
        case .keepAll: return String(localized: "Keep all")
        }
    }
}

enum ImageMetadataError: LocalizedError {
    case couldNotRewrite(String)

    var errorDescription: String? {
        switch self {
        case .couldNotRewrite(let filename):
            // Uploading anyway could share where the photo was taken.
            return String(localized: "Couldn't remove the metadata from \(filename), so it wasn't uploaded. Set Image metadata to Keep all for this destination to upload it as it is.")
        }
    }
}

enum ImageMetadataStripper {
    /// Formats ImageIO can rewrite without re-encoding the pixels.
    private static let rewritableTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
    ]

    /// A copy of `url` without the metadata `policy` removes, or nil when
    /// the original can be uploaded as it is: not a photo format, or
    /// nothing in it to remove. The copy is lossless where ImageIO can
    /// manage it; the caller deletes it after the upload.
    static func strippedCopy(of url: URL, policy: ImageMetadataPolicy) throws -> URL? {
        guard policy != .keepAll,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              rewritableTypes.contains(type),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard hasMetadataToRemove(properties, source: source, policy: policy) else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarMetadata", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(url.lastPathComponent)

        // First try copying the compressed image data as it is, with new
        // metadata. ImageIO handles this differently per format (PNG keeps
        // its metadata no matter what), so the result is checked.
        if let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil),
           CGImageDestinationCopyImageSource(destination, source, copyOptions(source: source, properties: properties, policy: policy) as CFDictionary, nil),
           !stillHasMetadataToRemove(at: output, policy: policy) {
            return output
        }

        // Otherwise write the image out again with only the metadata to keep:
        // lossless for PNG and TIFF, full quality for JPEG and HEIC.
        try? FileManager.default.removeItem(at: output)
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) {
            var kept: [CFString: Any]
            if policy == .removeLocation {
                kept = properties
                kept.removeValue(forKey: kCGImagePropertyGPSDictionary)
            } else {
                kept = [:]
                if let orientation = properties[kCGImagePropertyOrientation] {
                    kept[kCGImagePropertyOrientation] = orientation
                }
            }
            kept[kCGImageDestinationLossyCompressionQuality] = 1.0
            CGImageDestinationAddImage(destination, image, kept as CFDictionary)
            if CGImageDestinationFinalize(destination), !stillHasMetadataToRemove(at: output, policy: policy) {
                return output
            }
        }

        try? FileManager.default.removeItem(at: directory)
        throw ImageMetadataError.couldNotRewrite(url.lastPathComponent)
    }

    private static func copyOptions(source: CGImageSource, properties: [CFString: Any], policy: ImageMetadataPolicy) -> [CFString: Any] {
        if policy == .removeLocation {
            // Passing the source's own metadata back keeps it; without it,
            // JPEG copies drop everything.
            var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                options[kCGImageDestinationMetadata] = metadata
            }
            return options
        }
        // A fresh set that only says which way is up, so the photo isn't
        // shown sideways.
        let kept = CGImageMetadataCreateMutable()
        if let orientation = properties[kCGImagePropertyOrientation] as? NSNumber {
            CGImageMetadataSetValueMatchingImageProperty(kept, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation)
        }
        return [
            kCGImageDestinationMetadata: kept,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
    }

    /// Deletes a copy made by `strippedCopy`.
    static func removeCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func hasMetadataToRemove(_ properties: [CFString: Any], source: CGImageSource, policy: ImageMetadataPolicy) -> Bool {
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        guard policy == .removeAll else { return false }
        let removable = [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary]
        if removable.contains(where: { properties[$0] != nil }) { return true }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag], !tags.isEmpty {
            return true
        }
        return false
    }

    private static func stillHasMetadataToRemove(at url: URL, policy: ImageMetadataPolicy) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return true }
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        guard policy == .removeAll else { return false }
        let identifying = [kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary]
        if identifying.contains(where: { properties[$0] != nil }) { return true }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        // ImageIO always reports a few structural fields (size, color
        // space, orientation); what matters is anything that identifies
        // the camera, the person or the time.
        let identifyingKeys: [CFString] = [
            kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifLensModel,
            kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment,
        ]
        let identifyingTIFF: [CFString] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist]
        return identifyingKeys.contains { exif[$0] != nil } || identifyingTIFF.contains { tiff[$0] != nil }
    }
}
