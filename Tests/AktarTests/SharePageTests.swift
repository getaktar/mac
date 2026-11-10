import XCTest

/// Filling docs/share-page/template.html as reference.mjs does: escaping,
/// the head tags and the page data for each kind, and the keys and checks
/// around pages (docs/share-pages.md).
final class SharePageTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_793_088_000) // 2026-10-27T08:00:00Z
    private var template: String!

    override func setUpWithError() throws {
        template = try XCTUnwrap(SharePages.bundledTemplate(), "the template is bundled")
    }

    // MARK: - The bundled template

    func testBundledTemplateIsTheDocsFile() throws {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/share-page/template.html")
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "template", withExtension: "html"))
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: docs))
        for placeholder in ["{{LANG}}", "{{TITLE}}", "{{META}}", "{{DATA}}"] {
            XCTAssertEqual(template.components(separatedBy: placeholder).count, 2, placeholder)
        }
    }

    // MARK: - Escaping

    func testEscapingMatchesTheReference() {
        XCTAssertEqual(SharePages.escapeHTML(#"<a href="x">{{DATA}}</a> & 'q'"#), "&lt;a href=&quot;x&quot;&gt;&#123;&#123;DATA&#125;&#125;&lt;/a&gt; &amp; &#39;q&#39;")
        XCTAssertEqual(SharePages.escapeJSON(#"{"a":"</script><!--&\#u{2028}\#u{2029}"}"#), #"{"a":"\u003c/script\u003e\u003c!--\u0026\u2028\u2029"}"#)
    }

    func testJSONIsWrittenLikeJavaScript() {
        let json = JSJSON.object([
            ("s", .string("a\"b\\c\n\t\u{01}/é😀")),
            ("n", .int(-5)),
            ("b", .bool(true)),
            ("z", .null),
            ("a", .array([.int(1), .string("x")])),
        ]).serialized
        XCTAssertEqual(json, #"{"s":"a\"b\\c\n\t\u0001/é😀","n":-5,"b":true,"z":null,"a":[1,"x"]}"#)
    }

    func testFormatSize() {
        XCTAssertEqual(SharePages.formatSize(0), "0 B")
        XCTAssertEqual(SharePages.formatSize(999), "999 B")
        XCTAssertEqual(SharePages.formatSize(1000), "1.0 KB")
        XCTAssertEqual(SharePages.formatSize(2_400_000), "2.4 MB")
        XCTAssertEqual(SharePages.formatSize(512_000), "512 KB")
        XCTAssertEqual(SharePages.formatSize(1250), "1.3 KB", "halves round up, as toFixed does")
        XCTAssertEqual(SharePages.formatSize(99_950), "100.0 KB")
        XCTAssertEqual(SharePages.formatSize(4_100_000_000), "4.1 GB")
        XCTAssertEqual(SharePages.formatSize(3_000_000_000_000_000), "3000 TB")
    }

    func testExcerpt() {
        XCTAssertEqual(SharePages.excerpt("  a\n\n b  "), "a b")
        XCTAssertEqual(SharePages.excerpt("x\u{00A0}\u{3000}y"), "x y")
        let long = SharePages.excerpt(String(repeating: "x", count: 300))
        XCTAssertEqual(long.unicodeScalars.count, 200)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
        XCTAssertEqual(SharePages.excerpt(String(repeating: "😀", count: 200)).unicodeScalars.count, 200, "code points, not UTF-16")
    }

    // MARK: - Filling

    func testFilePageFromTheReferenceTest() {
        let page = SharePage(kind: .file, lang: "tr", created: created, files: [
            .init(name: "</script><script>alert(1)</script>{{META}}.png", url: "https://cdn.example.com/a.png", size: 2_400_000, type: "image/png", ogImage: "https://cdn.example.com/a.png"),
        ])
        let html = SharePages.build(page, template: template)
        let withoutData = html.replacingOccurrences(of: #"<script id="aktar-data"[^>]*>[\s\S]*?</script>"#, with: "", options: .regularExpression)
        XCTAssertFalse(withoutData.contains("{{"), "no placeholder left outside the data")
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2, "only the two script elements end")
        XCTAssertTrue(html.contains(#"<meta property="og:image" content="https://cdn.example.com/a.png">"#))
        XCTAssertTrue(html.contains(#"<meta name="twitter:card" content="summary_large_image">"#))
        XCTAssertTrue(html.contains(#"content="2.4 MB · PNG""#))
        XCTAssertTrue(html.contains(#"<html lang="tr">"#))
        XCTAssertTrue(html.contains("<title>&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;&#123;&#123;META&#125;&#125;.png</title>"))
    }

    func testReplacementPatternsInNamesStayLiteral() {
        // JavaScript's String.replace reads "$&" in a replacement string as
        // the match; the name must come out as it is.
        let page = SharePage(kind: .file, lang: "en", created: created, files: [.init(name: "a$&b$'c.txt", url: "https://x.example/a", size: 1, type: "text/plain")])
        let html = SharePages.build(page, template: template)
        XCTAssertTrue(html.contains("<title>a$&amp;b$&#39;c.txt</title>"))
    }

    func testFileDataAndHead() {
        let page = SharePage(kind: .file, lang: "en", created: created, expires: created.addingTimeInterval(86_400), files: [
            .init(name: "clip.mp4", url: "https://cdn.example.com/clip.mp4", size: 12_345_678, type: "video/mp4", thumb: "https://cdn.example.com/.aktar/thumbnails/clip.mp4.webp", ogImage: "https://cdn.example.com/.aktar/thumbnails/clip.mp4.webp"),
        ])
        XCTAssertEqual(SharePages.dataJSON(page), #"{"v":1,"kind":"file","lang":"en","created":"2026-10-27T08:00:00Z","expires":"2026-10-28T08:00:00Z","files":[{"name":"clip.mp4","url":"https://cdn.example.com/clip.mp4","size":12345678,"type":"video/mp4","thumb":"https://cdn.example.com/.aktar/thumbnails/clip.mp4.webp"}]}"#)
        let head = SharePages.head(for: page)
        XCTAssertEqual(head.title, "clip.mp4")
        XCTAssertEqual(head.meta, """
        <meta name="description" content="12.3 MB · MP4">
        <meta property="og:title" content="clip.mp4">
        <meta property="og:description" content="12.3 MB · MP4">
        <meta property="og:type" content="video.other">
        <meta property="og:image" content="https://cdn.example.com/.aktar/thumbnails/clip.mp4.webp">
        <meta property="og:image:alt" content="clip.mp4">
        <meta property="og:video" content="https://cdn.example.com/clip.mp4">
        <meta property="og:video:secure_url" content="https://cdn.example.com/clip.mp4">
        <meta property="og:video:type" content="video/mp4">
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="clip.mp4">
        """)
    }

    func testTextPage() {
        let text = "import Foundation\n\nfunc greet() {}\n"
        let page = SharePage(kind: .text, lang: "en", created: created, files: [.init(name: "greet.swift", url: "https://x.example/greet.swift", size: 35, type: "text/x-swift")], text: text, syntax: "swift")
        XCTAssertEqual(SharePages.dataJSON(page), #"{"v":1,"kind":"text","lang":"en","created":"2026-10-27T08:00:00Z","expires":null,"files":[{"name":"greet.swift","url":"https://x.example/greet.swift","size":35,"type":"text/x-swift","thumb":null}],"text":"import Foundation\n\nfunc greet() {}\n","syntax":"swift"}"#)
        let head = SharePages.head(for: page)
        XCTAssertTrue(head.meta.hasPrefix(#"<meta name="description" content="import Foundation func greet() &#123;&#125;">"#))
        XCTAssertTrue(head.meta.contains(#"<meta name="twitter:card" content="summary">"#))
        XCTAssertFalse(head.meta.contains("og:image"))
    }

    func testGalleryHead() {
        let page = SharePage(kind: .gallery, lang: "en", created: created, files: [
            .init(name: "notes.txt", url: "https://x.example/n", size: 100_000, type: "text/plain"),
            .init(name: "a.png", url: "https://x.example/a", size: 2_000_000, type: "image/png", ogImage: "https://x.example/a"),
            .init(name: "b.png", url: "https://x.example/b", size: 2_000_000, type: "image/png", ogImage: "https://x.example/b"),
        ])
        let head = SharePages.head(for: page)
        XCTAssertEqual(head.title, "notes.txt +2")
        XCTAssertTrue(head.meta.contains(#"<meta name="description" content="3 files · 4.1 MB">"#))
        XCTAssertTrue(head.meta.contains(#"<meta property="og:image" content="https://x.example/a">"#), "the first file that has one")
        XCTAssertTrue(SharePages.dataJSON(page).contains(#""kind":"gallery""#))
    }

    func testEncryptedPageLeaksNothing() {
        let page = SharePage(kind: .encrypted, lang: "de", created: created, encrypted: .init(url: "https://x.example/e/abc", size: 4567, password: true))
        XCTAssertEqual(SharePages.dataJSON(page), #"{"v":1,"kind":"encrypted","lang":"de","created":"2026-10-27T08:00:00Z","expires":null,"encrypted":{"url":"https://x.example/e/abc","size":4567,"password":true}}"#)
        let head = SharePages.head(for: page)
        XCTAssertEqual(head.title, "Encrypted file")
        XCTAssertEqual(head.meta, """
        <meta name="description" content="Open the link to decrypt it in the browser.">
        <meta property="og:title" content="Encrypted file">
        <meta property="og:description" content="Open the link to decrypt it in the browser.">
        <meta property="og:type" content="website">
        <meta name="twitter:card" content="summary">
        <meta name="twitter:title" content="Encrypted file">
        """)
    }

    func testRequestPage() {
        let request = SharePage.Request(title: "Logs <for> the crash", note: "", maxBytes: 2_000_000_000, conditional: true, slots: [.init(file: "https://s3.example/1?X-Amz=1&b=2", meta: "https://s3.example/1.json")])
        let page = SharePage(kind: .request, lang: "en", created: created, expires: created.addingTimeInterval(3600), request: request)
        XCTAssertEqual(SharePages.dataJSON(page), #"{"v":1,"kind":"request","lang":"en","created":"2026-10-27T08:00:00Z","expires":"2026-10-27T09:00:00Z","request":{"title":"Logs <for> the crash","note":"","maxBytes":2000000000,"conditional":true,"slots":[{"file":"https://s3.example/1?X-Amz=1&b=2","meta":"https://s3.example/1.json"}]}}"#)
        let html = SharePages.build(page, template: template)
        XCTAssertTrue(html.contains(#""title":"Logs \u003cfor\u003e the crash""#))
        XCTAssertTrue(html.contains(#"?X-Amz=1\u0026b=2"#))
        let head = SharePages.head(for: page)
        XCTAssertEqual(head.title, "Logs <for> the crash")
        XCTAssertTrue(head.meta.contains("Upload files straight to the requester\u{2019}s storage."))
        var untitled = request
        untitled.title = ""
        untitled.note = "Please send the logs\nand a screenshot."
        let other = SharePages.head(for: SharePage(kind: .request, lang: "en", created: created, request: untitled))
        XCTAssertEqual(other.title, "Send files")
        XCTAssertTrue(other.meta.contains(#"content="Please send the logs and a screenshot.""#))
    }

    func testBrandIsOnlyWrittenWhenOff() {
        var page = SharePage(kind: .file, lang: "en", created: created, files: [.init(name: "a", url: "https://x/a", size: 1, type: "text/plain")])
        XCTAssertFalse(SharePages.dataJSON(page).contains("brand"))
        page.brand = false
        XCTAssertTrue(SharePages.dataJSON(page).hasSuffix(#","brand":false}"#))
    }

    // MARK: - What a page shows

    func testOgImageRules() {
        XCTAssertEqual(SharePages.ogImage(type: "image/png", size: 8_000_000, url: "u", thumb: "t"), "u")
        XCTAssertEqual(SharePages.ogImage(type: "image/png", size: 8_000_001, url: "u", thumb: "t"), "t", "too big for crawlers")
        XCTAssertEqual(SharePages.ogImage(type: "image/svg+xml", size: 10, url: "u", thumb: nil), nil)
        XCTAssertEqual(SharePages.ogImage(type: "image/heic", size: 10, url: "u", thumb: "t"), "t")
        XCTAssertEqual(SharePages.ogImage(type: "application/pdf", size: 10, url: "u", thumb: "t"), "t")
        XCTAssertNil(SharePages.ogImage(type: "application/zip", size: 10, url: "u", thumb: nil))
    }

    func testTextDetection() throws {
        XCTAssertTrue(SharePages.isTextType("text/plain; charset=utf-8"))
        XCTAssertTrue(SharePages.isTextType("application/json"))
        XCTAssertTrue(SharePages.isTextType("application/toml"))
        XCTAssertFalse(SharePages.isTextType("application/pdf"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("a.txt")
        try Data("héllo".utf8).write(to: small)
        XCTAssertEqual(SharePages.pageText(of: small, contentType: "text/plain"), "héllo")
        let invalid = folder.appendingPathComponent("b.txt")
        try Data([0x68, 0xFF, 0x69]).write(to: invalid)
        XCTAssertNil(SharePages.pageText(of: invalid, contentType: "text/plain"), "not UTF-8")
        let big = folder.appendingPathComponent("c.txt")
        try Data(repeating: 0x61, count: SharePages.maxTextBytes + 1).write(to: big)
        XCTAssertNil(SharePages.pageText(of: big, contentType: "text/plain"), "over 256 KB")
        try Data(repeating: 0x61, count: SharePages.maxTextBytes).write(to: big)
        XCTAssertNotNil(SharePages.pageText(of: big, contentType: "text/plain"))
        XCTAssertNil(SharePages.pageText(of: small, contentType: "image/png"))
    }

    func testSyntax() {
        XCTAssertEqual(SharePages.syntax(forFilename: "a.swift"), "swift")
        XCTAssertEqual(SharePages.syntax(forFilename: "a.TSX"), "tsx")
        XCTAssertEqual(SharePages.syntax(forFilename: "Dockerfile"), "dockerfile")
        XCTAssertEqual(SharePages.syntax(forFilename: "makefile"), "makefile")
        XCTAssertEqual(SharePages.syntax(forFilename: "notes.md"), "markdown")
        XCTAssertEqual(SharePages.syntax(forFilename: "x.yml"), "yaml")
        XCTAssertEqual(SharePages.syntax(forFilename: "run.ps1"), "powershell")
        XCTAssertEqual(SharePages.syntax(forFilename: "data.csv"), "text")
        XCTAssertEqual(SharePages.syntax(forFilename: "app.log"), "text")
        XCTAssertEqual(SharePages.syntax(forFilename: "x.unknown"), "text")
        for name in ["a.swift", "a.kt", "a.java", "a.js", "a.ts", "a.py", "a.rb", "a.go", "a.rs", "a.c", "a.cpp", "a.cs", "a.php", "a.sh", "a.sql", "a.html", "a.css", "a.scss", "a.xml", "a.toml", "a.ini", "a.r", "a.pl", "a.lua", "a.dart", "a.scala", "a.ex"] {
            XCTAssertTrue(SharePages.syntaxNames.contains(SharePages.syntax(forFilename: name)), name)
        }
    }

    // MARK: - Keys

    func testPageAndGalleryKeys() {
        XCTAssertEqual(SharePages.pageKey(forFileKey: "2026/11/x7Kp2.png"), "2026/11/x7Kp2.png.html")
        XCTAssertEqual(SharePages.pageKey(forFileKey: "tmp/7d/2026/11/x7Kp2.png"), "tmp/7d/2026/11/x7Kp2.png.html", "under the file's expiry prefix")
        XCTAssertEqual(SharePages.galleryKey(forFirstFileKey: "tmp/1d/a.png"), "tmp/1d/a.png.gallery.html")
        XCTAssertEqual(SharePages.encryptedKey(expiryDays: nil, code: "A"), "e/A")
        XCTAssertEqual(SharePages.encryptedKey(expiryDays: 7, code: "A"), "tmp/7d/e/A")
        let random = SharePages.encryptedKey(expiryDays: 30)
        XCTAssertTrue(random.hasPrefix("tmp/30d/e/"))
        XCTAssertEqual(random.count, "tmp/30d/e/".count + 22)
        XCTAssertTrue(random.dropFirst("tmp/30d/e/".count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    func testPageURLFromTheFileURL() {
        XCTAssertEqual(
            SharePages.pageURL(fileURL: "https://cdn.example.com/2026/11/my%20shot.png", fileKey: "2026/11/my shot.png", pageKey: "2026/11/my shot.png.html")?.absoluteString,
            "https://cdn.example.com/2026/11/my%20shot.png.html"
        )
        XCTAssertNil(SharePages.pageURL(fileURL: "https://cdn.example.com/other.png", fileKey: "a.png", pageKey: "a.png.html"))
    }

    // MARK: - Warnings and origins

    func testWarnings() {
        XCTAssertTrue(SharePages.isR2Dev(publicBaseURL: "https://pub-123.r2.dev"))
        XCTAssertTrue(SharePages.isR2Dev(publicBaseURL: "pub-123.r2.dev/"))
        XCTAssertFalse(SharePages.isR2Dev(publicBaseURL: "https://cdn.example.com"))
        XCTAssertTrue(SharePages.isPathStyle(publicBaseURL: "http://127.0.0.1:9000/shots", bucket: "shots"))
        XCTAssertTrue(SharePages.isPathStyle(publicBaseURL: "https://f004.backblazeb2.com/file/shots", bucket: "shots"))
        XCTAssertFalse(SharePages.isPathStyle(publicBaseURL: "https://shots.s3.amazonaws.com", bucket: "shots"))
        XCTAssertFalse(SharePages.isPathStyle(publicBaseURL: "https://cdn.example.com/files", bucket: "shots"))
    }

    func testOrigins() {
        XCTAssertEqual(SharePages.origin(of: "cdn.example.com/a/b"), "https://cdn.example.com")
        XCTAssertEqual(SharePages.origin(of: "https://CDN.example.com:443/x"), "https://cdn.example.com")
        XCTAssertEqual(SharePages.origin(of: "http://127.0.0.1:9000/b/k"), "http://127.0.0.1:9000")
        XCTAssertNil(SharePages.origin(of: ""))
    }

    // MARK: - Output and history

    func testCopyAsWithAPage() throws {
        let page = try XCTUnwrap(URL(string: "https://cdn.example.com/a.png.html"))
        let file = try XCTUnwrap(URL(string: "https://cdn.example.com/a.png"))
        XCTAssertEqual(OutputFormatter.format(publicURL: page, mode: .url, filename: "a.png", fileURL: file), page.absoluteString)
        XCTAssertEqual(OutputFormatter.format(publicURL: page, mode: .markdown, filename: "a.png", fileURL: file), "![](https://cdn.example.com/a.png)", "images embed the file")
        XCTAssertEqual(OutputFormatter.format(publicURL: page, mode: .html, filename: "clip.mp4", fileURL: file), #"<a href="https://cdn.example.com/a.png">clip.mp4</a>"#, "videos keep the file link")
        XCTAssertEqual(OutputFormatter.format(publicURL: page, mode: .markdown, filename: "doc.pdf", fileURL: file), "[doc.pdf](https://cdn.example.com/a.png.html)")
        XCTAssertEqual(OutputFormatter.format(publicURL: page, mode: .custom, filename: "a.png", customTemplate: "{url} {file} {filename}", fileURL: file), "https://cdn.example.com/a.png.html https://cdn.example.com/a.png a.png")
        XCTAssertEqual(OutputFormatter.format(publicURL: file, mode: .custom, filename: "a.png", customTemplate: "{file}"), "https://cdn.example.com/a.png", "without a page, {file} is the link")
        XCTAssertEqual(OutputFormatter.formatGallery(link: page, title: "a.png +2", mode: .markdown), "[a.png +2](https://cdn.example.com/a.png.html)")
        XCTAssertEqual(OutputFormatter.formatGallery(link: page, title: "a&b +1", mode: .html), #"<a href="https://cdn.example.com/a.png.html">a&amp;b +1</a>"#)
        XCTAssertEqual(OutputFormatter.formatGallery(link: page, title: "x", mode: .custom), page.absoluteString)
    }

    func testRecordLinks() {
        let record = UploadRecord(localFilename: "a.png", objectKey: "tmp/1d/a b.png", publicURLString: "https://cdn.example.com/tmp/1d/a%20b.png", destinationID: UUID(), destinationName: "D", mimeType: "image/png", byteSize: 1)
        XCTAssertEqual(record.shareURLString, "https://cdn.example.com/tmp/1d/a%20b.png")
        record.sharePageKey = "tmp/1d/a b.png.html"
        XCTAssertEqual(record.shareURLString, "https://cdn.example.com/tmp/1d/a%20b.png.html")
        record.encryptionKey = "AAEC"
        XCTAssertEqual(record.shareURLString, "https://cdn.example.com/tmp/1d/a%20b.png.html#k=AAEC")
        record.encryptionSalt = "00"
        XCTAssertEqual(record.shareURLString, "https://cdn.example.com/tmp/1d/a%20b.png.html", "a password's key is never in the link")
        XCTAssertNil(record.sourceLabel)
        record.requestID = "abc"
        record.requestTitle = "Logs"
        XCTAssertEqual(record.sourceLabel, String(localized: "Request: Logs"))
    }

    // MARK: - Settings

    func testDestinationSettingsAreOptional() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","preset":"amazonS3","endpoint":"s3.amazonaws.com","region":"us-east-1","bucket":"b","publicBaseURL":"https://b.example","objectPathTemplate":"{filename}.{ext}","forcePathStyle":false,"isDefault":true}"#
        let decoded = try JSONDecoder().decode(DestinationConfig.self, from: Data(old.utf8))
        XCTAssertNil(decoded.sharePage)
        XCTAssertNil(decoded.encryption)
        XCTAssertFalse(decoded.writesSharePages)
        var config = decoded
        config.sharePage = true
        config.encryption = .password
        config.requestCorsOrigin = "https://b.example"
        let again = try JSONDecoder().decode(DestinationConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(again.sharePage, true)
        XCTAssertEqual(again.encryption, .password)
        XCTAssertEqual(again.requestCorsOrigin, "https://b.example")
        XCTAssertFalse(again.writesSharePages, "an encrypted destination writes its own pages")
    }

    func testTransferCarriesSharePageAndEncryption() throws {
        var config = DestinationConfig(name: "A", preset: .amazonS3, endpoint: "s3.amazonaws.com", region: "us-east-1", bucket: "b", publicBaseURL: "https://b.example", objectPathTemplate: "{short}.{ext}", forcePathStyle: false, isDefault: false)
        config.sharePage = true
        config.encryption = .link
        config.requestCorsOrigin = "https://b.example"
        let payload = DestinationTransfer.Payload(destination: config, credentials: StorageCredentials(accessKeyId: "a", secretAccessKey: "s", sessionToken: nil))
        let data = try DestinationTransfer.encodePayload(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let destination = try XCTUnwrap(object["destination"] as? [String: Any])
        XCTAssertEqual(destination["sharePage"] as? Bool, true)
        XCTAssertEqual(destination["encryption"] as? String, "link")
        XCTAssertNil(destination["requestCorsOrigin"], "not transferred")
        let decoded = try DestinationTransfer.decodePayload(data)
        XCTAssertEqual(decoded.destination.sharePage, true)
        XCTAssertEqual(decoded.destination.encryption, .link)
        XCTAssertNil(decoded.destination.requestCorsOrigin)

        // Older payloads don't have them; unknown values are left off.
        var stripped = object
        var plain = destination
        plain["sharePage"] = nil
        plain["encryption"] = "quantum"
        stripped["destination"] = plain
        let old = try DestinationTransfer.decodePayload(JSONSerialization.data(withJSONObject: stripped))
        XCTAssertNil(old.destination.sharePage)
        XCTAssertNil(old.destination.encryption)
    }
}
