import CryptoKit
import XCTest

/// The WebDAV backend against a real WebDAV server: Test Connection, small
/// and big uploads into nested folders, reading, listing, copying,
/// deleting and making folders, and how failures are reported.
///
/// Runs only with AKTAR_TEST_WEBDAV_ENDPOINT, AKTAR_TEST_WEBDAV_USER and
/// AKTAR_TEST_WEBDAV_PASSWORD set (TEST_RUNNER_ prefixed for xcodebuild);
/// AKTAR_TEST_WEBDAV_PUBLIC_URL serves the same folder without a password,
/// and AKTAR_TEST_WEBDAV_DIR is that folder on this Mac.
/// `scripts/test-webdav.sh` starts a throwaway `rclone serve webdav` and
/// sets everything up. Each test works in a folder of its own.
final class WebDAVIntegrationTests: XCTestCase {
    private var credentials = StorageCredentials(accessKeyId: "", secretAccessKey: "", sessionToken: nil)
    private var serverEndpoint = ""
    private var publicRoot = ""
    private var localRoot: URL?
    /// This test's folder under the server's endpoint.
    private var folder = ""
    private var backend: WebDAVBackend!
    private var directory: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["AKTAR_TEST_WEBDAV_ENDPOINT"],
              let user = environment["AKTAR_TEST_WEBDAV_USER"],
              let password = environment["AKTAR_TEST_WEBDAV_PASSWORD"] else {
            throw XCTSkip("AKTAR_TEST_WEBDAV_ENDPOINT, AKTAR_TEST_WEBDAV_USER and AKTAR_TEST_WEBDAV_PASSWORD aren't set (scripts/test-webdav.sh sets them)")
        }
        serverEndpoint = endpoint
        publicRoot = environment["AKTAR_TEST_WEBDAV_PUBLIC_URL"] ?? ""
        localRoot = environment["AKTAR_TEST_WEBDAV_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        credentials = StorageCredentials(accessKeyId: user, secretAccessKey: password, sessionToken: nil)
        folder = "run-\(UUID().uuidString.prefix(8).lowercased())"
        try await WebDAVBackend(config: config(endpoint: serverEndpoint), credentials: credentials).createFolder(prefix: folder + "/")
        backend = WebDAVBackend(config: config(), credentials: credentials)

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebDAVIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if backend != nil {
            try? await WebDAVBackend(config: config(endpoint: serverEndpoint), credentials: credentials).delete(objectKey: folder + "/")
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        backend = nil
    }

    // MARK: - Connection

    func testConnection() async throws {
        let result = try await backend.testConnection()
        XCTAssertTrue(result.bucketReachable)
        XCTAssertTrue(result.writable)
        if !publicRoot.isEmpty {
            XCTAssertEqual(result.publicLink, .reachable)
        }
        // The test file is cleaned up.
        let listing = try await backend.list(prefix: "", continuationToken: nil)
        XCTAssertEqual(listing.objects, [])

        // Without a public base URL there's nothing to open.
        var noPublicURL = config()
        noPublicURL.publicBaseURL = ""
        let publicLink = try await WebDAVBackend(config: noPublicURL, credentials: credentials).testConnection().publicLink
        XCTAssertNil(publicLink)

        // A public base URL that doesn't serve this folder.
        var wrongPublicURL = config()
        wrongPublicURL.publicBaseURL = publicRoot.isEmpty ? "http://127.0.0.1:9/nothing" : publicRoot + "/elsewhere"
        let wrongLink = try await WebDAVBackend(config: wrongPublicURL, credentials: credentials).testConnection().publicLink
        XCTAssertNotEqual(wrongLink, .reachable)
    }

    func testWrongPasswordAndMissingFolder() async throws {
        let wrong = StorageCredentials(accessKeyId: credentials.accessKeyId, secretAccessKey: "wrong", sessionToken: nil)
        do {
            _ = try await WebDAVBackend(config: config(), credentials: wrong).testConnection()
            XCTFail("A wrong password connected")
        } catch StorageError.wrongUserNameOrPassword {
        }
        do {
            _ = try await WebDAVBackend(config: config(endpoint: serverEndpoint + "/no-such-folder-\(folder)"), credentials: credentials).testConnection()
            XCTFail("A missing folder connected")
        } catch StorageError.folderNotFound {
        }
        // A wrong password on an upload, too.
        let file = try write(Data("x".utf8), named: "x.txt")
        do {
            _ = try await WebDAVBackend(config: config(), credentials: wrong).upload(fileURL: file, objectKey: "x.txt", contentType: "text/plain", progress: nil)
            XCTFail("A wrong password uploaded")
        } catch StorageError.wrongUserNameOrPassword {
        }
    }

    // MARK: - Files

    func testSmallUploadIntoNestedFolders() async throws {
        let key = "2026/11/deep er/My Shot +1 %.txt"
        let body = Data("hello, webdav".utf8)
        let file = try write(body, named: "shot.txt")
        let result = try await backend.upload(fileURL: file, objectKey: key, contentType: "text/plain", progress: nil)
        XCTAssertEqual(result.objectKey, key)
        XCTAssertEqual(result.byteSize, body.count)
        XCTAssertEqual(result.publicURL, backend.publicURL(for: key))

        let exists = try await backend.objectExists(key: key)
        XCTAssertTrue(exists)
        let missing = try await backend.objectExists(key: "2026/11/nope.txt")
        XCTAssertFalse(missing)
        let info = try await backend.objectInfo(key: key)
        XCTAssertEqual(info?.size, Int64(body.count))
        XCTAssertNotNil(info?.lastModified)
        let modified = try await backend.lastModified(key: key)
        XCTAssertLessThan(abs((modified ?? .distantPast).timeIntervalSinceNow), 600)
        let infoMissing = try await backend.objectInfo(key: "missing.txt")
        XCTAssertNil(infoMissing)

        let got = try await backend.getObject(key: key, maxBytes: 1024)
        XCTAssertEqual(got?.data, body)
        let gotMissing = try await backend.getObject(key: "missing.txt", maxBytes: 1024)
        XCTAssertNil(gotMissing)

        let downloaded = directory.appendingPathComponent("down.txt")
        let found = try await backend.download(key: key, to: downloaded, maxBytes: 1024)
        XCTAssertTrue(found)
        XCTAssertEqual(try Data(contentsOf: downloaded), body)
        let notFound = try await backend.download(key: "missing.txt", to: downloaded, maxBytes: 1024)
        XCTAssertFalse(notFound)

        // The public link serves the same bytes.
        if !publicRoot.isEmpty {
            let (data, response) = try await URLSession.shared.data(from: try XCTUnwrap(result.publicURL))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, body)
        }
        if let local = localFile(key) {
            XCTAssertEqual(try Data(contentsOf: local), body)
        }
    }

