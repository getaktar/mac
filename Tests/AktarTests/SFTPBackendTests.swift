import XCTest

/// The SFTP backend's pure parts (docs/storage-backends.md, "SFTP"): the
/// Server field, paths under the Folder, part files, host keys and their
/// fingerprints, private keys, and how SFTP destinations are stored and
/// transferred. The server itself is tested in SFTPIntegrationTests.
final class SFTPBackendTests: XCTestCase {
    // MARK: - Preset and capabilities

    func testPresetAndCapabilities() {
        XCTAssertEqual(ProviderPreset(rawValue: "sftp"), .sftp)
        XCTAssertEqual(ProviderPreset.sftp.kind, .sftp)
        XCTAssertEqual(ProviderPreset.sftp.displayName, "SFTP")
        XCTAssertEqual(ProviderPreset.sftp.defaultRegion, "")
        let capabilities = StorageCapabilities(preset: .sftp)
        XCTAssertTrue(capabilities.list)
        XCTAssertTrue(capabilities.copy)
        XCTAssertTrue(capabilities.rename)
        XCTAssertTrue(capabilities.bucketThumbnails)
        XCTAssertTrue(capabilities.sharePages)
        XCTAssertFalse(capabilities.temporaryLinks)
        XCTAssertFalse(capabilities.expiryRules)
        XCTAssertFalse(capabilities.fileRequests)
        XCTAssertFalse(capabilities.multipart)
        XCTAssertFalse(capabilities.conditionalWrites)
        XCTAssertFalse(capabilities.cloudflareSetup)
        // Only SFTP renames on the server.
        XCTAssertEqual(ProviderPreset.allCases.filter { StorageCapabilities(preset: $0).rename }, [.sftp])
    }

    func testFactoryMakesAnSFTPBackend() {
        let config = Self.destination()
        let backend = StorageBackends.make(config: config, credentials: StorageCredentials(accessKeyId: "me", secretAccessKey: "pw", sessionToken: nil))
        XCTAssertTrue(backend is SFTPBackend)
        XCTAssertNil(backend.s3(for: \.list))
        XCTAssertEqual(backend.publicURL(for: "2026/a b.png")?.absoluteString, "https://files.example.com/2026/a%20b.png")
    }

    func testStorageNames() {
        var config = Self.destination()
        XCTAssertEqual(config.storageRootName, "files")
        XCTAssertEqual(config.storageLocation, "files.example.com:2222/var/www/files")
        config.bucket = ""
        XCTAssertEqual(config.storageRootName, "files.example.com")
        XCTAssertEqual(config.storageLocation, "files.example.com:2222")
        config.bucket = "uploads"
        XCTAssertEqual(config.storageLocation, "files.example.com:2222/uploads")
    }

    // MARK: - Server and paths

    func testServerAddress() {
        XCTAssertEqual(SFTPAddress("files.example.com"), SFTPAddress(host: "files.example.com", port: 22))
        XCTAssertEqual(SFTPAddress(" files.example.com:2222 "), SFTPAddress(host: "files.example.com", port: 2222))
        XCTAssertEqual(SFTPAddress("sftp://files.example.com:23/"), SFTPAddress(host: "files.example.com", port: 23))
        XCTAssertEqual(SFTPAddress("[2001:db8::1]:2200"), SFTPAddress(host: "2001:db8::1", port: 2200))
        XCTAssertEqual(SFTPAddress("[::1]"), SFTPAddress(host: "::1", port: 22))
        XCTAssertEqual(SFTPAddress("2001:db8::1"), SFTPAddress(host: "2001:db8::1", port: 22), "a bare IPv6 address")
        XCTAssertEqual(SFTPAddress("192.168.1.5:22"), SFTPAddress(host: "192.168.1.5", port: 22))
        for bad in ["", "files.example.com:0", "files.example.com:70000", "files.example.com:abc", "me@files.example.com", "files.example.com/path", "[::1", "a b"] {
            XCTAssertNil(SFTPAddress(bad), bad)
            XCTAssertNotNil(SFTPAddress.problem(with: bad), bad)
        }
        XCTAssertNil(SFTPAddress.problem(with: "files.example.com"))
    }

