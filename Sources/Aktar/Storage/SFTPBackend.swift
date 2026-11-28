import Foundation

/// A folder on an SSH server as a destination (docs/storage-backends.md,
/// "SFTP"): OpenSSH on a VPS, a Hetzner Storage Box, a Synology, `rclone
/// serve sftp`. The endpoint is the server (`host`, `host:port` or
/// `[v6]:port`), the bucket field is the folder on it, and a key is a path
/// under that folder. Links come from the Public Base URL, served by a web
/// server from the same folder.
///
/// The SSH and SFTP work is the SFTP core shared with the desktop app
/// (rust/sftp-core, called through the UniFFI bindings in
/// build/sftp-core/swift/AktarSFTP.swift): the connection pool (one SSH
/// connection per server and account, closed after a minute without use),
/// host key checks, sign-in, part files (`.<name>.aktar-part`, renamed
/// over the target once complete) and retries. This class is the app's
/// side of it: destinations and credentials in, the app's errors out.
final class SFTPBackend: StorageBackend, Sendable {
    let config: DestinationConfig
    private let credentials: StorageCredentials

    /// Told when a destination without a stored host key connected and
    /// trusted the key it saw (trust on first use), so the app can save it
    /// with the destination. Set once at launch.
    nonisolated(unsafe) static var hostKeyLearned: (@Sendable (_ destinationID: UUID, _ endpoint: String, _ hostKey: String) -> Void)?

    init(config: DestinationConfig, credentials: StorageCredentials) {
        self.config = config
        self.credentials = credentials
    }

    // MARK: - Test Connection

    /// Connects afresh (the host key is checked against the stored one),
    /// signs in, checks the folder and writes a test file, then the same
    /// public link check and delete as for S3. The host key it connected to
    /// comes back in the result; a changed one is `SFTPHostKeyChanged`,
    /// before signing in.
    func testConnection() async throws -> ConnectionResult {
        let client = try makeClient()
        let session: SftpTestSession
        do {
            session = try await client.testConnection()
        } catch {
            throw finalError(error, client: client)
        }
        let writable = session.writable()
        var publicLink: PublicLinkCheck?
        if writable, !config.publicBaseURL.isEmpty {
            if let url = publicURL(for: session.testKey()) {
                publicLink = await S3Provider.probe(url: url)
            } else {
                publicLink = .noResponse
            }
        }
        await session.finish()
        return ConnectionResult(bucketReachable: true, writable: writable, publicLink: publicLink, sshHostKey: session.hostKey())
    }

    // MARK: - Writing

    /// Streamed from the file through a part file; `onlyIfNew` leaves a
    /// file already at the key alone (`StorageError.alreadyExists`).
    /// Cancelling the task stops it and removes the part file.
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        onlyIfNew: Bool,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult {
        _ = try remotePath(objectKey)
        let size = try S3Provider.fileSize(of: fileURL)
        let client = try makeClient()
        await progress?(0)
        let sink = SFTPProgressSink(ProgressReporter(total: size, report: progress))
        let cancel = SftpCancel()
        try await withTaskCancellationHandler {
            do {
                _ = try await client.upload(path: fileURL.path, key: objectKey, onlyIfNew: onlyIfNew, progress: sink, cancel: cancel)
            } catch {
                throw finalError(error, client: client)
            }
        } onCancel: {
            cancel.cancel()
        }
        await progress?(1)
        guard let url = publicURL(for: objectKey) else {
            throw StorageError.invalidPublicBaseURL
        }
        return UploadResult(objectKey: objectKey, publicURL: url, byteSize: Int(size))
    }

    func putObject(data: Data, objectKey: String, contentType: String, cacheControl: String?) async throws {
        _ = try remotePath(objectKey)
        try await perform { try await $0.putBytes(key: objectKey, data: data) }
    }

    // MARK: - Reading

    func getObject(key: String, maxBytes: Int) async throws -> (data: Data, lastModified: Date?)? {
        _ = try remotePath(key)
        guard let file = try await perform({ try await $0.getSmall(key: key, maxBytes: UInt64(max(maxBytes, 0))) }) else { return nil }
        return (file.data, Self.date(file.lastModifiedMs))
    }