    /// Over the S3 multipart threshold: still one streamed PUT, with the
    /// progress moving on the way.
    func testBigUploadIsOneStreamedPUT() async throws {
        let size = Int(S3Provider.multipartThreshold) + 3 * 1024 * 1024 + 17
        let file = directory.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        var hasher = SHA256()
        var written = 0
        var seed: UInt8 = 0
        while written < size {
            let count = min(4 * 1024 * 1024, size - written)
            let chunk = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
            seed &+= 31
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            written += count
        }
        try handle.close()
        let digest = hasher.finalize()

        let reports = ProgressLog()
        let result = try await backend.upload(fileURL: file, objectKey: "big/file.bin", contentType: "application/octet-stream") { value in
            reports.add(value)
        }
        XCTAssertEqual(result.byteSize, size)
        let info = try await backend.objectInfo(key: "big/file.bin")
        XCTAssertEqual(info?.size, Int64(size))
        try await Task.sleep(for: .milliseconds(200))
        let values = reports.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 }, "No progress between 0 and 1: \(values.count) reports")

        if let local = localFile("big/file.bin") {
            let stored = try Data(contentsOf: local)
            XCTAssertEqual(SHA256.hash(data: stored), digest)
        }
    }

    func testPutObjectAndReplace() async throws {
        try await backend.putObject(data: Data("<p>one</p>".utf8), objectKey: "pages/a.html", contentType: "text/html")
        try await backend.putObject(data: Data("<p>two</p>".utf8), objectKey: "pages/a.html", contentType: "text/html", cacheControl: "public, max-age=60")
        let got = try await backend.getObject(key: "pages/a.html", maxBytes: 100)
        XCTAssertEqual(got.map { String(decoding: $0.data, as: UTF8.self) }, "<p>two</p>")
        // Too big for what the caller takes.
        do {
            _ = try await backend.getObject(key: "pages/a.html", maxBytes: 3)
            XCTFail("An object over maxBytes was read")
        } catch {}
    }

    // MARK: - Listing

    /// Deleting a folder key behaves like S3's placeholder delete: a folder
    /// with files in it stays, an empty one goes.
    func testDeletingAFolderKeyKeepsItsFiles() async throws {
        try await backend.putObject(data: Data("keep".utf8), objectKey: "full/keep.txt", contentType: "text/plain")
        try await backend.delete(objectKey: "full/")
        let kept = try await backend.objectExists(key: "full/keep.txt")
        XCTAssertTrue(kept)

        try await backend.createFolder(prefix: "gone/")
        try await backend.delete(objectKey: "gone/")
        let root = try await backend.list(prefix: "", continuationToken: nil)
        XCTAssertFalse(root.folders.contains("gone/"), "\(root.folders)")
        XCTAssertTrue(root.folders.contains("full/"), "\(root.folders)")
    }

    func testListingAndNestedFolders() async throws {
        for key in ["a.txt", "b c.txt", "sub/one.txt", "sub/deeper/two.txt", "sub/deeper/three.txt", "other/four.txt"] {
            try await backend.putObject(data: Data(key.utf8), objectKey: key, contentType: "text/plain")
        }
        try await backend.createFolder(prefix: "empty/nested/")

        let root = try await backend.list(prefix: "", continuationToken: nil)
        XCTAssertEqual(root.objects.map(\.key), ["a.txt", "b c.txt"])
        XCTAssertEqual(root.folders, ["empty/", "other/", "sub/"])
        XCTAssertNil(root.nextContinuationToken)
        XCTAssertEqual(root.objects.first?.size, 5)
        XCTAssertNotNil(root.objects.first?.lastModified)

        let sub = try await backend.list(prefix: "sub/", continuationToken: nil)
        XCTAssertEqual(sub.objects.map(\.key), ["sub/one.txt"])
        XCTAssertEqual(sub.folders, ["sub/deeper/"])

        // A prefix that ends mid-name, as S3 lists them.
        let partial = try await backend.list(prefix: "sub/deeper/t", continuationToken: nil)
        XCTAssertEqual(partial.objects.map(\.key), ["sub/deeper/three.txt", "sub/deeper/two.txt"])

        // A folder that isn't there lists as empty.
        let none = try await backend.list(prefix: "nothing/", continuationToken: nil)
        XCTAssertEqual(none.objects, [])
        XCTAssertEqual(none.folders, [])

        let everything = try await allObjects(prefix: "")
        XCTAssertEqual(everything.objects, ["a.txt", "b c.txt", "other/four.txt", "sub/deeper/three.txt", "sub/deeper/two.txt", "sub/one.txt"])
        XCTAssertTrue(everything.folders.isSuperset(of: ["empty/", "empty/nested/", "sub/", "sub/deeper/", "other/"]))

        let underSub = try await allObjects(prefix: "sub/")
        XCTAssertEqual(underSub.objects, ["sub/deeper/three.txt", "sub/deeper/two.txt", "sub/one.txt"])
    }

    // MARK: - Changing

    func testCopyMoveAndDelete() async throws {
        try await backend.putObject(data: Data("copy me".utf8), objectKey: "from/x y.txt", contentType: "text/plain")
        try await backend.copy(from: "from/x y.txt", to: "to/new folder/x y.txt")
        let copied = try await backend.getObject(key: "to/new folder/x y.txt", maxBytes: 100)
        XCTAssertEqual(copied?.data, Data("copy me".utf8))
        let source = try await backend.objectExists(key: "from/x y.txt")
        XCTAssertTrue(source)

        // Overwrite: T replaces a file that's already there.
        try await backend.putObject(data: Data("other".utf8), objectKey: "to/other.txt", contentType: "text/plain")
        try await backend.copy(from: "from/x y.txt", to: "to/other.txt")
        let replaced = try await backend.getObject(key: "to/other.txt", maxBytes: 100)
        XCTAssertEqual(replaced?.data, Data("copy me".utf8))

        try await backend.delete(objectKey: "from/x y.txt")
        let gone = try await backend.objectExists(key: "from/x y.txt")
        XCTAssertFalse(gone)
        // Deleting what isn't there counts as done.
        try await backend.delete(objectKey: "from/x y.txt")

        try await backend.delete(objectKeys: ["to/new folder/x y.txt", "to/other.txt", "never.txt"])
        let left = try await allObjects(prefix: "")
        XCTAssertEqual(left.objects, [])

        // Copying a file that isn't there fails.
        do {
            try await backend.copy(from: "missing.txt", to: "copy.txt")
            XCTFail("Copied a missing file")
        } catch {}
    }

    func testUploadAfterItsFolderWasDeleted() async throws {
        try await backend.putObject(data: Data("1".utf8), objectKey: "gone/a.txt", contentType: "text/plain")
        try await backend.delete(objectKey: "gone/")
        // The same backend makes the folder again rather than trusting
        // that it's still there.
        try await backend.putObject(data: Data("2".utf8), objectKey: "gone/b.txt", contentType: "text/plain")
        let exists = try await backend.objectExists(key: "gone/b.txt")
        XCTAssertTrue(exists)
    }

    func testFactoryAndOnlyIfNew() async throws {
        let made = StorageBackends.make(config: config(), credentials: credentials)
        let file = try write(Data("first".utf8), named: "f.txt")
        _ = try await made.upload(fileURL: file, objectKey: "short/Ab12.txt", contentType: "text/plain", onlyIfNew: true, progress: nil)
        do {
            _ = try await made.upload(fileURL: file, objectKey: "short/Ab12.txt", contentType: "text/plain", onlyIfNew: true, progress: nil)
            XCTFail("A taken key was written")
        } catch StorageError.alreadyExists {
        }
    }

    // MARK: - Helpers

    private func config(endpoint: String? = nil) -> DestinationConfig {
        DestinationConfig(
            name: "WebDAV test",
            preset: .webdav,
            accountID: nil,
            endpoint: endpoint ?? "\(serverEndpoint)/\(folder)",
            region: "",
            bucket: "",
            publicBaseURL: publicRoot.isEmpty ? "https://files.example.com" : "\(publicRoot)/\(folder)",
            objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: false,
            isDefault: false
        )
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func localFile(_ key: String) -> URL? {
        localRoot?.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(key)
    }

    private func allObjects(prefix: String) async throws -> (objects: [String], folders: Set<String>) {
        var objects: [String] = []
        var folders = Set<String>()
        var token: String?
        repeat {
            let page = try await backend.listRecursively(prefix: prefix, continuationToken: token)
            objects += page.objects.map(\.key)
            folders.formUnion(page.folders)
            token = page.nextContinuationToken
        } while token != nil
        return (objects.sorted(), folders)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [Double] = []

    var values: [Double] { lock.withLock { reported } }

    func add(_ value: Double) {
        lock.withLock { reported.append(value) }
    }
}
