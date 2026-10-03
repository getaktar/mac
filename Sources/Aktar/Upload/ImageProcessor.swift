import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import libwebp

enum ImageProcessor {
    /// Bigger files are uploaded as they are: decoding one takes a lot of
    /// memory, and it's rarely a photo meant to be shrunk.
    static let maxSourceBytes: Int64 = 200 * 1024 * 1024

    /// ImageIO writes AVIF on recent macOS only.
    static let canEncodeAVIF: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(avifType)
    }()

    private static let webpType = "org.webmproject.webp"
    private static let avifType = "public.avif"
    private static let bmpType = UTType.bmp.identifier

    /// Raster formats that are processed. GIF (could be animated), SVG,
    /// PDF and everything else are left alone.
    private static let processableTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        webpType,
        UTType.tiff.identifier,
        bmpType,
    ]

    /// Formats that lose quality on every save, and so are worth
    /// recompressing in their own format.
    private static let lossyTypes: Set<String> = [
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        webpType,
    ]

    struct Output {
        /// The processed copy; the caller deletes it with `removeCopy`.
        let url: URL
        /// `filename` with the new format's extension.
        let filename: String
    }

    /// A processed copy of the photo at `url`, or nil when it's uploaded as
    /// it is (not a photo, nothing to do, or the result wasn't smaller).
    /// The metadata `policy` is applied to the copy, so it doesn't go
    /// through `ImageMetadataStripper` again. `filename` is the name the
    /// upload goes by, whose extension changes with the format.
    static func process(_ url: URL, filename: String, settings: ImageProcessing?, policy: ImageMetadataPolicy) throws -> Output? {
        guard let settings, !settings.isOff else { return nil }
        let sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard sourceSize > 0, sourceSize <= maxSourceBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              processableTypes.contains(type) else { return nil }
        let count = CGImageSourceGetCount(source)
        // An animated PNG or WebP would lose its animation.
        guard count > 0, count == 1 || !(type == UTType.png.identifier || type == webpType) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let longest = max(pixelWidth, pixelHeight)
        let needsResize = settings.maxLongEdge.map { longest > $0 } ?? false

        var format = settings.format
        if format == .avif, !canEncodeAVIF { format = .original }

        let targetType: String
        switch format {
        case .webp: targetType = webpType
        case .avif: targetType = avifType
        case .original:
            let recompress = settings.quality != nil && lossyTypes.contains(type)
            guard needsResize || recompress else { return nil }
            targetType = type
        }

        // Pixels upright (EXIF orientation applied), at full size or the
        // resized one.
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        var image = decoded
        if needsResize, let maxLongEdge = settings.maxLongEdge {
            guard let resized = resize(decoded, longestSide: maxLongEdge) else { return nil }
            image = resized
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarProcessing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newExtension: String = switch format {
        case .webp: "webp"
        case .avif: "avif"
        case .original: (filename as NSString).pathExtension
        }
        let base = (filename as NSString).deletingPathExtension
        let outputName = newExtension.isEmpty ? base : base + "." + newExtension
        let output = directory.appendingPathComponent(outputName.isEmpty ? "image" : outputName)

        let quality = Double(settings.quality ?? 90) / 100
        let written: Bool
        if targetType == webpType {
            let lossless = settings.quality == nil && type == UTType.png.identifier && hasAlpha(image)
            written = writeWebP(image, to: output, quality: Float(quality * 100), lossless: lossless,
                                metadata: webpMetadata(source: source, policy: policy))
        } else {
            written = writeImageIO(image, to: output, type: targetType, quality: lossyTypes.contains(targetType) || targetType == avifType ? quality : nil,
                                   properties: keptProperties(properties, policy: policy))
        }
        guard written else {
            try? FileManager.default.removeItem(at: directory)
            // Nothing was uploaded yet, so the photo still goes up, only
            // not processed; the metadata policy still applies to it then.
            return nil
        }
        if policy != .keepAll, ImageMetadataStripper.stillHasMetadataToRemove(at: output, policy: policy) {
            try? FileManager.default.removeItem(at: directory)
            throw ImageMetadataError.couldNotRewrite(filename)
        }

        // Recompressed in its own format without being resized: only worth
        // it when it's actually smaller.
        if format == .original, !needsResize {
            let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? .max
            if newSize >= sourceSize {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }
        return Output(url: output, filename: outputName)
    }

    /// Deletes a copy made by `process`.
    static func removeCopy(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The longest side at most `longestSide`, never upscaled, scaled with
    /// Core Graphics' high quality filter in the image's own color space.
    static func resize(_ image: CGImage, longestSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longestSide else { return image }
        let scale = Double(longestSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitsPerComponent = image.bitsPerComponent > 8 ? 16 : 8
        let alpha: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alpha.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: - Metadata

    /// The source's metadata for an ImageIO destination, as the policy
    /// allows: everything, everything but the location, or nothing. The
    /// pixels are already upright, so the orientation is reset, and the
    /// old pixel size is dropped.
    static func keptProperties(_ properties: [CFString: Any], policy: ImageMetadataPolicy) -> [CFString: Any] {
        var kept: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard policy != .removeAll else { return kept }
        let dictionaries: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary,
        ]
        for key in dictionaries {
            if key == kCGImagePropertyGPSDictionary, policy == .removeLocation { continue }
            if let value = properties[key] { kept[key] = value }
        }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            kept[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { kept[key] = value }
        }
        return kept
    }

    /// WebP carries metadata as XMP: the source's, as the policy allows.
    private static func webpMetadata(source: CGImageSource, policy: ImageMetadataPolicy) -> Data? {
        guard policy != .removeAll,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let copy = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        var removable: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(copy, nil, nil) { path, _ in
            let name = path as String
            if name.hasSuffix("PixelXDimension") || name.hasSuffix("PixelYDimension") {
                removable.append(name)
            } else if policy == .removeLocation, name.hasPrefix("exif:GPS") || name.hasPrefix("exifEX:GPS") {
                removable.append(name)
            }
            return true
        }
        for path in removable {
            CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString)
        }
        CGImageMetadataSetValueWithPath(copy, nil, "tiff:Orientation" as CFString, 1 as CFNumber)
        return CGImageMetadataCreateXMPData(copy, nil) as Data?
    }

    // MARK: - Encoders

    private static func writeImageIO(_ image: CGImage, to url: URL, type: String, quality: Double?, properties: [CFString: Any]) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        var options = properties
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Lossy (or lossless) WebP through libwebp, as ImageIO can only read
    /// it. The color profile and the XMP metadata go in their own chunks.
    private static func writeWebP(_ image: CGImage, to url: URL, quality: Float, lossless: Bool, metadata: Data?) -> Bool {
        // libwebp takes 8-bit RGBA without premultiplied alpha. The pixels
        // stay in the image's own RGB color space, whose profile is
        // embedded; anything else (grayscale, CMYK) becomes sRGB.
        let sourceSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let colorSpace = sourceSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        if hasAlpha(image) {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[index + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }

        var encoded: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer -> Int in
            lossless
                ? WebPEncodeLosslessRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), &encoded)
                : WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), quality, &encoded)
        }
        guard size > 0, let encoded else { return false }
        defer { WebPFree(encoded) }

        let icc = sourceSpace.flatMap { space -> Data? in
            // sRGB is what a WebP without a profile is shown as anyway.
            guard space.name != CGColorSpace.sRGB else { return nil }
            return space.copyICCData() as Data?
        }
        guard icc != nil || metadata != nil else {
            return FileManager.default.createFile(atPath: url.path, contents: Data(bytes: encoded, count: size))
        }

        guard let mux = WebPMuxNew() else { return false }
        defer { WebPMuxDelete(mux) }
        var bitstream = WebPData(bytes: encoded, size: size)
        guard WebPMuxSetImage(mux, &bitstream, 1) == WEBP_MUX_OK else { return false }
        func setChunk(_ fourCC: String, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw -> Bool in
                var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: data.count)
                return WebPMuxSetChunk(mux, fourCC, &chunk, 1) == WEBP_MUX_OK
            }
        }
        if let icc, !setChunk("ICCP", icc) { return false }
        if let metadata, !setChunk("XMP ", metadata) { return false }
        var assembled = WebPData()
        guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK, let bytes = assembled.bytes else { return false }
        defer { WebPDataClear(&assembled) }
        return FileManager.default.createFile(atPath: url.path, contents: Data(bytes: bytes, count: assembled.size))
    }
}