    /// Into a hidden file next to `destination`, moved over it once
    /// complete; false when there's no such file.
    func download(key: String, to destination: URL, maxBytes: Int64) async throws -> Bool {
        _ = try remotePath(key)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let client = try makeClient()
        let cancel = SftpCancel()
        let found = try await withTaskCancellationHandler {
            do {
                return try await client.download(key: key, path: temporary.path, maxBytes: UInt64(max(maxBytes, 0)), cancel: cancel)
            } catch {
                throw finalError(error, client: client)
            }
        } onCancel: {
            cancel.cancel()
        }
        guard found else { return false }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return true
    }

    func objectExists(key: String) async throws -> Bool {
        try await objectInfo(key: key) != nil
    }

    /// `stat`: the size and the modification time. A folder isn't an object.
    func objectInfo(key: String) async throws -> (size: Int64, lastModified: Date?)? {
        _ = try remotePath(key)
        guard let info = try await perform({ try await $0.info(key: key) }) else { return nil }
        return (info.size, Self.date(info.lastModifiedMs))
    }

    // MARK: - Listing

    /// One `readdir` of the folder `prefix` is in, keeping what starts with
    /// `prefix`. One page. A folder that isn't there lists as empty.
    func list(prefix: String, continuationToken: String?) async throws -> BucketListing {
        let folder = WebDAVBackend.folder(of: prefix)
        guard let entries = try await entries(in: folder) else {
            return BucketListing(prefix: prefix, folders: [], objects: [], nextContinuationToken: nil)
        }
        var folders: [String] = []
        var objects: [BucketObject] = []
        for entry in entries where entry.key.hasPrefix(prefix) && entry.key != prefix {
            if entry.isFolder {
                folders.append(entry.key)
            } else {
                objects.append(BucketObject(key: entry.key, size: entry.size, lastModified: entry.lastModified))
            }
        }
        return BucketListing(prefix: prefix, folders: folders.sorted(), objects: objects.sorted { $0.key < $1.key }, nextContinuationToken: nil)
    }

    /// Everything under `prefix`, one folder after another, as for WebDAV.
    func listRecursively(prefix: String, continuationToken: String?) async throws -> BucketListing {
        var pending = continuationToken.flatMap(Self.decodePending) ?? [WebDAVBackend.folder(of: prefix)]
        var folders: [String] = []
        var objects: [BucketObject] = []
        while !pending.isEmpty, objects.count < WebDAVBackend.recursivePageSize {
            let folder = pending.removeFirst()
            guard let entries = try await entries(in: folder) else { continue }
            for entry in entries {
                if entry.isFolder {
                    if entry.key.hasPrefix(prefix) {
                        folders.append(entry.key)
                        pending.append(entry.key)
                    } else if prefix.hasPrefix(entry.key) {
                        pending.append(entry.key)
                    }
                } else if entry.key.hasPrefix(prefix) {
                    objects.append(BucketObject(key: entry.key, size: entry.size, lastModified: entry.lastModified))
                }
            }
        }
        return BucketListing(prefix: prefix, folders: folders, objects: objects, nextContinuationToken: pending.isEmpty ? nil : Self.encodePending(pending))
    }

    struct Entry: Equatable {
        let key: String
        let isFolder: Bool
        let size: Int64
        let lastModified: Date?
    }

    /// The folder's contents as keys (`.`, `..` and part files left out, a
    /// link as what it points at); nil when there's no such folder.
    private func entries(in folder: String) async throws -> [Entry]? {
        if !folder.isEmpty { _ = try remotePath(String(folder.dropLast())) }
        let client = try makeClient()
        let listed: [SftpEntry]
        do {
            listed = try await client.list(prefix: folder)
        } catch SftpError.FolderNotFound {
            return nil
        } catch {
            throw finalError(error, client: client)
        }
        return listed.filter { Self.isListed($0.name) }.map { entry in
            Entry(
                key: folder + entry.name + (entry.isFolder ? "/" : ""),
                isFolder: entry.isFolder,
                size: entry.isFolder ? 0 : entry.size,
                lastModified: Self.date(entry.lastModifiedMs)
            )
        }
    }

    /// `.`, `..` and part files of uploads on their way aren't listed.
    static func isListed(_ name: String) -> Bool {
        guard name != ".", name != "..", !name.isEmpty, !name.contains("/") else { return false }
        return !sftpIsPartFile(name: name)
    }

    private static func encodePending(_ folders: [String]) -> String? {
        (try? JSONEncoder().encode(folders)).map { $0.base64EncodedString() }
    }

