import CryptoKit
import XCTest

/// The SFTP backend against a real SFTP server: Test Connection and the
/// host key (trust on first use, a changed key), signing in with a password
/// and with ed25519 / RSA keys (encrypted too), uploads into nested
/// folders through part files, reading, listing, copying, moving, deleting
/// and how failures are reported.
///
/// Runs only with AKTAR_TEST_SFTP_ENDPOINT, AKTAR_TEST_SFTP_USER,
/// AKTAR_TEST_SFTP_PASSWORD and AKTAR_TEST_SFTP_KEYS set (TEST_RUNNER_
/// prefixed for xcodebuild); with an empty password every test signs in
/// with the ed25519 key (OpenSSH run as a user can't check passwords).
/// `scripts/test-sftp.sh` starts a throwaway `rclone serve sftp` (or, with
/// --openssh, macOS's sshd) and sets everything up. Each test works in a folder
/// of its own.
final class SFTPIntegrationTests: XCTestCase {
    private var endpoint = ""
    private var otherEndpoint = ""
    private var user = ""
    private var password = ""
    private var keys: URL!
    private var passphrase = ""
    private var publicRoot = ""
    private var hostFingerprint = ""
    private var localRoot: URL?
    private var hostKey = ""
    /// The destination folder the tests' folders are in: relative to the
    /// login folder or a full path.
    private var root = "aktar"
    private var otherHostKey = ""
    /// This test's folder under the destination folder `aktar`.
    private var folder = ""
    private var credentials = StorageCredentials(accessKeyId: "", secretAccessKey: "", sessionToken: nil)
    private var backend: SFTPBackend!
    private var directory: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["AKTAR_TEST_SFTP_ENDPOINT"],
              let user = environment["AKTAR_TEST_SFTP_USER"],
              let password = environment["AKTAR_TEST_SFTP_PASSWORD"],
              let keys = environment["AKTAR_TEST_SFTP_KEYS"] else {
            throw XCTSkip("AKTAR_TEST_SFTP_ENDPOINT, AKTAR_TEST_SFTP_USER, AKTAR_TEST_SFTP_PASSWORD and AKTAR_TEST_SFTP_KEYS aren't set (scripts/test-sftp.sh sets them)")
        }
        self.endpoint = endpoint
        self.user = user
        self.password = password
        self.keys = URL(fileURLWithPath: keys, isDirectory: true)
        otherEndpoint = environment["AKTAR_TEST_SFTP_OTHER_ENDPOINT"] ?? ""
        passphrase = environment["AKTAR_TEST_SFTP_PASSPHRASE"] ?? ""
        publicRoot = environment["AKTAR_TEST_SFTP_PUBLIC_URL"] ?? ""
        hostFingerprint = environment["AKTAR_TEST_SFTP_HOST_FINGERPRINT"] ?? ""
        localRoot = environment["AKTAR_TEST_SFTP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        hostKey = try String(contentsOf: self.keys.appendingPathComponent("host.pub"), encoding: .utf8)
        otherHostKey = try String(contentsOf: self.keys.appendingPathComponent("other-host.pub"), encoding: .utf8)
        root = environment["AKTAR_TEST_SFTP_ROOT"] ?? "aktar"
        credentials = StorageCredentials(accessKeyId: user, secretAccessKey: password.isEmpty ? try key("id_ed25519") : password, sessionToken: nil)
        folder = "run-\(UUID().uuidString.prefix(8).lowercased())"
        try await SFTPBackend(config: config(folder: root), credentials: credentials).createFolder(prefix: folder + "/")
        backend = SFTPBackend(config: config(), credentials: credentials)

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let localRoot, !folder.isEmpty {
            try? FileManager.default.removeItem(at: localRoot.appendingPathComponent(folder, isDirectory: true))
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        backend = nil
    }

    // MARK: - Connection and host keys

    func testConnection() async throws {
        let result = try await backend.testConnection()
        XCTAssertTrue(result.bucketReachable)
        XCTAssertTrue(result.writable)
        if !publicRoot.isEmpty {
            XCTAssertEqual(result.publicLink, .reachable)
        }
        let seen = try XCTUnwrap(result.sshHostKey)
        XCTAssertTrue(SSHHostKey.matches(seen, hostKey))
        if !hostFingerprint.isEmpty {
            // As `ssh-keygen -l` prints it.
            XCTAssertEqual(SSHHostKey.fingerprint(seen), hostFingerprint)
        }
        // The test file is cleaned up, and no part file is left.
        let listing = try await backend.list(prefix: "", continuationToken: nil)
        XCTAssertEqual(listing.objects, [])
        if let local = localRoot?.appendingPathComponent(folder) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), [])
        }

        // A full path works the same as one in the login folder.
        if !root.hasPrefix("/") {
            let absolute = try await SFTPBackend(config: config(folder: "/\(root)/\(folder)"), credentials: credentials).testConnection()
            XCTAssertTrue(absolute.writable)
        }
    }

    func testTrustOnFirstUse() async throws {
        let learned = LearnedKeys()
        let previous = SFTPBackend.hostKeyLearned
        SFTPBackend.hostKeyLearned = { id, endpoint, key in learned.add(id, endpoint, key) }
        defer { SFTPBackend.hostKeyLearned = previous }

        var unknown = config()
        unknown.id = UUID()
        unknown.sshHostKey = nil
        let fresh = SFTPBackend(config: unknown, credentials: credentials)
        try await fresh.putObject(data: Data("tofu".utf8), objectKey: "tofu.txt", contentType: "text/plain")
        let entries = learned.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.0, unknown.id)
        XCTAssertEqual(entries.first?.1, endpoint)
        XCTAssertTrue(SSHHostKey.matches(entries.first?.2 ?? "", hostKey))

        // Test Connection without a stored key shows the key it saw.
        let result = try await SFTPBackend(config: unknown, credentials: credentials).testConnection()
        XCTAssertTrue(SSHHostKey.matches(result.sshHostKey ?? "", hostKey))
    }

    /// The other server on the same folder has another host key: refused
    /// before signing in, for Test Connection and an upload alike.
    func testChangedHostKeyIsRefused() async throws {
        try XCTSkipIf(otherEndpoint.isEmpty, "AKTAR_TEST_SFTP_OTHER_ENDPOINT isn't set")
        var moved = config()
        moved.endpoint = otherEndpoint
        moved.sshHostKey = hostKey
        do {
            _ = try await SFTPBackend(config: moved, credentials: credentials).testConnection()
            XCTFail("A changed host key connected")
        } catch let change as SFTPHostKeyChanged {
            XCTAssertTrue(SSHHostKey.matches(change.stored, hostKey))
            XCTAssertTrue(SSHHostKey.matches(change.seen, otherHostKey))
            let message = change.errorDescription ?? ""
            XCTAssertTrue(message.contains(SSHHostKey.fingerprint(otherHostKey) ?? "-"), message)
        }
        let file = try write(Data("x".utf8), named: "x.txt")
        do {
            _ = try await SFTPBackend(config: moved, credentials: credentials).upload(fileURL: file, objectKey: "x.txt", contentType: "text/plain", progress: nil)
            XCTFail("A changed host key uploaded")
        } catch is SFTPHostKeyChanged {
        }
        // Trusting the new key (what saving after Test Connection does) works.
        moved.sshHostKey = otherHostKey
        let result = try await SFTPBackend(config: moved, credentials: credentials).testConnection()
        XCTAssertTrue(result.writable)
    }

    func testWrongPasswordMissingFolderAndNoServer() async throws {
        let wrong = StorageCredentials(accessKeyId: user, secretAccessKey: "wrong", sessionToken: nil)
        do {
            _ = try await SFTPBackend(config: config(), credentials: wrong).testConnection()
            XCTFail("A wrong password connected")
        } catch StorageError.sshAuthenticationFailed {
        }
        let file = try write(Data("x".utf8), named: "x.txt")
        do {
            _ = try await SFTPBackend(config: config(), credentials: wrong).upload(fileURL: file, objectKey: "x.txt", contentType: "text/plain", progress: nil)
            XCTFail("A wrong password uploaded")
        } catch StorageError.sshAuthenticationFailed {
        }
        do {
            _ = try await SFTPBackend(config: config(folder: "\(root)/no-such-folder-\(folder)"), credentials: credentials).testConnection()
            XCTFail("A missing folder connected")
        } catch StorageError.serverFolderNotFound {
        }
        // Nothing listens on port 9: refused, with the host in the message.
        var nowhere = config()
        nowhere.endpoint = "127.0.0.1:9"
        do {
            _ = try await SFTPBackend(config: nowhere, credentials: credentials).testConnection()
            XCTFail("Connected to nothing")
        } catch StorageError.network(let message) {
            XCTAssertTrue(message.contains("127.0.0.1:9"), message)
        }
    }

    // MARK: - Keys

    func testPrivateKeys() async throws {
        let cases: [(file: String, passphrase: String?)] = [
            ("id_ed25519", nil),
            ("id_ed25519_encrypted", passphrase),
            ("id_rsa", nil),
            ("id_rsa_encrypted", passphrase),
            ("id_rsa_pem", nil),
        ]
        for (index, keyCase) in cases.enumerated() {
            var keyCredentials = StorageCredentials(accessKeyId: user, secretAccessKey: try key(keyCase.file), sessionToken: nil)
            keyCredentials.keyPassphrase = keyCase.passphrase
            let keyBackend = SFTPBackend(config: config(), credentials: keyCredentials)
            let body = Data("signed in with \(keyCase.file)".utf8)
            try await keyBackend.putObject(data: body, objectKey: "keys/\(index).txt", contentType: "text/plain")
            let got = try await keyBackend.getObject(key: "keys/\(index).txt", maxBytes: 1024)
            XCTAssertEqual(got?.data, body, keyCase.file)
        }
    }

    func testEncryptedKeyPassphrase() async throws {
        let encrypted = try key("id_ed25519_encrypted")
        var missing = StorageCredentials(accessKeyId: user, secretAccessKey: encrypted, sessionToken: nil)
        do {
            _ = try await SFTPBackend(config: config(), credentials: missing).testConnection()
            XCTFail("An encrypted key without its passphrase connected")
        } catch StorageError.keyPassphrase {
        }
        missing.keyPassphrase = "not the passphrase"
        do {
            _ = try await SFTPBackend(config: config(), credentials: missing).testConnection()
            XCTFail("An encrypted key with a wrong passphrase connected")
        } catch StorageError.keyPassphrase {
        }
    }

    func testKeyNotInAuthorizedKeys() async throws {
        let other = directory.appendingPathComponent("stranger")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", other.path]
        try process.run()
        process.waitUntilExit()
        let stranger = StorageCredentials(accessKeyId: user, secretAccessKey: try String(contentsOf: other, encoding: .utf8), sessionToken: nil)
        do {
            _ = try await SFTPBackend(config: config(), credentials: stranger).testConnection()
            XCTFail("A key the server doesn't know signed in")
        } catch StorageError.sshAuthenticationFailed {
        }
    }

    // MARK: - Files

    func testSmallUploadIntoNestedFolders() async throws {
        let key = "2026/11/deep er/My Shot +1 %.txt"
        let body = Data("hello, sftp".utf8)
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
        let modified = try await backend.lastModified(key: key)
        XCTAssertLessThan(abs((modified ?? .distantPast).timeIntervalSinceNow), 600)
        // A folder isn't an object.
        let folderInfo = try await backend.objectInfo(key: "2026/11")
        XCTAssertNil(folderInfo)

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

        if !publicRoot.isEmpty {
            let (data, response) = try await URLSession.shared.data(from: try XCTUnwrap(result.publicURL))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, body)
        }
        if let local = localFile(key) {
            XCTAssertEqual(try Data(contentsOf: local), body)
            // Only the file: its part file was renamed onto it.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.deletingLastPathComponent().path), ["My Shot +1 %.txt"])
        }
    }

    func testBigUploadWithProgressAndDownload() async throws {
        let size = 20 * 1024 * 1024 + 12_345
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

        let reports = SFTPProgressLog()
        let started = ContinuousClock.now
        let result = try await backend.upload(fileURL: file, objectKey: "big/file.bin", contentType: "application/octet-stream") { value in
            reports.add(value)
        }
        let took = ContinuousClock.now - started
        XCTAssertEqual(result.byteSize, size)
        let info = try await backend.objectInfo(key: "big/file.bin")
        XCTAssertEqual(info?.size, Int64(size))
        try await Task.sleep(for: .milliseconds(200))
        let values = reports.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        // Reports come at most ten times a second; a fast server may be
        // done before the first one.
        if took > .milliseconds(500) {
            XCTAssertTrue(values.contains { $0 > 0 && $0 < 1 }, "No progress between 0 and 1: \(values.count) reports")
        }

        let downloaded = directory.appendingPathComponent("big-down.bin")
        let found = try await backend.download(key: "big/file.bin", to: downloaded, maxBytes: Int64(size))
        XCTAssertTrue(found)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: downloaded)), digest)
        // Over the cap: refused.
        do {
            _ = try await backend.download(key: "big/file.bin", to: downloaded, maxBytes: 1024)
            XCTFail("A file over maxBytes was downloaded")
        } catch {}
    }

    func testCancelledUploadLeavesNoPartFile() async throws {
        let local = try XCTUnwrap(localFile("cancel"), "AKTAR_TEST_SFTP_DIR isn't set")
        let file = directory.appendingPathComponent("cancel.bin")
        try Data(count: 40 * 1024 * 1024).write(to: file)
        let backend = backend!
        let started = SFTPProgressLog()
        let task = Task {
            try await backend.upload(fileURL: file, objectKey: "cancel/file.bin", contentType: "application/octet-stream") { started.add($0) }
        }
        for _ in 0..<200 where !started.values.contains(where: { $0 > 0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(300))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix(".aktar-part") }, "\(left)")
    }

    func testPutObjectReplacesAndHidesPartFiles() async throws {
        try await backend.putObject(data: Data("<p>one</p>".utf8), objectKey: "pages/a.html", contentType: "text/html")
        try await backend.putObject(data: Data("<p>two</p>".utf8), objectKey: "pages/a.html", contentType: "text/html", cacheControl: "public, max-age=60")
        let got = try await backend.getObject(key: "pages/a.html", maxBytes: 100)
        XCTAssertEqual(got.map { String(decoding: $0.data, as: UTF8.self) }, "<p>two</p>")
        do {
            _ = try await backend.getObject(key: "pages/a.html", maxBytes: 3)
            XCTFail("An object over maxBytes was read")
        } catch {}

        // Another upload's part file on its way isn't listed.
        if let local = localFile("pages/.b.html.aktar-part") {
            try Data("half".utf8).write(to: local)
            let listing = try await backend.list(prefix: "pages/", continuationToken: nil)
            XCTAssertEqual(listing.objects.map(\.key), ["pages/a.html"])
        }
    }

    func testKeysOutsideTheFolderAreRefused() async throws {
        for key in ["../escape.txt", "a/../../b.txt", "./x.txt", "a//b.txt"] {
            do {
                try await backend.putObject(data: Data("x".utf8), objectKey: key, contentType: "text/plain")
                XCTFail("\(key) was written")
            } catch {}
        }
    }

    // MARK: - Listing

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

        let partial = try await backend.list(prefix: "sub/deeper/t", continuationToken: nil)
        XCTAssertEqual(partial.objects.map(\.key), ["sub/deeper/three.txt", "sub/deeper/two.txt"])

        let none = try await backend.list(prefix: "nothing/", continuationToken: nil)
        XCTAssertEqual(none.objects, [])
        XCTAssertEqual(none.folders, [])

        let everything = try await allObjects(prefix: "")
        XCTAssertEqual(everything.objects, ["a.txt", "b c.txt", "other/four.txt", "sub/deeper/three.txt", "sub/deeper/two.txt", "sub/one.txt"])
        XCTAssertTrue(everything.folders.isSuperset(of: ["empty/", "empty/nested/", "sub/", "sub/deeper/", "other/"]))
    }

    // MARK: - Changing

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

    func testCopyMoveAndDelete() async throws {
        try await backend.putObject(data: Data("copy me".utf8), objectKey: "from/x y.txt", contentType: "text/plain")
        try await backend.copy(from: "from/x y.txt", to: "to/new folder/x y.txt")
        let copied = try await backend.getObject(key: "to/new folder/x y.txt", maxBytes: 100)
        XCTAssertEqual(copied?.data, Data("copy me".utf8))
        let source = try await backend.objectExists(key: "from/x y.txt")
        XCTAssertTrue(source)

        // Copying onto a file replaces it.
        try await backend.putObject(data: Data("other".utf8), objectKey: "to/other.txt", contentType: "text/plain")
        try await backend.copy(from: "from/x y.txt", to: "to/other.txt")
        let replaced = try await backend.getObject(key: "to/other.txt", maxBytes: 100)
        XCTAssertEqual(replaced?.data, Data("copy me".utf8))

        // A move is a rename on the server.
        XCTAssertTrue(backend.config.capabilities.rename)
        try await backend.move(from: "to/other.txt", to: "moved/here.txt")
        let moved = try await backend.getObject(key: "moved/here.txt", maxBytes: 100)
        XCTAssertEqual(moved?.data, Data("copy me".utf8))
        let oldGone = try await backend.objectExists(key: "to/other.txt")
        XCTAssertFalse(oldGone)

        try await backend.delete(objectKey: "from/x y.txt")
        let gone = try await backend.objectExists(key: "from/x y.txt")
        XCTAssertFalse(gone)
        try await backend.delete(objectKey: "from/x y.txt")

        try await backend.delete(objectKeys: ["to/new folder/x y.txt", "moved/here.txt", "never.txt"])
        let left = try await allObjects(prefix: "")
        XCTAssertEqual(left.objects, [])

        do {
            try await backend.copy(from: "missing.txt", to: "copy.txt")
            XCTFail("Copied a missing file")
        } catch {}
    }

    func testUploadAfterItsFolderWasDeleted() async throws {
        try await backend.putObject(data: Data("1".utf8), objectKey: "gone/a.txt", contentType: "text/plain")
        try await backend.delete(objectKey: "gone/a.txt")
        try await backend.delete(objectKey: "gone/")
        try await backend.putObject(data: Data("2".utf8), objectKey: "gone/b.txt", contentType: "text/plain")
        let exists = try await backend.objectExists(key: "gone/b.txt")
        XCTAssertTrue(exists)
    }

    func testFactoryAndOnlyIfNew() async throws {
        let made = StorageBackends.make(config: config(), credentials: credentials)
        XCTAssertTrue(made is SFTPBackend)
        let file = try write(Data("first".utf8), named: "f.txt")
        _ = try await made.upload(fileURL: file, objectKey: "short/Ab12.txt", contentType: "text/plain", onlyIfNew: true, progress: nil)
        do {
            _ = try await made.upload(fileURL: file, objectKey: "short/Ab12.txt", contentType: "text/plain", onlyIfNew: true, progress: nil)
            XCTFail("A taken key was written")
        } catch StorageError.alreadyExists {
        }
    }

    /// Many operations at once share the connection.
    func testConcurrentOperations() async throws {
        let backend = backend!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await backend.putObject(data: Data("n\(index)".utf8), objectKey: "many/\(index).txt", contentType: "text/plain")
                }
            }
            try await group.waitForAll()
        }
        let listing = try await backend.list(prefix: "many/", continuationToken: nil)
        XCTAssertEqual(listing.objects.count, 12)
    }

    // MARK: - Helpers

    private func config(folder: String? = nil) -> DestinationConfig {
        var config = DestinationConfig(
            name: "SFTP test",
            preset: .sftp,
            accountID: nil,
            endpoint: endpoint,
            region: "",
            bucket: folder ?? "\(root)/\(self.folder)",
            publicBaseURL: publicRoot.isEmpty ? "https://files.example.com" : "\(publicRoot)/\(self.folder)",
            objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: false,
            isDefault: false
        )
        config.sshHostKey = hostKey
        return config
    }

    private func key(_ name: String) throws -> String {
        try String(contentsOf: keys.appendingPathComponent(name), encoding: .utf8)
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

private final class SFTPProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [Double] = []

    var values: [Double] { lock.withLock { reported } }

    func add(_ value: Double) {
        lock.withLock { reported.append(value) }
    }
}

private final class LearnedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var learned: [(UUID, String, String)] = []

    var entries: [(UUID, String, String)] { lock.withLock { learned } }

    func add(_ id: UUID, _ endpoint: String, _ key: String) {
        lock.withLock { learned.append((id, endpoint, key)) }
    }
}