    func testPathsUnderTheFolder() throws {
        XCTAssertEqual(SFTPBackend.basePath(" /var/www/files/ "), "/var/www/files")
        XCTAssertEqual(SFTPBackend.basePath("/"), "/")
        XCTAssertEqual(SFTPBackend.basePath("files//"), "files")
        XCTAssertEqual(SFTPBackend.basePath(""), "")

        XCTAssertEqual(try SFTPBackend.path(for: "2026/11/a b.png", base: "/var/www/files"), "/var/www/files/2026/11/a b.png")
        XCTAssertEqual(try SFTPBackend.path(for: "a.png", base: "files"), "files/a.png")
        XCTAssertEqual(try SFTPBackend.path(for: "a.png", base: "/"), "/a.png")
        XCTAssertEqual(try SFTPBackend.path(for: "a.png", base: ""), "a.png", "the login folder")
        for bad in ["../a.png", "a/../../b", "./a", "a//b", "", "a/", "a\u{0}b"] {
            XCTAssertThrowsError(try SFTPBackend.path(for: bad, base: "/srv"), bad)
        }

        XCTAssertEqual(SFTPBackend.statPath(""), ".")
        XCTAssertEqual(SFTPBackend.statPath("/srv"), "/srv")
    }

    func testPartFiles() {
        XCTAssertEqual(SFTPBackend.partPath(for: "/var/www/2026/a.png"), "/var/www/2026/.a.png.aktar-part")
        XCTAssertEqual(SFTPBackend.partPath(for: "a.png"), ".a.png.aktar-part")
        XCTAssertFalse(SFTPBackend.isListed(".a.png.aktar-part"))
        XCTAssertFalse(SFTPBackend.isListed("."))
        XCTAssertFalse(SFTPBackend.isListed(".."))
        XCTAssertTrue(SFTPBackend.isListed(".htaccess"))
        XCTAssertTrue(SFTPBackend.isListed("a.aktar-part"), "only Aktar's hidden part files are left out")
    }

    // MARK: - Host keys

    func testHostKeyFormatAndFingerprint() throws {
        let key = try Self.generateKey(type: "ed25519").publicKey
        let normalized = try XCTUnwrap(SSHHostKey.normalized(key))
        XCTAssertTrue(normalized.hasPrefix("ssh-ed25519 AAAA"))
        XCTAssertFalse(normalized.contains("aktar-test"), "the comment is dropped")
        XCTAssertEqual(SSHHostKey.fingerprint(key), try Self.keygenFingerprint(of: key))
        XCTAssertTrue(SSHHostKey.matches(key, "  " + normalized + "  other comment"))
        let other = try Self.generateKey(type: "ed25519").publicKey
        XCTAssertFalse(SSHHostKey.matches(key, other))
        XCTAssertNil(SSHHostKey.normalized("not a key"))
        XCTAssertNil(SSHHostKey.normalized("ssh-ed25519 !!!"))
        XCTAssertFalse(SSHHostKey.matches("junk", "junk"))
    }

    func testChangedHostKeyMessage() throws {
        let old = try Self.generateKey(type: "ed25519").publicKey
        let new = try Self.generateKey(type: "ed25519").publicKey
        let change = SFTPHostKeyChanged(stored: old, seen: new)
        let message = try XCTUnwrap(change.errorDescription)
        XCTAssertTrue(message.contains(try XCTUnwrap(SSHHostKey.fingerprint(new))), message)
        XCTAssertFalse(message.contains(try XCTUnwrap(SSHHostKey.fingerprint(old))), message)
    }

    // MARK: - Private keys

    func testPasswordsAndKeysAreToldApart() {
        XCTAssertFalse(SSHPrivateKey.looksLikeKey("hunter2"))
        XCTAssertFalse(SSHPrivateKey.looksLikeKey("ssh-ed25519 AAAA"))
        XCTAssertTrue(SSHPrivateKey.looksLikeKey("\n-----BEGIN OPENSSH PRIVATE KEY-----\n..."))
    }