    private static func decodePending(_ token: String) -> [String]? {
        Data(base64Encoded: token).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    // MARK: - Changing

    /// `remove`; no such file counts as done. A folder key is removed with
    /// `rmdir` only when it's empty, as S3 leaves the files of a deleted
    /// folder placeholder.
    func delete(objectKey: String) async throws {
        let key = objectKey.hasSuffix("/") ? String(objectKey.dropLast()) : objectKey
        _ = try remotePath(key)
        try await perform { try await $0.delete(key: objectKey) }
    }

    func delete(objectKeys: [String]) async throws {
        for key in objectKeys {
            try await delete(objectKey: key)
        }
    }

    /// SFTP has no server-side copy: the file is read and written back
    /// through this Mac, into a part file like an upload.
    func copy(from sourceKey: String, to destinationKey: String) async throws {
        _ = try remotePath(sourceKey)
        _ = try remotePath(destinationKey)
        try await perform { try await $0.copy(source: sourceKey, destination: destinationKey) }
    }

    /// A rename on the server, replacing a file at the target
    /// (`posix-rename@openssh.com` where the server has it).
    func move(from sourceKey: String, to destinationKey: String) async throws {
        _ = try remotePath(sourceKey)
        _ = try remotePath(destinationKey)
        try await perform { try await $0.rename(source: sourceKey, destination: destinationKey) }
    }

    /// `mkdir` for the folder and each one above it.
    func createFolder(prefix: String) async throws {
        var path = prefix
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return }
        _ = try remotePath(path)
        try await perform { try await $0.createFolder(prefix: path + "/") }
    }

