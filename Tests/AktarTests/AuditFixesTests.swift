import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Output escaping, key rules, pause limits, webhook addresses, public
/// links, active content, metadata removal and transfer link expiry.
final class AuditFixesTests: XCTestCase {
    private let url = URL(string: "https://img.example.com/a/report.pdf?X-Amz-Signature=1&X-Amz-Expires=60")!

    // MARK: - Output

    func testHTMLOutputEscapesTheFilename() {
        let output = OutputFormatter.format(publicURL: url, mode: .html, filename: "<script>alert('x')</script> & \"q\".pdf")
        XCTAssertEqual(output, "<a href=\"\(url.absoluteString)\">&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;q&quot;.pdf</a>")
    }

    func testMarkdownOutputEscapesTheLinkText() {
        let output = OutputFormatter.format(publicURL: url, mode: .markdown, filename: "a](https://evil.example)[b\\.pdf")
        XCTAssertEqual(output, "[a\\]\\(https://evil.example\\)\\[b\\\\.pdf](\(url.absoluteString))")
        XCTAssertEqual(OutputFormatter.format(publicURL: url, mode: .markdown, filename: "plain.pdf"), "[plain.pdf](\(url.absoluteString))")
    }

    func testCustomTemplatesAreNotEscaped() {
        let output = OutputFormatter.format(publicURL: url, mode: .custom, filename: "<b>.pdf", customTemplate: "{filename} {url}")
        XCTAssertEqual(output, "<b>.pdf \(url.absoluteString)")
    }

    // MARK: - Keys

    func testGeneratedKeysSanitizeTheFilename() {
        let key = ObjectKeyGenerator.generate(template: "up/{filename}.{ext}", originalFilename: "../../etc\\pa\u{0}ss\nwd.png")
        XCTAssertEqual(key, "up/....etcpasswd.png")
        XCTAssertEqual(ObjectKeyGenerator.generate(template: "up/{filename}", originalFilename: ".."), "up/file")
        XCTAssertEqual(ObjectKeyGenerator.generate(template: "{filename}.{ext}", originalFilename: "\u{1}.png"), "file.png")
        XCTAssertEqual(ObjectKeyGenerator.sanitizedFilename(".."), "file")
        XCTAssertEqual(ObjectKeyGenerator.sanitizedFilename(""), "file")
        // Emoji joiners aren't control characters.
        XCTAssertEqual(ObjectKeyGenerator.sanitizedFilename("👩\u{200D}💻 notes"), "👩\u{200D}💻 notes")
    }

    func testUniqueTokens() {
        XCTAssertTrue(ObjectKeyGenerator.hasUniqueToken("{year}/{uuid}.{ext}"))
        XCTAssertTrue(ObjectKeyGenerator.hasUniqueToken("{random}-{filename}"))
        XCTAssertTrue(ObjectKeyGenerator.hasUniqueToken("{sha256}.{ext}"))
        XCTAssertFalse(ObjectKeyGenerator.hasUniqueToken("{folder}/{subpath}/{year}/{month}/{filename}.{ext}"))
    }