    func testOpenSSHKeys() throws {
        let ed25519 = try Self.generateKey(type: "ed25519").privateKey
        XCTAssertEqual(try SSHPrivateKey.keyType(ofOpenSSH: ed25519), "ssh-ed25519")
        XCTAssertFalse(try SSHPrivateKey.isEncrypted(openSSH: ed25519))
        XCTAssertEqual(try SSHPrivateKey.parse(ed25519, passphrase: nil).algorithm, "ssh-ed25519")
        // Windows line ends, as a key pasted from there has.
        XCTAssertEqual(try SSHPrivateKey.parse(ed25519.replacingOccurrences(of: "\n", with: "\r\n"), passphrase: "").algorithm, "ssh-ed25519")

        let rsa = try Self.generateKey(type: "rsa").privateKey
        XCTAssertEqual(try SSHPrivateKey.keyType(ofOpenSSH: rsa), "ssh-rsa")
        XCTAssertEqual(try SSHPrivateKey.parse(rsa, passphrase: nil).algorithm, "ssh-rsa")

        let pem = try Self.generateKey(type: "rsa", pem: true).privateKey
        XCTAssertTrue(pem.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertEqual(try SSHPrivateKey.parse(pem, passphrase: nil).algorithm, "ssh-rsa")

        let ecdsa = try Self.generateKey(type: "ecdsa").privateKey
        XCTAssertEqual(try SSHPrivateKey.keyType(ofOpenSSH: ecdsa), "ecdsa-sha2-nistp256")
        XCTAssertEqual(SSHPrivateKey.displayName(ofType: "ecdsa-sha2-nistp256"), "ECDSA")
        XCTAssertEqual(try SSHPrivateKey.parse(ecdsa, passphrase: nil).algorithm, "ecdsa-sha2-nistp256")
    }

    func testEncryptedKeys() throws {
        let key = try Self.generateKey(type: "ed25519", passphrase: "correct horse").privateKey
        XCTAssertTrue(try SSHPrivateKey.isEncrypted(openSSH: key))
        XCTAssertEqual(try SSHPrivateKey.keyType(ofOpenSSH: key), "ssh-ed25519", "the type is readable without the passphrase")
        XCTAssertThrowsError(try SSHPrivateKey.parse(key, passphrase: nil)) { error in
            guard case StorageError.keyPassphrase = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SSHPrivateKey.parse(key, passphrase: "wrong")) { error in
            guard case StorageError.keyPassphrase = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try SSHPrivateKey.parse(key, passphrase: "correct horse").algorithm, "ssh-ed25519")

        // Old encrypted PEM keys are read too.
        let pem = try Self.generateKey(type: "rsa", passphrase: "pem-phrase", pem: true).privateKey
        XCTAssertThrowsError(try SSHPrivateKey.parse(pem, passphrase: nil)) { error in
            guard case StorageError.keyPassphrase = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try SSHPrivateKey.parse(pem, passphrase: "pem-phrase").algorithm, "ssh-rsa")
    }

    func testUnreadableKeys() throws {
        for text in ["-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----"] {
            XCTAssertThrowsError(try SSHPrivateKey.parse(text, passphrase: nil)) { error in
                XCTAssertNotNil((error as? StorageError)?.errorDescription, "\(error)")
            }
        }
        XCTAssertEqual(SSHPrivateKey.displayName(ofType: "ssh-dss"), "DSA")
        XCTAssertTrue((StorageError.unsupportedKey("DSA").errorDescription ?? "").contains("DSA"))
    }

    func testCoreErrorsInTheAppsWords() {
        func message(_ error: SftpError) -> String {
            (SFTPBackend.appError(error, server: "files.example.com:2222") as? LocalizedError)?.errorDescription ?? ""
        }
        guard case StorageError.sshAuthenticationFailed = SFTPBackend.appError(SftpError.AuthFailed, server: "x") else { return XCTFail("auth") }
        guard case StorageError.writeNotAllowed = SFTPBackend.appError(SftpError.PermissionDenied, server: "x") else { return XCTFail("permission") }
        guard case StorageError.serverFolderNotFound("/srv") = SFTPBackend.appError(SftpError.FolderNotFound(path: "/srv"), server: "x") else { return XCTFail("folder") }
        guard case StorageError.outOfSpace = SFTPBackend.appError(SftpError.OutOfSpace, server: "x") else { return XCTFail("space") }
        XCTAssertTrue(SFTPBackend.appError(SftpError.Cancelled, server: "x") is CancellationError)
        XCTAssertTrue(message(.Refused(host: "files.example.com:2222")).contains("files.example.com:2222"))
        XCTAssertTrue(message(.Dropped(message: "reset")).contains("files.example.com:2222"))
        let changed = SFTPBackend.appError(SftpError.HostKeyChanged(stored: "a", seen: "b"), server: "x") as? SFTPHostKeyChanged
        XCTAssertEqual(changed, SFTPHostKeyChanged(stored: "a", seen: "b"))
    }

    // MARK: - Stored and transferred

    func testHostKeyAndPassphraseAreStored() throws {
        var config = Self.destination()
        config.sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKey"
        let decoded = try JSONDecoder().decode(DestinationConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.sshHostKey, config.sshHostKey)
        XCTAssertEqual(decoded.bucket, "/var/www/files")

        // An odd value is dropped rather than the destination.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["sshHostKey"] = 42
        let lenient = try JSONDecoder().decode(DestinationConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(lenient.sshHostKey)

        var credentials = StorageCredentials(accessKeyId: "me", secretAccessKey: "-----BEGIN OPENSSH PRIVATE KEY-----", sessionToken: nil)
        credentials.keyPassphrase = "phrase"
        let stored = try JSONDecoder().decode(StorageCredentials.self, from: JSONEncoder().encode(credentials))
        XCTAssertEqual(stored.keyPassphrase, "phrase")
        let old = try JSONDecoder().decode(StorageCredentials.self, from: Data(#"{"accessKeyId":"a","secretAccessKey":"b"}"#.utf8))
        XCTAssertNil(old.keyPassphrase)
    }

    func testTransferAsVersion2WithHostKey() throws {
        let hostKey = try Self.generateKey(type: "ed25519").publicKey
        var config = Self.destination()
        config.sshHostKey = hostKey
        var credentials = StorageCredentials(accessKeyId: "deploy", secretAccessKey: try Self.generateKey(type: "ed25519", passphrase: "p").privateKey, sessionToken: nil)
        credentials.keyPassphrase = "p"
        let payload = DestinationTransfer.Payload(destination: config, credentials: credentials, customTemplate: nil)
        XCTAssertEqual(DestinationTransfer.formatVersion(for: config), 2)

        let plaintext = try DestinationTransfer.encodePayload(payload)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(root["v"] as? Int, 2)
        let sent = try XCTUnwrap(root["destination"] as? [String: Any])
        XCTAssertEqual(sent["preset"] as? String, "sftp")
        XCTAssertEqual(sent["bucket"] as? String, "/var/www/files")
        XCTAssertEqual(sent["sshHostKey"] as? String, SSHHostKey.normalized(hostKey))
        XCTAssertEqual((root["credentials"] as? [String: Any])?["keyPassphrase"] as? String, "p")

        let decoded = try DestinationTransfer.decodePayload(plaintext)
        XCTAssertEqual(decoded.destination.kind, .sftp)
        XCTAssertEqual(decoded.destination.endpoint, "files.example.com:2222")
        XCTAssertEqual(decoded.destination.bucket, "/var/www/files")
        XCTAssertEqual(decoded.destination.sshHostKey, SSHHostKey.normalized(hostKey))
        XCTAssertEqual(decoded.credentials.secretAccessKey, credentials.secretAccessKey)
        XCTAssertEqual(decoded.credentials.keyPassphrase, "p")

        // Sealed and opened again.
        let code = DestinationTransfer.generateCode()
        let link = try DestinationTransfer.seal(payload, code: DestinationTransfer.normalizeCode(code)!)
        let opened = try DestinationTransfer.open(link, code: code)
        XCTAssertEqual(opened.destination.sshHostKey, SSHHostKey.normalized(hostKey))

        // An empty Folder (the login folder) is fine too.
        config.bucket = ""
        let empty = try DestinationTransfer.decodePayload(DestinationTransfer.encodePayload(.init(destination: config, credentials: credentials, customTemplate: nil)))
        XCTAssertEqual(empty.destination.bucket, "")
    }

    // MARK: - Helpers

    private static func destination() -> DestinationConfig {
        DestinationConfig(
            id: UUID(uuidString: "6E0F5E1A-7C0B-4B57-9D7A-3C1F0E6A5B21")!,
            name: "VPS",
            preset: .sftp,
            accountID: nil,
            endpoint: "files.example.com:2222",
            region: "",
            bucket: "/var/www/files",
            publicBaseURL: "https://files.example.com",
            objectPathTemplate: "{year}/{short}.{ext}",
            forcePathStyle: false,
            isDefault: false
        )
    }

    /// A key pair made by `ssh-keygen`, as text.
    static func generateKey(type: String, passphrase: String = "", pem: Bool = false) throws -> (privateKey: String, publicKey: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPBackendTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("key")
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", "aktar-test", "-f", file.path]
        if type == "rsa" { arguments += ["-b", "2048"] }
        if pem { arguments += ["-m", "PEM"] }
        try run("/usr/bin/ssh-keygen", arguments)
        return (try String(contentsOf: file, encoding: .utf8), try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8))
    }

    /// What `ssh-keygen -l` prints as the fingerprint of `publicKey`.
    static func keygenFingerprint(of publicKey: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SFTPBackendTests-\(UUID().uuidString).pub")
        try publicKey.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path])
        return String(output.split(separator: " ")[1])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ssh-keygen", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self)
    }
}
