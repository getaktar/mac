import CryptoKit
import XCTest

/// The steps every upload goes through before and after the bytes are
/// sent: the object key from the path template, content hashes, the
/// content type, expiring keys, the public link and what's copied, and
/// folders (as a ZIP or with their structure).
final class UploadPipelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UploadPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Object keys

    func testDateAndNameTokens() throws {
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9, minute: 5, second: 4)))
        let key = ObjectKeyGenerator.generate(
            template: "{year}/{month}/{day}/{date}_{time}/{filename}.{ext}",
            originalFilename: "Screen Shot.png",
            date: date
        )
        XCTAssertEqual(key, "2026/03/07/2026-03-07_090504/Screen Shot.png")
    }

    func testTheDefaultTemplateUsesTheShortCode() throws {
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let key = ObjectKeyGenerator.generate(
            template: DestinationConfig.defaultObjectPathTemplate,
            originalFilename: "photo.jpeg",
            date: date,
            shortCode: { "Ab3dE7x" }
        )
        XCTAssertEqual(key, "2026/10/Ab3dE7x.jpeg")
        XCTAssertEqual(ObjectKeyGenerator.generate(template: DestinationConfig.cleanURLTemplate, originalFilename: "a.pdf", shortCode: { "XyZ1234" }), "XyZ1234.pdf")
    }

    func testShortCodeIsOnlyDrawnWhenUsed() {
        var drawn = 0
        _ = ObjectKeyGenerator.generate(template: "{filename}.{ext}", originalFilename: "a.png", shortCode: { drawn += 1; return "x" })
        XCTAssertEqual(drawn, 0)
        _ = ObjectKeyGenerator.generate(template: "{short}.{ext}", originalFilename: "a.png", shortCode: { drawn += 1; return "x" })
        XCTAssertEqual(drawn, 1)
    }

    func testRandomTokens() {
        let key = ObjectKeyGenerator.generate(template: "{uuid}|{random}", originalFilename: "a.png")
        let parts = key.split(separator: "|").map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotNil(UUID(uuidString: parts[0]))
        XCTAssertEqual(parts[0], parts[0].lowercased())
        XCTAssertEqual(parts[1].count, 8)
        XCTAssertEqual(parts[1], parts[1].lowercased())
        XCTAssertNotEqual(key, ObjectKeyGenerator.generate(template: "{uuid}|{random}", originalFilename: "a.png"))
    }

    func testHashTokensAndWhenTheyreNeeded() {
        let hashes = ContentHashes(md5: "900150983cd24fb0d6963f7d28e17f72", sha256: "ba78")
        XCTAssertEqual(
            ObjectKeyGenerator.generate(template: "{md5}/{sha256}.{ext}", originalFilename: "a.txt", hashes: hashes),
            "900150983cd24fb0d6963f7d28e17f72/ba78.txt"
        )
        // Not computed: the segment collapses.
        XCTAssertEqual(ObjectKeyGenerator.generate(template: "x/{md5}/{filename}.{ext}", originalFilename: "a.txt"), "x/a.txt")

        XCTAssertTrue(ObjectKeyGenerator.usesMD5("{md5}.{ext}"))
        XCTAssertFalse(ObjectKeyGenerator.usesMD5("{sha256}.{ext}"))
        XCTAssertTrue(ObjectKeyGenerator.usesSHA256("{year}/{sha256}"))
        XCTAssertFalse(ObjectKeyGenerator.usesSHA256("{uuid}"))
    }

    func testWatchedFolderTokensAndEmptySegments() {
        XCTAssertEqual(
            ObjectKeyGenerator.generate(template: "{folder}/{subpath}/{filename}.{ext}", originalFilename: "a.png", folder: "Shots/2026", subpath: "x/y"),
            "Shots-2026/x/y/a.png"
        )
        // Outside a watched folder both are empty, and so is their path.
        XCTAssertEqual(ObjectKeyGenerator.generate(template: "/{folder}/{subpath}/{filename}.{ext}", originalFilename: "a.png"), "a.png")
    }

    func testAFileWithoutAnExtension() {
        XCTAssertEqual(ObjectKeyGenerator.generate(template: "{filename}", originalFilename: "Makefile"), "Makefile")
    }

    // MARK: - Content hashes

    func testHashesOfAKnownInput() throws {
        let url = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try ContentHasher.hashes(of: url, md5: true, sha256: true), ContentHashes(
            md5: "900150983cd24fb0d6963f7d28e17f72",
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ))
        XCTAssertEqual(try ContentHasher.hashes(of: url, md5: false, sha256: true).md5, nil)
        XCTAssertEqual(try ContentHasher.hashes(of: url, md5: true, sha256: false).sha256, nil)
        // Nothing asked for: the file isn't even opened.
        XCTAssertEqual(try ContentHasher.hashes(of: url.appendingPathExtension("missing"), md5: false, sha256: false), ContentHashes())
    }

    func testHashesAcrossChunks() throws {
        // A little over 2 MiB, so the 1 MiB chunks add up.
        let data = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = directory.appendingPathComponent("big.bin")
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ContentHasher.hashes(of: url, md5: false, sha256: true).sha256, expected)
    }

    // MARK: - Content types

    func testContentTypes() {
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/b.png")), "image/png")
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/b.JPG")), "image/jpeg")
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/b.pdf")), "application/pdf")
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/b.zip")), "application/zip")
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/b.unknownext")), "application/octet-stream")
        XCTAssertEqual(ContentTypeResolver.resolve(for: URL(fileURLWithPath: "/a/noext")), "application/octet-stream")
    }

    // MARK: - Expiring uploads

    func testExpiringKeysAndPrefixes() {
        // Shared with the Windows and mobile apps: these strings can't change.
        XCTAssertEqual(UploadExpiry.options, [1, 7, 14, 30])
        XCTAssertEqual(UploadExpiry.prefix(days: 7), "tmp/7d/")
        XCTAssertEqual(UploadExpiry.ruleID(days: 14), "aktar-expire-14d")

        XCTAssertEqual(UploadExpiry.key("2026/a.png", days: 1), "tmp/1d/2026/a.png")
        XCTAssertEqual(UploadExpiry.key("2026/a.png", days: nil), "2026/a.png")
        XCTAssertEqual(UploadExpiry.days(forKey: "tmp/30d/a.png"), 30)
        XCTAssertNil(UploadExpiry.days(forKey: "tmp/2d/a.png"))
        XCTAssertNil(UploadExpiry.days(forKey: "a/tmp/7d/a.png"))
        XCTAssertNil(UploadExpiry.days(forKey: "tmp/7da.png"))
    }

    func testExpiryValidation() {
        for days in [0, 1, 7, 14, 30] { XCTAssertTrue(UploadExpiry.isValid(days), "\(days)") }
        for days in [-1, 2, 3, 31, 365] { XCTAssertFalse(UploadExpiry.isValid(days), "\(days)") }
    }

    func testDeletionLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UploadExpiry.deletionLabel(for: now.addingTimeInterval(-1), now: now), String(localized: "Expired"))
        XCTAssertEqual(UploadExpiry.deletionLabel(for: now, now: now), String(localized: "Expired"))
        XCTAssertNotEqual(UploadExpiry.deletionLabel(for: now.addingTimeInterval(86_400), now: now), String(localized: "Expired"))
    }

    // MARK: - Temporary links

    func testTemporaryLinkDurationsAreSeconds() throws {
        // Written as numbers into the transfer format and the destinations
        // file, the same on every platform.
        XCTAssertEqual(TemporaryLinkDuration.allCases.map(\.rawValue), [300, 900, 3600, 86_400, 604_800])
        // Seven days is the longest an S3 presigned URL can last.
        XCTAssertEqual(TemporaryLinkDuration.allCases.map(\.rawValue).max(), 7 * 86_400)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(TemporaryLinkDuration.day), as: UTF8.self), "86400")
    }

    // MARK: - Public links

    func testPublicLinksEncodeTheKey() {
        XCTAssertEqual(
            PublicURLResolver.resolve(baseURL: "https://img.example.com/", objectKey: "2026/a b/ç.png")?.absoluteString,
            "https://img.example.com/2026/a%20b/%C3%A7.png"
        )
        XCTAssertEqual(
            PublicURLResolver.resolve(baseURL: "img.example.com/files", objectKey: "a.png")?.absoluteString,
            "https://img.example.com/files/a.png"
        )
        XCTAssertEqual(
            PublicURLResolver.resolve(baseURL: "http://localhost:9000/bucket", objectKey: "a?b#c.png")?.absoluteString,
            "http://localhost:9000/bucket/a%3Fb%23c.png"
        )
        XCTAssertNil(PublicURLResolver.resolve(baseURL: "", objectKey: "a.png"))
        XCTAssertNil(PublicURLResolver.resolve(baseURL: "ftp://example.com", objectKey: "a.png"))
    }

    // MARK: - What's copied

    private let link = URL(string: "https://img.example.com/2026/a.png")!
    private let pdfLink = URL(string: "https://img.example.com/2026/report.pdf")!

    func testImagesAreEmbeddedAndOtherFilesLinked() {
        XCTAssertEqual(OutputFormatter.format(publicURL: link, mode: .url, filename: "a.png"), link.absoluteString)
        XCTAssertEqual(OutputFormatter.format(publicURL: link, mode: .markdown, filename: "a.png"), "![](\(link.absoluteString))")
        XCTAssertEqual(OutputFormatter.format(publicURL: link, mode: .html, filename: "a.png"), "<img src=\"\(link.absoluteString)\" alt=\"\">")
        XCTAssertEqual(OutputFormatter.format(publicURL: pdfLink, mode: .markdown, filename: "report.pdf"), "[report.pdf](\(pdfLink.absoluteString))")
        XCTAssertEqual(OutputFormatter.format(publicURL: pdfLink, mode: .html, filename: "report.pdf"), "<a href=\"\(pdfLink.absoluteString)\">report.pdf</a>")
        // No extension: a link, not a broken image.
        XCTAssertEqual(OutputFormatter.format(publicURL: pdfLink, mode: .markdown, filename: "README"), "[README](\(pdfLink.absoluteString))")
    }

    func testShortLinksReplaceTheLink() {
        let short = URL(string: "https://s.example/x")!
        XCTAssertEqual(OutputFormatter.format(publicURL: link, shortURL: short, mode: .url, filename: "a.png"), short.absoluteString)
        XCTAssertEqual(OutputFormatter.format(publicURL: link, shortURL: short, mode: .markdown, filename: "a.png"), "![](\(short.absoluteString))")
        XCTAssertEqual(
            OutputFormatter.format(publicURL: link, shortURL: short, mode: .custom, filename: "a.png", customTemplate: "{url} {shortUrl} {longUrl}"),
            "\(short.absoluteString) \(short.absoluteString) \(link.absoluteString)"
        )
        // Without a short link, {shortUrl} is the long one.
        XCTAssertEqual(
            OutputFormatter.format(publicURL: link, mode: .custom, filename: "a.png", customTemplate: "{shortUrl}"),
            link.absoluteString
        )
    }

    func testCustomTemplateTokens() {
        XCTAssertEqual(
            OutputFormatter.format(publicURL: link, mode: .custom, filename: "my.photo.png", customTemplate: "{name}|{ext}|{filename}"),
            "my.photo|png|my.photo.png"
        )
        // The default custom template.
        XCTAssertEqual(OutputFormatter.format(publicURL: link, mode: .custom, filename: "a.png"), "![a.png](\(link.absoluteString))")
    }

    func testBatchesAreOnePerLine() {
        let output = OutputFormatter.formatBatch(entries: [(link, "a.png"), (pdfLink, "report.pdf")], mode: .markdown)
        XCTAssertEqual(output, "![](\(link.absoluteString))\n[report.pdf](\(pdfLink.absoluteString))")
        XCTAssertEqual(OutputFormatter.formatBatch(entries: [], mode: .url), "")
    }

    // MARK: - Folders

    func testFolderFilesSkipHiddenOnesAndAreSorted() throws {
        let folder = try makeFolder("Site", files: ["index.html", "css/site.css", "img/b 10.png", "img/b 2.png", ".env", ".git/config", "css/.DS_Store"])
        let entries = try FolderUpload.files(in: folder)
        XCTAssertEqual(entries.map(\.relativePath), ["css/site.css", "img/b 2.png", "img/b 10.png", "index.html"])
        XCTAssertTrue(FolderUpload.isFolder(folder))
        XCTAssertFalse(FolderUpload.isFolder(entries[0].fileURL))
    }

    func testEmptyAndOversizedFolders() throws {
        let empty = try makeFolder("Empty", files: [".hidden"])
        XCTAssertThrowsError(try FolderUpload.files(in: empty)) { error in
            guard case FolderUploadError.empty("Empty") = error else { return XCTFail("\(error)") }
        }
        let big = try makeFolder("Big", files: ["1", "2", "3"])
        XCTAssertThrowsError(try FolderUpload.files(in: big, limit: 2)) { error in
            guard case FolderUploadError.tooManyFiles("Big", 2) = error else { return XCTFail("\(error)") }
        }
        // As a ZIP there's no limit.
        XCTAssertEqual(try FolderUpload.files(in: big, limit: nil).count, 3)
    }

    func testFolderKeyPrefix() throws {
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 1)))
        XCTAssertEqual(FolderUpload.keyPrefix(template: "{filename}.{ext}", folderName: "Project", date: date), "Project/")
        XCTAssertEqual(FolderUpload.keyPrefix(template: "uploads/{filename}.{ext}", folderName: "Project", date: date), "uploads/Project/")
        XCTAssertEqual(FolderUpload.keyPrefix(template: "{year}/{month}/{filename}", folderName: "Project", date: date), "2026/09/Project/")

        let unique = FolderUpload.keyPrefix(template: "{year}/{month}/{uuid}.{ext}", folderName: "Project", date: date)
        XCTAssertTrue(unique.hasPrefix("2026/09/"))
        XCTAssertTrue(unique.hasSuffix("/Project/"), "the folder's name still shows in every link")
        XCTAssertNotEqual(unique, FolderUpload.keyPrefix(template: "{year}/{month}/{uuid}.{ext}", folderName: "Project", date: date))
        // Nothing left of the template.
        XCTAssertEqual(FolderUpload.keyPrefix(template: "{md5}.{ext}", folderName: "Project", date: date), "Project/")
    }

    func testZipLeavesHiddenFilesOut() async throws {
        let folder = try makeFolder("Site", files: ["index.html", "css/site.css", ".env", ".git/config"])
        let zip = try await FolderUpload.zip(folder, imageMetadata: .removeLocation)
        defer { FolderUpload.removeZip(zip) }
        XCTAssertEqual(zip.lastPathComponent, "Site.zip")

        let names = try Self.zipEntries(zip).filter { !$0.hasSuffix("/") }.sorted()
        XCTAssertEqual(names, ["Site/css/site.css", "Site/index.html"])

        FolderUpload.removeZip(zip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.deletingLastPathComponent().path))
    }

    // MARK: - Image processing settings

    func testImageProcessingDecodesLeniently() throws {
        let json = #"{"format":"jpegxl","quality":"high","maxLongEdge":1920}"#
        let settings = try JSONDecoder().decode(ImageProcessing.self, from: Data(json.utf8))
        XCTAssertEqual(settings, ImageProcessing(format: .original, quality: nil, maxLongEdge: 1920))
        XCTAssertFalse(settings.isOff)
        XCTAssertTrue(try JSONDecoder().decode(ImageProcessing.self, from: Data("{}".utf8)).isOff)

        let webp = try JSONDecoder().decode(ImageProcessing.self, from: Data(#"{"format":"webp","quality":80}"#.utf8))
        XCTAssertEqual(webp, ImageProcessing(format: .webp, quality: 80))
    }

    func testImageProcessingLabels() {
        XCTAssertEqual(ImageProcessing.qualityLabel(nil), String(localized: "Off"))
        XCTAssertEqual(ImageProcessing.qualityLabel(73), "73%")
        XCTAssertEqual(ImageProcessing.sizeLabel(nil), String(localized: "Off"))
        for quality in ImageProcessing.qualityOptions {
            XCTAssertNotEqual(ImageProcessing.qualityLabel(quality), "\(quality)%", "every offered quality has its own label")
        }
    }

    // MARK: - Helpers

    private func makeFolder(_ name: String, files: [String]) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        for file in files {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func zipEntries(_ zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