    func testUserKeyRules() {
        XCTAssertNil(ObjectKeyGenerator.problem(withUserKey: "a/b/c.png"))
        XCTAssertNil(ObjectKeyGenerator.problem(withUserKey: "folder/", allowsTrailingSlash: true))
        XCTAssertNil(ObjectKeyGenerator.problem(withUserKey: "v1.2/..hidden"))
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "/a.png"), .leadingSlash)
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "a/../b.png"), .dotSegment)
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "./b.png"), .dotSegment)
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "a//b.png"), .emptySegment)
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "folder/"), .emptySegment)
        XCTAssertEqual(ObjectKeyGenerator.problem(withUserKey: "a\u{7}b"), .controlCharacter)
    }

    // MARK: - Pausing

    func testPauseMinutesFromLinks() {
        XCTAssertEqual(WatchPause.minutes(fromQuery: "60"), 60)
        XCTAssertEqual(WatchPause.minutes(fromQuery: "525601"), WatchPause.maxMinutes)
        XCTAssertEqual(WatchPause.minutes(fromQuery: "99999999999999999999999999"), WatchPause.maxMinutes)
        XCTAssertNil(WatchPause.minutes(fromQuery: "0"))
        XCTAssertNil(WatchPause.minutes(fromQuery: "-5"))
        XCTAssertNil(WatchPause.minutes(fromQuery: "1.5"))
        XCTAssertNil(WatchPause.minutes(fromQuery: "abc"))
        XCTAssertNil(WatchPause.minutes(fromQuery: ""))
        XCTAssertNil(WatchPause.minutes(fromQuery: nil))
    }

    func testPauseArithmeticCantOverflow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(WatchPause.end(minutes: Int.max, from: now), now.addingTimeInterval(525_600 * 60))
        XCTAssertEqual(WatchPause.clampedMinutes(-1), nil)
        XCTAssertEqual(WatchPause.wait(until: .distantFuture, from: now), WatchPause.maxWait + 0.5)
        XCTAssertEqual(WatchPause.wait(until: .distantPast, from: now), 0.5)
        XCTAssertEqual(WatchPause.wait(until: now.addingTimeInterval(90), from: now), 90.5)
        // Sleeping that long is fine.
        _ = Duration.seconds(WatchPause.wait(until: .distantFuture, from: now))
    }

    // MARK: - Webhooks

    func testWebhookAddresses() {
        XCTAssertEqual(WatchHookAddress.check("https://hooks.example.com/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://hooks.example.com/x"), .insecure)
        XCTAssertEqual(WatchHookAddress.check("http://localhost:8080/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://127.0.0.1/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://192.168.1.20/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://10.0.0.5/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://172.20.1.1/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://172.32.1.1/x"), .insecure)
        XCTAssertEqual(WatchHookAddress.check("http://nas.local/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://[::1]:9000/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://[fd12::1]/x"), .allowed)
        XCTAssertEqual(WatchHookAddress.check("http://[2001:db8::1]/x"), .insecure)
        XCTAssertEqual(WatchHookAddress.check("http://8.8.8.8/x"), .insecure)
        XCTAssertEqual(WatchHookAddress.check("ftp://example.com"), .invalid)
        XCTAssertEqual(WatchHookAddress.check("not a url"), .invalid)
    }

    func testWebhookRedirects() {
        let hook = URL(string: "https://hooks.example.com/a")!
        XCTAssertTrue(WatchHookAddress.mayFollowRedirect(from: hook, to: URL(string: "https://hooks.example.com/b")!))
        XCTAssertFalse(WatchHookAddress.mayFollowRedirect(from: hook, to: URL(string: "https://other.example.com/b")!))
        XCTAssertFalse(WatchHookAddress.mayFollowRedirect(from: hook, to: URL(string: "http://hooks.example.com/b")!))
        XCTAssertFalse(WatchHookAddress.mayFollowRedirect(from: hook, to: URL(string: "https://hooks.example.com:8443/b")!))
    }

    // MARK: - Public links

    func testPublicBaseURLValidation() {
        XCTAssertTrue(PublicURLResolver.isValidBaseURL("img.example.com"))
        XCTAssertTrue(PublicURLResolver.isValidBaseURL("https://img.example.com/sub/"))
        XCTAssertTrue(PublicURLResolver.isValidBaseURL("http://192.168.1.10:9000/uploads"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL(""))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("exa mple.com"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("ftp://img.example.com"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("https://"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("https://img.example.com:99999"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("https://img.example.com:0"))
        XCTAssertFalse(PublicURLResolver.isValidBaseURL("https://img.example.com:abc"))
        XCTAssertNil(PublicURLResolver.resolve(baseURL: "exa mple.com", objectKey: "a.png"))
        XCTAssertEqual(PublicURLResolver.resolve(baseURL: "img.example.com/", objectKey: "a b/c.png")?.absoluteString, "https://img.example.com/a%20b/c.png")
    }

    // MARK: - Active content

    func testActiveContentIsDownloadedNotShown() {
        XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["page.HTML"], contentType: "application/octet-stream"), "attachment")
        XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["2026/x.svg"], contentType: "image/svg+xml"), "attachment")
        XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["noext"], contentType: "text/html; charset=utf-8"), "attachment")
        XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["key", "app.mjs"], contentType: "application/octet-stream"), "attachment")
        for ext in ["htm", "xhtml", "xht", "svgz", "xml", "js"] {
            XCTAssertTrue(ContentTypeResolver.isActiveContent(names: ["f." + ext], contentType: ""), ext)
        }
        XCTAssertNil(ContentTypeResolver.contentDisposition(names: ["photo.png"], contentType: "image/png"))
        XCTAssertNil(ContentTypeResolver.contentDisposition(names: ["notes.txt"], contentType: "text/plain"))
    }

    // MARK: - Metadata in WebP, GIF and PNG

    func testWebPMetadataChunksAreRemoved() throws {
        let vp8x = chunk("VP8X", [0x08 | 0x04 | 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let webp = riff([vp8x, chunk("ICCP", [1, 2, 3]), chunk("VP8L", [9, 9, 9, 9, 9]), chunk("EXIF", [1, 2, 3, 4]), chunk("XMP ", Array("<x>exif:GPSLatitude</x>".utf8))])

        let all = try XCTUnwrap(ContainerMetadata.webp(webp, policy: .removeAll, exifHasLocation: false))
        let bytes = [UInt8](all)
        XCTAssertEqual(Array(bytes[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24, bytes.count - 8)
        XCTAssertEqual(bytes[20], 0x20, "EXIF and XMP flags cleared, ICC kept")
        XCTAssertFalse(String(decoding: all, as: UTF8.self).contains("EXIF"))
        XCTAssertFalse(String(decoding: all, as: UTF8.self).contains("GPS"))
        XCTAssertTrue(String(decoding: all, as: UTF8.self).contains("ICCP"))
        XCTAssertNil(try ContainerMetadata.webp(all, policy: .removeAll, exifHasLocation: true))

        // The XMP has a location, so "Remove location" drops it too.
        XCTAssertNotNil(try ContainerMetadata.webp(webp, policy: .removeLocation, exifHasLocation: false))
        let noLocation = riff([vp8x, chunk("VP8L", [9]), chunk("XMP ", Array("<x>Creator</x>".utf8))])
        XCTAssertNil(try ContainerMetadata.webp(noLocation, policy: .removeLocation, exifHasLocation: false))
        XCTAssertNotNil(try ContainerMetadata.webp(noLocation, policy: .removeLocation, exifHasLocation: true))
        XCTAssertNil(try ContainerMetadata.webp(webp, policy: .keepAll, exifHasLocation: true))
        XCTAssertThrowsError(try ContainerMetadata.webp(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8X\u{FF}".utf8), policy: .removeAll, exifHasLocation: false))
    }

    func testGIFMetadataBlocksAreRemoved() throws {
        var gif: [UInt8] = Array("GIF89a".utf8) + [1, 0, 1, 0, 0x80, 0, 0] + [0, 0, 0, 255, 255, 255]
        let loop: [UInt8] = [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]
        let xmpData = Array("<x>exif:GPSLatitude=1</x>".utf8)
        let xmp: [UInt8] = [0x21, 0xFF, 11] + Array("XMP DataXMP".utf8) + [UInt8(xmpData.count)] + xmpData + [0]
        let comment: [UInt8] = [0x21, 0xFE, 5] + Array("hello".utf8) + [0]
        let image: [UInt8] = [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0]
        gif += loop + xmp + comment + image + [0x3B]

        let all = try XCTUnwrap(ContainerMetadata.gif(Data(gif), policy: .removeAll))
        XCTAssertEqual([UInt8](all), Array(gif[0..<19]) + loop + image + [0x3B])
        let location = try XCTUnwrap(ContainerMetadata.gif(Data(gif), policy: .removeLocation))
        XCTAssertEqual([UInt8](location), Array(gif[0..<19]) + loop + comment + image + [0x3B])
        XCTAssertNil(try ContainerMetadata.gif(all, policy: .removeAll))
        XCTAssertThrowsError(try ContainerMetadata.gif(Data(gif.dropLast(3)), policy: .removeAll))
    }

    func testPNGTextChunksAreRemovedUnderRemoveAll() throws {
        let original = try png()
        var bytes = [UInt8](original)
        // A tEXt chunk right after IHDR (8 + 25 bytes in).
        let text = pngChunk("tEXt", Array("Author\u{0}Someone".utf8))
        bytes.insert(contentsOf: text, at: 33)
        let withText = Data(bytes)

        let cleaned = try XCTUnwrap(ContainerMetadata.png(withText, policy: .removeAll))
        XCTAssertEqual(cleaned, original)
        XCTAssertNil(try ContainerMetadata.png(withText, policy: .removeLocation))
        XCTAssertNil(try ContainerMetadata.png(original, policy: .removeAll))

        // Through the stripper, the copy has no text left and still opens.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try withText.write(to: url)
        let copy = try XCTUnwrap(ImageMetadataStripper.strippedCopy(of: url, policy: .removeAll))
        defer { ImageMetadataStripper.removeCopy(copy) }
        XCTAssertFalse(String(decoding: try Data(contentsOf: copy), as: UTF8.self).contains("Someone"))
        XCTAssertNotNil(CGImageSourceCreateWithURL(copy as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    }

    func testVideosAreRecognizedByExtension() {
        XCTAssertTrue(VideoMetadataStripper.isVideo(URL(fileURLWithPath: "/tmp/a.MOV")))
        XCTAssertTrue(VideoMetadataStripper.isVideo(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertTrue(VideoMetadataStripper.isVideo(URL(fileURLWithPath: "/tmp/a.m4v")))
        XCTAssertFalse(VideoMetadataStripper.isVideo(URL(fileURLWithPath: "/tmp/a.png")))
    }

    // MARK: - Transfer link expiry

    func testTransferLinksExpire() throws {
        let payload = try DestinationTransfer.decodePayload(JSONSerialization.data(withJSONObject: [
            "v": 1,
            "destination": ["id": UUID().uuidString, "name": "A", "preset": "customS3", "endpoint": "e", "bucket": "b", "publicBaseURL": "https://p.example.com"],
            "credentials": ["accessKeyId": "a", "secretAccessKey": "s"],
        ]))
        XCTAssertNil(payload.expiresAt)
        let code = DestinationTransfer.generateCode()
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let link = try DestinationTransfer.seal(payload, code: code, now: made)

        let opened = try DestinationTransfer.open(link, code: code, now: made.addingTimeInterval(60))
        XCTAssertEqual(opened.expiresAt, 1_800_003_600)
        // Five minutes of leeway for a clock that's off.
        XCTAssertNoThrow(try DestinationTransfer.open(link, code: code, now: made.addingTimeInterval(3600 + 300)))
        XCTAssertThrowsError(try DestinationTransfer.open(link, code: code, now: made.addingTimeInterval(3600 + 301))) { error in
            XCTAssertEqual(error as? DestinationTransferError, .expired)
        }
        let data = try DestinationTransfer.encodePayload(opened)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["expiresAt"] as? Int, 1_800_003_600)
    }

    func testTransferNeedsAUsablePublicBaseURL() {
        let object: [String: Any] = [
            "v": 1,
            "destination": ["id": UUID().uuidString, "name": "A", "preset": "customS3", "endpoint": "e", "bucket": "b", "publicBaseURL": "https://bad host"],
            "credentials": ["accessKeyId": "a", "secretAccessKey": "s"],
        ]
        XCTAssertThrowsError(try DestinationTransfer.decodePayload(JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? DestinationTransferError, .notAktarTransfer)
        }
    }

    // MARK: - Helpers

    private func chunk(_ fourCC: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count)
        var bytes = Array(fourCC.utf8) + [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)] + payload
        if payload.count % 2 == 1 { bytes.append(0) }
        return bytes
    }

    private func riff(_ chunks: [[UInt8]]) -> Data {
        let body = Array("WEBP".utf8) + chunks.flatMap { $0 }
        let size = UInt32(body.count)
        return Data(Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)] + body)
    }

    private func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        // The CRC isn't checked when chunks are dropped.
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
            + Array(type.utf8) + payload + [0, 0, 0, 0]
    }

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
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
