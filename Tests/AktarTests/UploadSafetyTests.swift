import ImageIO
import UniformTypeIdentifiers
import XCTest

final class UploadSafetyTests: XCTestCase {
    func testPixelLimit() {
        XCTAssertFalse(ImagePixelLimit.isTooLarge(width: 10_000, height: 10_000))
        XCTAssertTrue(ImagePixelLimit.isTooLarge(width: 10_001, height: 10_000))
        XCTAssertTrue(ImagePixelLimit.isTooLarge(width: Int.max, height: 2))
    }

    func testPixelLimitReadsTheHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.png(width: 4, height: 3).write(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertFalse(ImagePixelLimit.isTooLarge(source))

        let notAnImage = Data("hello".utf8)
        let textSource = try XCTUnwrap(CGImageSourceCreateWithData(notAnImage as CFData, nil))
        XCTAssertTrue(ImagePixelLimit.isTooLarge(textSource))
    }

    func testReusedObjectMustBeUnchanged() {
        let uploadedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(DuplicateReuse.isUnchanged(size: 10, lastModified: uploadedAt, uploadedSize: 10, uploadedAt: uploadedAt))
        XCTAssertTrue(DuplicateReuse.isUnchanged(size: 10, lastModified: uploadedAt.addingTimeInterval(240), uploadedSize: 10, uploadedAt: uploadedAt))
        // Replaced by a file of another size, or later on.
        XCTAssertFalse(DuplicateReuse.isUnchanged(size: 11, lastModified: uploadedAt, uploadedSize: 10, uploadedAt: uploadedAt))
        XCTAssertFalse(DuplicateReuse.isUnchanged(size: 10, lastModified: uploadedAt.addingTimeInterval(3_600), uploadedSize: 10, uploadedAt: uploadedAt))
        XCTAssertFalse(DuplicateReuse.isUnchanged(size: 10, lastModified: nil, uploadedSize: 10, uploadedAt: uploadedAt))
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
