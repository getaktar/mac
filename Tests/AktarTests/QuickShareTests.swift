import AppKit
import Network
import XCTest

/// docs/capture-and-instant-links.md: copied text and links as uploads,
/// downloading a copied link, the clipboard kept for Undo, the outbox that
/// keeps an instant link's upload going after a restart, and the charset
/// text is sent with.
final class QuickShareTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Copied text

    func testOneLinkIsALink() throws {
        XCTAssertEqual(ClipboardText.link(in: "https://example.com/a.png")?.absoluteString, "https://example.com/a.png")
        XCTAssertEqual(ClipboardText.link(in: "  http://example.com/x?y=1#z \n")?.absoluteString, "http://example.com/x?y=1#z")
        XCTAssertNotNil(ClipboardText.link(in: "HTTPS://Example.com"))
        // Not one http(s) link and nothing else.
        XCTAssertNil(ClipboardText.link(in: "see https://example.com/a.png"))
        XCTAssertNil(ClipboardText.link(in: "https://example.com/a.png https://example.com/b.png"))
        XCTAssertNil(ClipboardText.link(in: "ftp://example.com/a.png"))
        XCTAssertNil(ClipboardText.link(in: "file:///Users/me/a.png"))
        XCTAssertNil(ClipboardText.link(in: "example.com/a.png"))
        XCTAssertNil(ClipboardText.link(in: "https://"))
        XCTAssertNil(ClipboardText.link(in: ""))
        XCTAssertNil(ClipboardText.link(in: "https://example.com/" + String(repeating: "a", count: ClipboardText.maxLinkLength)))
    }

    func testTextKinds() {
        XCTAssertEqual(ClipboardText.kind(of: "{\"a\": [1, 2]}"), .json)
        XCTAssertEqual(ClipboardText.kind(of: "  [1, 2, 3]\n"), .json)
        XCTAssertEqual(ClipboardText.kind(of: "{not json"), .plain)
        XCTAssertEqual(ClipboardText.kind(of: "\"just a string\""), .plain)

        XCTAssertEqual(ClipboardText.kind(of: "# Release notes\nFixed things."), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "Run this:\n```\nmake test\n```"), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "- milk\n- eggs"), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "1. one\n2. two"), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "See [the docs](https://example.com/docs)."), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "| a | b |\n|---|---|\n| 1 | 2 |"), .markdown)
        XCTAssertEqual(ClipboardText.kind(of: "- [ ] write tests"), .markdown)

        XCTAssertEqual(ClipboardText.kind(of: "Merhaba, toplantı 15:00'te."), .plain)
        XCTAssertEqual(ClipboardText.kind(of: "- one dash line"), .plain)
        XCTAssertEqual(ClipboardText.kind(of: "#hashtag without a space"), .plain)
        XCTAssertEqual(ClipboardText.kind(of: "2026 was a year."), .plain)
        XCTAssertEqual(ClipboardText.Kind.markdown.fileExtension, "md")
        XCTAssertEqual(ClipboardText.Kind.plain.fileExtension, "txt")
        XCTAssertEqual(ClipboardText.Kind.json.fileExtension, "json")
        XCTAssertFalse(ClipboardText.hasContent(" \n\t "))
        XCTAssertTrue(ClipboardText.hasContent(" a "))
    }

    // MARK: - Downloaded file names

    func testNameFromContentDisposition() {
        XCTAssertEqual(RemoteFileName.filename(fromContentDisposition: "attachment; filename=\"report 2026.pdf\""), "report 2026.pdf")
        XCTAssertEqual(RemoteFileName.filename(fromContentDisposition: "attachment; filename=plain.txt"), "plain.txt")
        XCTAssertEqual(RemoteFileName.filename(fromContentDisposition: "attachment; filename=\"fallback.pdf\"; filename*=UTF-8''%E2%82%AC%20rates.pdf"), "\u{20AC} rates.pdf")
        XCTAssertEqual(RemoteFileName.filename(fromContentDisposition: "inline; filename=\"a \\\"quoted\\\" name.png\""), "a \"quoted\" name.png")
        XCTAssertNil(RemoteFileName.filename(fromContentDisposition: "inline"))
    }

    func testResolvedNames() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/i/photo.jpg?w=200"))
        XCTAssertEqual(RemoteFileName.resolve(url: url, contentDisposition: nil, mimeType: "image/jpeg"), "photo.jpg")
        // The file's real type wins over a name that says otherwise.
        XCTAssertEqual(RemoteFileName.resolve(url: url, contentDisposition: nil, mimeType: "image/webp"), "photo.webp")
        // A content type that says nothing keeps the name's extension.
        XCTAssertEqual(RemoteFileName.resolve(url: url, contentDisposition: nil, mimeType: "application/octet-stream"), "photo.jpg")
        // No extension: the content type's.
        let bare = try XCTUnwrap(URL(string: "https://example.com/media/12345"))
        XCTAssertEqual(RemoteFileName.resolve(url: bare, contentDisposition: nil, mimeType: "image/png; charset=binary"), "12345.png")
        // Content-Disposition first; folders in it are dropped.
        XCTAssertEqual(RemoteFileName.resolve(url: bare, contentDisposition: "attachment; filename=\"../../evil/clip.mp4\"", mimeType: "video/mp4"), "clip.mp4")
        // Nothing usable at all.
        let root = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertEqual(RemoteFileName.resolve(url: root, contentDisposition: nil, mimeType: nil), "download")
        XCTAssertEqual(RemoteFileName.resolve(url: root, contentDisposition: nil, mimeType: "application/pdf"), "download.pdf")
        // Percent-encoded names are decoded.
        let encoded = try XCTUnwrap(URL(string: "https://example.com/Ekran%20Resmi%20%C3%A7.png"))
        XCTAssertEqual(RemoteFileName.suggestedName(for: encoded), "Ekran Resmi \u{E7}.png")
        // Long names are cut, keeping the extension.
        let long = try XCTUnwrap(URL(string: "https://example.com/" + String(repeating: "x", count: 300) + ".png"))
        let name = RemoteFileName.resolve(url: long, contentDisposition: nil, mimeType: "image/png")
        XCTAssertEqual(name.count, RemoteFileName.maxLength)
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    // MARK: - Downloading a copied link

    func testDownloadsAFileUnderItsName() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let server = try await TinyHTTPServer.start { path in
            switch path {
            case "/image": return .init(status: 200, headers: ["Content-Type": "image/png"], body: png)
            case "/named": return .init(status: 200, headers: ["Content-Type": "application/pdf", "Content-Disposition": "attachment; filename=\"Q3 report.pdf\""], body: Data("%PDF-1.4".utf8))
            case "/moved": return .init(status: 302, headers: ["Location": "/image"], body: Data())
            default: return .init(status: 404, headers: [:], body: Data())
            }
        }
        defer { server.stop() }

        let image = try await RemoteDownloader.download(RemoteSource(url: server.url("/image")), into: directory) { _ in }
        XCTAssertEqual(image.filename, "image.png")
        XCTAssertEqual(try Data(contentsOf: image.fileURL), png)
        XCTAssertEqual(image.fileURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)

        let named = try await RemoteDownloader.download(RemoteSource(url: server.url("/named")), into: directory) { _ in }
        XCTAssertEqual(named.filename, "Q3 report.pdf")

        // Redirects are followed; the name comes from where they end.
        let moved = try await RemoteDownloader.download(RemoteSource(url: server.url("/moved")), into: try newFolder()) { _ in }
        XCTAssertEqual(moved.filename, "image.png")
    }

    func testWebPagesAndErrorsAreRefused() async throws {
        let server = try await TinyHTTPServer.start { path in
            switch path {
            case "/page": return .init(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<html></html>".utf8))
            case "/empty": return .init(status: 200, headers: ["Content-Type": "image/png"], body: Data())
            case "/busy": return .init(status: 503, headers: [:], body: Data())
            default: return .init(status: 404, headers: [:], body: Data("nope".utf8))
            }
        }
        defer { server.stop() }

        await assertDownloadFails(server.url("/page"), with: .webPage)
        await assertDownloadFails(server.url("/empty"), with: .empty)
        await assertDownloadFails(server.url("/missing"), with: .status(404))
        // A busy server may answer later: that's for the queue to retry.
        do {
            _ = try await RemoteDownloader.download(RemoteSource(url: server.url("/busy")), into: directory) { _ in }
            XCTFail("A 503 shouldn't succeed")
        } catch {
            XCTAssertTrue(error is URLError, "\(error)")
        }
        // Nothing is left behind by the refused ones.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func assertDownloadFails(_ url: URL, with expected: RemoteDownloadError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await RemoteDownloader.download(RemoteSource(url: url), into: directory) { _ in }
            XCTFail("\(url) shouldn't download", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteDownloadError, expected, file: file, line: line)
        }
    }

    private func newFolder() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Clipboard kept for Undo

    @MainActor
    func testClipboardSnapshotPutsEverythingBack() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickShareTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .png)
        pasteboard.writeObjects([item])

        let snapshot = try XCTUnwrap(ClipboardSnapshot.take(from: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/link", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(pasteboard.data(forType: .png), Data([1, 2, 3]))

        // An empty clipboard comes back empty.
        pasteboard.clearContents()
        let empty = try XCTUnwrap(ClipboardSnapshot.take(from: pasteboard))
        pasteboard.setString("link", forType: .string)
        empty.restore(to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testPasswordsAreNeverKept() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickShareTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertNil(ClipboardSnapshot.take(from: pasteboard))
    }

    // MARK: - Outbox

    @MainActor
    func testOutboxKeepsAnUploadUntilItsDone() async throws {
        let outbox = UploadOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
        let file = directory.appendingPathComponent("Screenshot.png")
        try Data("pixels".utf8).write(to: file)
        let early = EarlyLink(
            objectKey: "2026/11/Ab3dE7x.png",
            link: try XCTUnwrap(URL(string: "https://cdn.example.com/2026/11/Ab3dE7x.png")),
            temporaryExpiresAt: nil,
            shortLink: EarlyShortLink(shortUrl: "https://s.example/x", providerId: "x", provider: "shlink", providerName: "Shlink", domain: nil, targetUrl: "https://cdn.example.com/2026/11/Ab3dE7x.png", expiresAt: nil),
            shortLinkError: nil,
            copiedText: "https://s.example/x"
        )
        let entry = OutboxEntry(
            id: UUID(), destinationID: UUID(), originalFilename: "Screenshot.png", storedName: file.lastPathComponent,
            expiryDays: 7, shortLinkOverride: nil, earlyLink: early, firstAttemptAt: Date(timeIntervalSinceReferenceDate: Date.now.timeIntervalSinceReferenceDate.rounded()), failure: nil
        )
        let saved = await outbox.save(entry, file: file)
        XCTAssertTrue(saved)
        XCTAssertTrue(outbox.contains(entry.id))

        // The kept copy doesn't depend on the original.
        try FileManager.default.removeItem(at: file)
        var loaded = outbox.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.entry, entry)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(loaded.first?.fileURL)), Data("pixels".utf8))

        var failed = entry
        failed.failure = "Access denied"
        XCTAssertTrue(outbox.update(failed))
        loaded = outbox.load()
        XCTAssertEqual(loaded.first?.entry.failure, "Access denied")

        outbox.remove(entry.id)
        XCTAssertTrue(outbox.load().isEmpty)
        XCTAssertFalse(outbox.contains(entry.id))
    }

    @MainActor
    func testOutboxDropsWhatItCantRead() throws {
        let root = directory.appendingPathComponent("Outbox", isDirectory: true)
        let broken = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("entry.json"))
        let stray = root.appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let outbox = UploadOutbox(directory: root)
        XCTAssertTrue(outbox.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    @MainActor
    func testOldOutboxEntriesAreDropped() async throws {
        let outbox = UploadOutbox(directory: directory.appendingPathComponent("Outbox", isDirectory: true))
        let file = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let early = EarlyLink(objectKey: "a.txt", link: try XCTUnwrap(URL(string: "https://cdn.example.com/a.txt")), copiedText: "https://cdn.example.com/a.txt")
        let started = Date(timeIntervalSince1970: 1_000_000)
        let entry = OutboxEntry(id: UUID(), destinationID: UUID(), originalFilename: "a.txt", storedName: "a.txt", expiryDays: nil, shortLinkOverride: nil, earlyLink: early, firstAttemptAt: started, failure: nil)
        let saved = await outbox.save(entry, file: file)
        XCTAssertTrue(saved)
        XCTAssertEqual(outbox.load(now: started.addingTimeInterval(86_400)).count, 1)
        XCTAssertTrue(outbox.load(now: started.addingTimeInterval(OutboxEntry.maxAge + 1)).isEmpty)
        XCTAssertFalse(outbox.contains(entry.id))
    }

    func testOutboxCopiesWithinTheSameDisk() throws {
        let file = directory.appendingPathComponent("big.bin")
        try Data(count: 16).write(to: file)
        XCTAssertTrue(UploadOutbox.canCopy(file, into: directory))
        XCTAssertEqual(UploadOutbox.totalSize(of: file), 16)
    }

    func testEarlyLinksSurviveEncoding() throws {
        let early = EarlyLink(
            objectKey: "tmp/7d/a.png",
            link: try XCTUnwrap(URL(string: "https://bucket.s3.amazonaws.com/tmp/7d/a.png?X-Amz-Signature=abc")),
            temporaryExpiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            shortLink: nil,
            shortLinkError: "The shortener didn't answer.",
            copiedText: "![](https://bucket.s3.amazonaws.com/tmp/7d/a.png?X-Amz-Signature=abc)"
        )
        let decoded = try JSONDecoder().decode(EarlyLink.self, from: JSONEncoder().encode(early))
        XCTAssertEqual(decoded, early)
    }

    // MARK: - Offline queue

    func testOfflineRetriesSlowDown() {
        XCTAssertEqual(OfflineRetry.delay(afterTries: 0), 15)
        XCTAssertEqual(OfflineRetry.delay(afterTries: 1), 15)
        XCTAssertEqual(OfflineRetry.delay(afterTries: 2), 30)
        XCTAssertEqual(OfflineRetry.delay(afterTries: 5), 300)
        XCTAssertEqual(OfflineRetry.delay(afterTries: 50), 300)
    }

    // MARK: - Text charset

    func testUTF8TextIsSentWithItsCharset() throws {
        let text = directory.appendingPathComponent("clipboard-1.txt")
        try Data("Merhaba dünya, ğüşiöç".utf8).write(to: text)
        XCTAssertEqual(ContentTypeResolver.uploadContentType(for: text), "text/plain; charset=utf-8")
        XCTAssertEqual(ContentTypeResolver.resolve(for: text), "text/plain")

        let markdown = directory.appendingPathComponent("notes.md")
        try Data("# Başlık".utf8).write(to: markdown)
        XCTAssertTrue(ContentTypeResolver.uploadContentType(for: markdown).hasSuffix("; charset=utf-8"))

        // Latin-1 bytes aren't UTF-8: no charset is claimed.
        let latin1 = directory.appendingPathComponent("old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin1)
        XCTAssertEqual(ContentTypeResolver.uploadContentType(for: latin1), "text/plain")

        let json = directory.appendingPathComponent("data.json")
        try Data("{}".utf8).write(to: json)
        XCTAssertEqual(ContentTypeResolver.uploadContentType(for: json), "application/json")
    }
}

/// Just enough HTTP/1.1 on the loopback interface to answer a download:
/// one canned response per path, then the connection closes.
private final class TinyHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private let listener: NWListener
    private let respond: @Sendable (String) -> Response
    private let queue = DispatchQueue(label: "QuickShareTests.server")
    let port: UInt16

    private init(listener: NWListener, port: UInt16, respond: @escaping @Sendable (String) -> Response) {
        self.listener = listener
        self.port = port
        self.respond = respond
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    static func start(_ respond: @escaping @Sendable (String) -> Response) async throws -> TinyHTTPServer {
        for _ in 0..<20 {
            let port = UInt16.random(in: 49152...64000)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            guard let listener = try? NWListener(using: parameters) else { continue }
            let server = TinyHTTPServer(listener: listener, port: port, respond: respond)
            let ready: Bool = await withCheckedContinuation { continuation in
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume(returning: true) }
                    case .failed, .cancelled: once.run { continuation.resume(returning: false) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in server.handle(connection) }
                listener.start(queue: server.queue)
            }
            if ready { return server }
            listener.cancel()
        }
        throw XCTSkip("No free port for the test server.")
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [respond] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response = respond(path)
            var head = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// Runs its block once, whichever thread gets there first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        block()
    }
}