    func publicURL(for objectKey: String) -> URL? {
        PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: objectKey)
    }

    // MARK: - Paths

    /// The Folder as it's used in paths: trimmed, without a trailing `/`
    /// (but `/` itself stays). Empty is the login folder.
    static func basePath(_ folder: String) -> String {
        if let normalized = try? sftpNormalizeFolder(folder: folder) { return normalized }
        var base = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// The path on the server for `key` under the folder `base`:
    /// `<base>/<key>`. Keys with `.` or `..` parts, empty parts or a NUL
    /// are refused, so nothing lands outside the folder (the core refuses
    /// `..` itself; the app is stricter).
    static func path(for key: String, base: String) throws -> String {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !key.isEmpty, !key.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StorageError.unknown(String(localized: "This name can\u{2019}t be used on an SFTP server: \(key)"))
        }
        do {
            return try sftpRemotePath(base: base, key: key)
        } catch {
            throw StorageError.unknown(String(localized: "This name can\u{2019}t be used on an SFTP server: \(key)"))
        }
    }

    /// The folder itself for `stat` and `opendir`: `.` for the login folder.
    static func statPath(_ base: String) -> String {
        base.isEmpty ? "." : base
    }

    /// `<dir>/.<name>.aktar-part` next to `path`.
    static func partPath(for path: String) -> String {
        sftpPartPath(path: path)
    }

    private func remotePath(_ key: String) throws -> String {
        try Self.path(for: key, base: Self.basePath(config.bucket))
    }

    private static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    // MARK: - Client

    /// The core's client for this destination: where, who, and the host
    /// key to expect. One that can't be read is refused rather than taken
    /// as no key (which would trust any server).
    private func makeClient() throws -> SftpClient {
        guard SFTPAddress(config.endpoint) != nil else {
            throw StorageError.unknown(SFTPAddress.problem(with: config.endpoint) ?? "")
        }
        let id = config.id
        let endpoint = config.endpoint
        let listener = SFTPHostKeyListenerBox { hostKey in
            SFTPBackend.hostKeyLearned?(id, endpoint, hostKey)
        }
        let stored = try storedHostKey()
        do {
            return try SftpClient(
                config: SftpConfig(
                    endpoint: config.endpoint,
                    folder: config.bucket,
                    user: credentials.accessKeyId,
                    secret: credentials.secretAccessKey,
                    keyPassphrase: credentials.keyPassphrase,
                    hostKey: stored,
                    trustId: config.id.uuidString
                ),
                listener: listener
            )
        } catch {
            throw finalError(error, client: nil)
        }
    }

    private func storedHostKey() throws -> String? {
        guard let raw = config.sshHostKey, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let key = SSHHostKey.normalized(raw) else {
            throw StorageError.unknown(String(localized: "The saved server key can\u{2019}t be read. Run Test Connection again and save."))
        }
        return key
    }

    /// Runs `operation` on a client for this destination, with the core's
    /// errors in the app's words.
    private func perform<T>(_ operation: (SftpClient) async throws -> T) async throws -> T {
        let client = try makeClient()
        do {
            return try await operation(client)
        } catch {
            throw finalError(error, client: client)
        }
    }

    /// What an error says to the user, in the spec's words.
    private func finalError(_ error: Error, client: SftpClient?) -> Error {
        let address = SFTPAddress(config.endpoint)
        let server = client?.displayHost() ?? address.map { $0.port == 22 ? $0.host : "\($0.host):\($0.port)" } ?? config.endpoint
        return Self.appError(error, server: server, storedHostKey: config.sshHostKey)
    }

    /// The core's `SftpError` as the app's own: `StorageError`,
    /// `SFTPHostKeyChanged` or `CancellationError`. `server` is how the
    /// server is named in messages.
    static func appError(_ error: Error, server: String, storedHostKey: String? = nil) -> Error {
        guard let error = error as? SftpError else { return error }
        switch error {
        case .InvalidEndpoint:
            return StorageError.unknown(SFTPAddress.problem(with: "") ?? "")
        case .FolderHasParent:
            return StorageError.unknown(String(localized: "This name can\u{2019}t be used on an SFTP server: \("..")"))
        case .InvalidName(let name):
            return StorageError.unknown(String(localized: "This name can\u{2019}t be used on an SFTP server: \(name)"))
        case .AuthFailed:
            return StorageError.sshAuthenticationFailed
        case .KeyPassphrase:
            return StorageError.keyPassphrase
        case .UnsupportedKey(let name):
            return StorageError.unsupportedKey(SSHPrivateKey.displayName(ofType: name))
        case .UnreadableKey:
            return StorageError.unknown(String(localized: "The private key can\u{2019}t be read. Paste it in OpenSSH format, starting with -----BEGIN."))
        case .UnreadableHostKey:
            return StorageError.unknown(String(localized: "The saved server key can\u{2019}t be read. Run Test Connection again and save."))
        case .HostKeyChanged(let stored, let seen):
            return SFTPHostKeyChanged(stored: stored ?? storedHostKey ?? "", seen: seen ?? "")
        case .PermissionDenied:
            return StorageError.writeNotAllowed
        case .FolderNotFound(let path):
            return StorageError.serverFolderNotFound(path)
        case .FileNotFound:
            return StorageError.unknown(String(localized: "The file isn\u{2019}t on the server."))
        case .FileInTheWay(let folder):
            return StorageError.unknown(String(localized: "The server answered: \(folder)"))
        case .Refused(let host):
            return StorageError.network(String(localized: "\(host) refused the connection. Check the server and port."))
        case .Timeout(let host):
            return StorageError.network(String(localized: "\(host) didn\u{2019}t answer in time."))
        case .HostNotFound(let host):
            return StorageError.network(String(localized: "\(host) couldn\u{2019}t be found. Check the server name."))
        case .NoCommonAlgorithm(let host, let detail):
            return StorageError.network(String(localized: "The connection to \(host) failed: \(detail)"))
        case .NoSftp, .NoServerKey:
            return StorageError.network(String(localized: "The connection to \(server) failed."))
        case .Dropped:
            return StorageError.network(String(localized: "The connection to \(server) was lost."))
        case .ServerTimeout:
            return StorageError.network(String(localized: "\(server) didn\u{2019}t answer in time."))
        case .OutOfSpace:
            return StorageError.outOfSpace
        case .ServerAnswered(let message):
            return StorageError.unknown(String(localized: "The server answered: \(message)"))
        case .TooLarge:
            return StorageError.unknown("The object is too large.")
        case .AlreadyExists:
            return StorageError.alreadyExists
        case .Cancelled:
            return CancellationError()
        case .Local(let message):
            return StorageError.unknown(message)
        case .Other(let message):
            return StorageError.network(String(localized: "The connection to \(server) failed: \(message)"))
        }
    }
}

/// Counts an upload's bytes into the app's progress reporter.
private final class SFTPProgressSink: SftpProgress, @unchecked Sendable {
    private let reporter: ProgressReporter
    private let lock = NSLock()
    private var sent: Int64 = 0

    init(_ reporter: ProgressReporter) {
        self.reporter = reporter
    }

    func start(total: UInt64) {
        lock.withLock { sent = 0 }
        reporter.update(part: 0, sent: 0)
    }

    func advance(bytes: UInt64) {
        let now = lock.withLock {
            sent += Int64(bytes)
            return sent
        }
        reporter.update(part: 0, sent: now)
    }
}

