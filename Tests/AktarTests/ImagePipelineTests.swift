import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Photo metadata removal (location by default, everything on request)
/// and Image Processing (WebP, recompression, resizing), on real files.
final class ImagePipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImagePipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Metadata removal

    func testRemoveLocationKeepsTheRest() throws {
        let photo = try writeJPEG("photo.jpg", width: 64, height: 48, withLocation: true)
        XCTAssertTrue(ImageMetadataStripper.stillHasMetadataToRemove(at: photo, policy: .removeLocation))

        let copy = try XCTUnwrap(ImageMetadataStripper.strippedCopy(of: photo, policy: .removeLocation))
        defer { ImageMetadataStripper.removeCopy(copy) }
        XCTAssertEqual(copy.lastPathComponent, "photo.jpg")

        let properties = try Self.properties(of: copy)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "the location must be gone")
        XCTAssertEqual(Self.tiff(properties)[kCGImagePropertyTIFFMake] as? String, "Aktar Camera")
        XCTAssertEqual(Self.exif(properties)[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:10:01 12:00:00")
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertFalse(ImageMetadataStripper.stillHasMetadataToRemove(at: copy, policy: .removeLocation))
        try Self.assertDecodes(copy, width: 64, height: 48)

        // The original isn't touched.
        XCTAssertNotNil(try Self.properties(of: photo)[kCGImagePropertyGPSDictionary])
    }

    func testRemoveAllKeepsOnlyTheOrientation() throws {
        let photo = try writeJPEG("photo.jpg", width: 64, height: 48, withLocation: true)
        let copy = try XCTUnwrap(ImageMetadataStripper.strippedCopy(of: photo, policy: .removeAll))
        defer { ImageMetadataStripper.removeCopy(copy) }

        let properties = try Self.properties(of: copy)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(Self.tiff(properties)[kCGImagePropertyTIFFMake])
        XCTAssertNil(Self.tiff(properties)[kCGImagePropertyTIFFModel])
        XCTAssertNil(Self.exif(properties)[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(Self.exif(properties)[kCGImagePropertyExifBodySerialNumber])
        // Otherwise the photo shows sideways.
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertFalse(ImageMetadataStripper.stillHasMetadataToRemove(at: copy, policy: .removeAll))
        try Self.assertDecodes(copy, width: 64, height: 48)
    }

    func testNothingToRemoveUploadsTheOriginal() throws {
        let photo = try writeJPEG("photo.jpg", width: 16, height: 16, withLocation: true)
        XCTAssertNil(try ImageMetadataStripper.strippedCopy(of: photo, policy: .keepAll))

        let noLocation = try writeJPEG("plain.jpg", width: 16, height: 16, withLocation: false)
        XCTAssertNil(try ImageMetadataStripper.strippedCopy(of: noLocation, policy: .removeLocation))
        // Camera details still count under Remove all.
        let cleaned = try XCTUnwrap(ImageMetadataStripper.strippedCopy(of: noLocation, policy: .removeAll))
        ImageMetadataStripper.removeCopy(cleaned)

        let text = directory.appendingPathComponent("notes.txt")
        try Data("not a photo".utf8).write(to: text)
        XCTAssertNil(try ImageMetadataStripper.strippedCopy(of: text, policy: .removeAll))
    }

    func testPNGLocationIsRemoved() throws {
        let png = try writeImage("shot.png", type: UTType.png.identifier, width: 32, height: 32, withLocation: true)
        XCTAssertNotNil(try Self.properties(of: png)[kCGImagePropertyGPSDictionary], "fixture must carry a location")
        let copy = try XCTUnwrap(ImageMetadataStripper.strippedCopy(of: png, policy: .removeLocation))
        defer { ImageMetadataStripper.removeCopy(copy) }
        XCTAssertNil(try Self.properties(of: copy)[kCGImagePropertyGPSDictionary])
        try Self.assertDecodes(copy, width: 32, height: 32)
    }

    // MARK: - Image Processing

    func testOffLeavesThePhotoAlone() throws {
        let photo = try writeJPEG("photo.jpg", width: 64, height: 48, withLocation: false)
        XCTAssertNil(try ImageProcessor.process(photo, filename: "photo.jpg", settings: nil, policy: .removeLocation))
        XCTAssertNil(try ImageProcessor.process(photo, filename: "photo.jpg", settings: ImageProcessing(), policy: .removeLocation))
        // Never upscaled, and nothing else asked for.
        XCTAssertNil(try ImageProcessor.process(photo, filename: "photo.jpg", settings: ImageProcessing(maxLongEdge: 1920), policy: .removeLocation))
    }

    func testConvertsToWebPWithoutTheLocation() throws {
        let photo = try writeJPEG("Holiday.JPG", width: 120, height: 80, withLocation: true)
        let output = try XCTUnwrap(ImageProcessor.process(photo, filename: "Holiday.JPG", settings: ImageProcessing(format: .webp, quality: 80), policy: .removeLocation))
        defer { ImageProcessor.removeCopy(output.url) }

        XCTAssertEqual(output.filename, "Holiday.webp")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
        XCTAssertNil(try Self.properties(of: output.url)[kCGImagePropertyGPSDictionary])
        // The orientation was applied to the pixels: 120x80 turned upright.
        try Self.assertDecodes(output.url, width: 80, height: 120)
    }

    func testResizesTheLongestSide() throws {
        let photo = try writeJPEG("wide.jpg", width: 400, height: 200, withLocation: false, orientation: 1)
        let output = try XCTUnwrap(ImageProcessor.process(photo, filename: "wide.jpg", settings: ImageProcessing(maxLongEdge: 100), policy: .removeLocation))
        defer { ImageProcessor.removeCopy(output.url) }
        XCTAssertEqual(output.filename, "wide.jpg")
        try Self.assertDecodes(output.url, width: 100, height: 50)
    }

    func testAnimatedAndVectorFormatsAreLeftAlone() throws {
        let gif = try writeImage("anim.gif", type: UTType.gif.identifier, width: 32, height: 32, withLocation: false)
        XCTAssertNil(try ImageProcessor.process(gif, filename: "anim.gif", settings: ImageProcessing(format: .webp), policy: .removeLocation))
        let svg = directory.appendingPathComponent("logo.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8).write(to: svg)
        XCTAssertNil(try ImageProcessor.process(svg, filename: "logo.svg", settings: ImageProcessing(format: .webp), policy: .removeLocation))
    }

    func testResizeNeverUpscales() throws {
        let image = try Self.image(width: 300, height: 100)
        let smaller = try XCTUnwrap(ImageProcessor.resize(image, longestSide: 150))
        XCTAssertEqual(smaller.width, 150)
        XCTAssertEqual(smaller.height, 50)
        let same = try XCTUnwrap(ImageProcessor.resize(image, longestSide: 1000))
        XCTAssertEqual(same.width, 300)
        XCTAssertEqual(same.height, 100)
        // A sliver never collapses to zero.
        let sliver = try XCTUnwrap(ImageProcessor.resize(try Self.image(width: 1000, height: 1), longestSide: 10))
        XCTAssertEqual(sliver.height, 1)
    }

    func testKeptPropertiesFollowThePolicy() {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.0],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cam", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 4000, kCGImagePropertyExifLensModel: "Lens"],
        ]
        let keepAll = ImageProcessor.keptProperties(properties, policy: .keepAll)
        XCTAssertNotNil(keepAll[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(keepAll[kCGImagePropertyOrientation] as? Int, 1, "the pixels are already upright")
        XCTAssertEqual((keepAll[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? Int, 1)
        XCTAssertNil((keepAll[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifPixelXDimension], "the old size is dropped")
        XCTAssertEqual((keepAll[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel] as? String, "Lens")

        let noLocation = ImageProcessor.keptProperties(properties, policy: .removeLocation)
        XCTAssertNil(noLocation[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(noLocation[kCGImagePropertyTIFFDictionary])

        let nothing = ImageProcessor.keptProperties(properties, policy: .removeAll)
        XCTAssertEqual(nothing.count, 1)
        XCTAssertEqual(nothing[kCGImagePropertyOrientation] as? Int, 1)
    }

    func testWebPEncoding() throws {
        let data = try XCTUnwrap(ImageProcessor.encodeWebP(try Self.image(width: 20, height: 10), quality: 80))
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WEBP")
        let lossless = try XCTUnwrap(ImageProcessor.encodeWebP(try Self.image(width: 20, height: 10), quality: 100, lossless: true))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(lossless as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 20)
        XCTAssertEqual(decoded.height, 10)
    }

    // MARK: - Fixtures

    private func writeJPEG(_ name: String, width: Int, height: Int, withLocation: Bool, orientation: Int = 6) throws -> URL {
        try writeImage(name, type: UTType.jpeg.identifier, width: width, height: height, withLocation: withLocation, orientation: orientation)
    }

    /// A photo with camera details, a capture date and an orientation, and
    /// optionally where it was taken.
    private func writeImage(_ name: String, type: String, width: Int, height: Int, withLocation: Bool, orientation: Int = 6) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Aktar Camera",
                kCGImagePropertyTIFFModel: "Test 1",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
                kCGImagePropertyExifBodySerialNumber: "SN-123",
            ],
        ]
        if withLocation {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 41.0082,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 28.9784,
                kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(destination, try Self.image(width: width, height: height), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A gradient, so lossy encoders have something to work on.
    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(max(width, 1)), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(max(width, 1)), alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private static func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private static func tiff(_ properties: [CFString: Any]) -> [CFString: Any] {
        properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    }

    private static func exif(_ properties: [CFString: Any]) -> [CFString: Any] {
        properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    }

    private static func assertDecodes(_ url: URL, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
    }
}
