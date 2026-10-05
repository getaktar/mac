import XCTest

final class ThumbnailKeysTests: XCTestCase {
    private let prefix = ThumbnailKeys.defaultPrefix

    func testKeyMirrorsTheFile() {
        XCTAssertEqual(ThumbnailKeys.key(for: "photos/cat.png", prefix: prefix), ".aktar/thumbnails/photos/cat.png.webp")
        XCTAssertEqual(ThumbnailKeys.key(for: "cat", prefix: "thumbs/"), "thumbs/cat.webp")
    }

    func testExpiringFileKeepsItsThumbnailInTheSameExpiringFolder() {
        // The bucket's tmp/7d/ rule then deletes both.
        XCTAssertEqual(ThumbnailKeys.key(for: "tmp/7d/photos/cat.png", prefix: prefix), "tmp/7d/.aktar/thumbnails/photos/cat.png.webp")
        XCTAssertEqual(ThumbnailKeys.key(for: "tmp/1d/a.mov", prefix: prefix), "tmp/1d/.aktar/thumbnails/a.mov.webp")
        // Not an expiring folder Aktar uses.
        XCTAssertEqual(ThumbnailKeys.key(for: "tmp/2d/a.mov", prefix: prefix), ".aktar/thumbnails/tmp/2d/a.mov.webp")
    }

    func testNoThumbnailOfAFolderOrAThumbnail() {
        XCTAssertNil(ThumbnailKeys.key(for: "photos/", prefix: prefix))
        XCTAssertNil(ThumbnailKeys.key(for: "", prefix: prefix))
        XCTAssertNil(ThumbnailKeys.key(for: ".aktar/thumbnails/a.png.webp", prefix: prefix))
        XCTAssertNil(ThumbnailKeys.key(for: "tmp/7d/.aktar/thumbnails/a.png.webp", prefix: prefix))
    }

    func testRecognizesThumbnails() {
        XCTAssertTrue(ThumbnailKeys.isThumbnail(".aktar/thumbnails/a.png.webp", prefixes: [prefix]))
        XCTAssertTrue(ThumbnailKeys.isThumbnail("tmp/30d/.aktar/thumbnails/a.png.webp", prefixes: [prefix]))
        XCTAssertFalse(ThumbnailKeys.isThumbnail(".aktar/other/a.png", prefixes: [prefix]))
        XCTAssertFalse(ThumbnailKeys.isThumbnail(".aktar/thumbnails/a.png.webp", prefixes: []))
    }

    func testHidesThumbnailFoldersAndDotFoldersLeadingThere() {
        XCTAssertTrue(ThumbnailKeys.isHiddenFolder(".aktar/", prefixes: [prefix]))
        XCTAssertTrue(ThumbnailKeys.isHiddenFolder(".aktar/thumbnails/", prefixes: [prefix]))
        XCTAssertTrue(ThumbnailKeys.isHiddenFolder(".aktar/thumbnails/photos/", prefixes: [prefix]))
        XCTAssertTrue(ThumbnailKeys.isHiddenFolder("tmp/7d/.aktar/", prefixes: [prefix]))
        // The folders around them stay.
        XCTAssertFalse(ThumbnailKeys.isHiddenFolder("tmp/", prefixes: [prefix]))
        XCTAssertFalse(ThumbnailKeys.isHiddenFolder("tmp/7d/", prefixes: [prefix]))
        XCTAssertFalse(ThumbnailKeys.isHiddenFolder("media/", prefixes: ["media/thumbs/"]))
        XCTAssertTrue(ThumbnailKeys.isHiddenFolder("media/thumbs/", prefixes: ["media/thumbs/"]))
        XCTAssertFalse(ThumbnailKeys.isHiddenFolder(".aktar/", prefixes: []))
    }

    func testPrefixValidation() {
        XCTAssertEqual(ThumbnailKeys.normalizedPrefix(" /previews// "), "previews/")
        XCTAssertNil(ThumbnailKeys.normalizedPrefix(" / "))
        XCTAssertNil(ThumbnailKeys.problem(withPrefix: "previews"))
        XCTAssertNil(ThumbnailKeys.problem(withPrefix: ".aktar/thumbnails/"))
        XCTAssertNotNil(ThumbnailKeys.problem(withPrefix: ""))
        XCTAssertNotNil(ThumbnailKeys.problem(withPrefix: "tmp/thumbs"))
        XCTAssertNotNil(ThumbnailKeys.problem(withPrefix: "a/../b"))
        XCTAssertNotNil(ThumbnailKeys.problem(withPrefix: "a//b"))
    }

    func testModeDefaultsAndPrefixes() {
        var destination = Self.destination(bucket: "files")
        XCTAssertEqual(destination.thumbnailMode, .local)
        XCTAssertNil(destination.bucketThumbnailPrefix)
        destination.thumbnails = .bucket
        XCTAssertEqual(destination.bucketThumbnailPrefix, ThumbnailKeys.defaultPrefix)
        destination.thumbnailPrefix = "previews/"
        XCTAssertEqual(destination.bucketThumbnailPrefix, "previews/")
    }

    func testPrefixesOfProfilesSharingTheBucket() {
        let local = Self.destination(bucket: "files")
        var sameBucket = Self.destination(bucket: "files")
        sameBucket.thumbnails = .bucket
        sameBucket.thumbnailPrefix = "previews/"
        var otherBucket = Self.destination(bucket: "other")
        otherBucket.thumbnails = .bucket
        let all = [local, sameBucket, otherBucket]
        XCTAssertEqual(ThumbnailKeys.bucketPrefixes(for: local, among: all), ["previews/"])
        XCTAssertEqual(ThumbnailKeys.bucketPrefixes(for: otherBucket, among: all), [ThumbnailKeys.defaultPrefix])
        var off = local
        off.thumbnails = .off
        XCTAssertEqual(ThumbnailKeys.bucketPrefixes(for: off, among: [off]), [])
    }

    func testCanHaveThumbnail() {
        for name in ["a.png", "a.mov", "a.mp4", "a.pdf", "a.heic", "a.docx", "a.key", "a.txt", "a.cr2"] {
            XCTAssertTrue(ThumbnailGenerator.canHaveThumbnail(filename: name), name)
        }
        for name in ["a.zip", "a.dmg", "a.app", "noextension"] {
            XCTAssertFalse(ThumbnailGenerator.canHaveThumbnail(filename: name), name)
        }
    }

    func testGeneratesFromAnImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let thumbnail = try await XCTUnwrapAsync(await ThumbnailGenerator.make(from: url))
        XCTAssertTrue(thumbnail.isWebP)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 512)
        XCTAssertEqual(decoded.height, 256)
        XCTAssertFalse(ThumbnailGenerator.isWebP(Data("RIFF0000WAVE".utf8)))
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T {
        try XCTUnwrap(value)
    }

    private static func destination(bucket: String) -> DestinationConfig {
        DestinationConfig(
            name: bucket, preset: .customS3, accountID: nil, endpoint: "https://s3.example.com", region: "auto",
            bucket: bucket, publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}",
            forcePathStyle: true, isDefault: false
        )
    }
}