/// Passes a host key learned on first use on to the app.
private final class SFTPHostKeyListenerBox: SftpHostKeyListener, @unchecked Sendable {
    private let onLearned: @Sendable (String) -> Void

    init(_ onLearned: @escaping @Sendable (String) -> Void) {
        self.onLearned = onLearned
    }

    func learned(hostKey: String) {
        onLearned(hostKey)
    }
}

/// The server showed another public key than the one stored for it.
struct SFTPHostKeyChanged: LocalizedError, Equatable {
    /// Both in OpenSSH format.
    let stored: String
    let seen: String

    var errorDescription: String? {
        let fingerprint = SSHHostKey.fingerprint(seen) ?? seen
        return String(localized: "The server\u{2019}s identity has changed (\(fingerprint)). If you expected this, run Test Connection again and save.")
    }
}

// MARK: - Server address

/// `host`, `host:port`, `[v6address]:port` or a bare IPv6 address; port 22
/// when left out. An `sftp://` in front is allowed, a path after it isn't.
struct SFTPAddress: Equatable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    init?(_ endpoint: String) {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sftp://") { text = String(text.dropFirst(7)) }
        while text.hasSuffix("/") { text.removeLast() }
        // The core tolerates a path after the server; the form doesn't.
        guard !text.isEmpty, !text.contains("/"), let parsed = try? sftpParseEndpoint(endpoint: text) else { return nil }
        self.host = parsed.host
        self.port = Int(parsed.port)
    }

    /// Nil when the Server field can be used.
    static func problem(with endpoint: String) -> String? {
        SFTPAddress(endpoint) == nil
            ? String(localized: "Enter the server as a host name, such as files.example.com or files.example.com:2222.")
            : nil
    }
}

// MARK: - Host keys

/// A server's public key in OpenSSH format and its fingerprint.
enum SSHHostKey {
    /// `type base64`, without a comment or extra spaces; nil when it isn't
    /// a key.
    static func normalized(_ key: String) -> String? {
        sftpNormalizeHostKey(hostKey: key)
    }

    /// `SHA256:` and the unpadded base64 of the key's SHA-256, as
    /// `ssh-keygen -l` prints it.
    static func fingerprint(_ key: String) -> String? {
        sftpFingerprint(hostKey: key)
    }

    /// The same key, whatever comment or spacing either has.
    static func matches(_ a: String, _ b: String) -> Bool {
        sftpSameHostKey(a: a, b: b)
    }
}

// MARK: - Private keys

/// A private key from `secretAccessKey`: OpenSSH format (ed25519, RSA or
/// ECDSA, encrypted or not) or old PEM RSA and EC keys (encrypted or not),
/// as the SFTP core reads them.
struct SSHPrivateKey: Equatable, Sendable {
    /// The SSH name of its type: `ssh-ed25519`, `ssh-rsa`,
    /// `ecdsa-sha2-nistp256`, ...
    let algorithm: String

    /// A value starting with `-----BEGIN` is a key; anything else is a password.
    static func looksLikeKey(_ secret: String) -> Bool {
        secret.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-----BEGIN")
    }

    /// Reads (and with `passphrase`, decrypts) the key as signing in will.
    static func parse(_ text: String, passphrase: String?) throws -> SSHPrivateKey {
        do {
            return SSHPrivateKey(algorithm: try sftpCheckPrivateKey(key: text, passphrase: passphrase))
        } catch {
            throw SFTPBackend.appError(error, server: "")
        }
    }

    /// The key type inside an OpenSSH private key (`ssh-ed25519`,
    /// `ssh-rsa`, `ecdsa-sha2-nistp256`, ...), read without its passphrase.
    static func keyType(ofOpenSSH key: String) throws -> String {
        do {
            return try sftpKeyInfo(key: key).algorithm
        } catch {
            throw SFTPBackend.appError(error, server: "")
        }
    }

    /// Whether the key is protected by a passphrase.
    static func isEncrypted(openSSH key: String) throws -> Bool {
        do {
            return try sftpKeyInfo(key: key).encrypted
        } catch {
            throw SFTPBackend.appError(error, server: "")
        }
    }

    static func displayName(ofType type: String) -> String {
        if type.hasPrefix("ecdsa") { return "ECDSA" }
        if type.hasPrefix("sk-") { return String(localized: "security key (\(type))") }
        if type == "ssh-dss" { return "DSA" }
        return type
    }
}
