import Foundation

/// A WebDAV server as a destination (docs/storage-backends.md, "WebDAV"):
/// Nextcloud, ownCloud, Synology, a Hetzner Storage Box, Apache or nginx
/// with DAV, `rclone serve webdav`. The endpoint is the folder uploads go
/// into, a key is a path under it, and every request carries the user name
/// and password as Basic authentication.
///
/// Files go up in one PUT streamed from disk, however big: WebDAV has no
/// multipart uploads to resume. Redirects are never followed for a write,
/// and a read only follows one to the same server, so the password can't
/// end up somewhere else.
final class WebDAVBackend: StorageBackend, Sendable {
    let config: DestinationConfig
    private let credentials: StorageCredentials
    /// Folders known to be there already, so an upload into a folder that
    /// earlier uploads made doesn't ask for it again.
    private let knownFolders = FolderSet()

    init(config: DestinationConfig, credentials: StorageCredentials) {
        self.config = config
        self.credentials = credentials
    }

    // MARK: - Test Connection

    /// PROPFIND on the folder itself (401: wrong user name or password,
    /// 404: no such folder), then the same test upload, public link check
    /// and delete as for S3.
    func testConnection() async throws -> ConnectionResult {
        let (data, response) = try await send(try request("PROPFIND", url: try folderURL(""), headers: ["Depth": "0"], body: Self.propfindBody))
        try check(response, data: data, onEndpoint: true)

        let testKey = "_aktar_test_\(UUID().uuidString.prefix(8)).txt"
        var writable = false
        do {
            try await putObject(data: Data("aktar connection test".utf8), objectKey: testKey, contentType: "text/plain", cacheControl: nil)
            writable = true
        } catch {
            writable = false
        }

        var publicLink: PublicLinkCheck?
        if writable, !config.publicBaseURL.isEmpty {
            if let url = publicURL(for: testKey) {
                publicLink = await S3Provider.probe(url: url)
            } else {
                publicLink = .noResponse
            }
        }

        if writable {
            try? await delete(objectKey: testKey)
        }
        return ConnectionResult(bucketReachable: true, writable: writable, publicLink: publicLink)
    }

    // MARK: - Writing

    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        onlyIfNew: Bool,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult {
        let size = try S3Provider.fileSize(of: fileURL)
        // WebDAV has no conditional writes Aktar relies on, so a caller
        // asking for one anyway gets the same answer from a check first.
        if onlyIfNew, try await objectExists(key: objectKey) {
            throw StorageError.alreadyExists
        }
        await progress?(0)
        let reporter = ProgressReporter(total: size, report: progress)
        try await createParents(of: objectKey)
        try await withRetries {
            reporter.update(part: 0, sent: 0)
            let request = try request("PUT", url: try self.fileURL(objectKey), headers: writeHeaders(contentType: contentType, cacheControl: nil))
            let delegate = TaskDelegate(followsRedirects: false) { sent in reporter.update(part: 0, sent: sent) }
            let (data, response) = try await Self.session.upload(for: request, fromFile: fileURL, delegate: delegate)
            try check(response, data: data)
        }
        await progress?(1)
        guard let url = publicURL(for: objectKey) else {
            throw StorageError.invalidPublicBaseURL
        }
        return UploadResult(objectKey: objectKey, publicURL: url, byteSize: Int(size))
    }

    func putObject(data: Data, objectKey: String, contentType: String, cacheControl: String?) async throws {
        try await createParents(of: objectKey)
        try await withRetries {
            let request = try request("PUT", url: try fileURL(objectKey), headers: writeHeaders(contentType: contentType, cacheControl: cacheControl))
            let (body, response) = try await Self.session.upload(for: request, from: data, delegate: TaskDelegate(followsRedirects: false))
            try check(response, data: body)
        }
    }

    /// `cacheControl` replaces the destination's own short cache time.
    private func writeHeaders(contentType: String, cacheControl: String?) -> [String: String] {
        var headers = ["Content-Type": contentType]
        if let cacheControl = cacheControl ?? (config.shortCache == true ? "public, max-age=60" : nil) {
            headers["Cache-Control"] = cacheControl
        }
        return headers
    }

    /// MKCOL for each folder above `key` that isn't known to be there, top
    /// down. 405 is the answer for one that already exists.
    private func createParents(of key: String) async throws {
        for folder in Self.parentFolders(of: key) where !knownFolders.contains(folder) {
            try await makeFolder(folder)
        }
    }

    private func makeFolder(_ folder: String) async throws {
        try await withRetries {
            let (data, response) = try await send(try request("MKCOL", url: try folderURL(folder)), followsRedirects: false)
            guard let http = response as? HTTPURLResponse else { throw Transient(message: String(localized: "The server didn\u{2019}t answer.")) }
            if http.statusCode != 405 { try check(response, data: data) }
        }
        knownFolders.insert(folder)
    }

    // MARK: - Reading

    func getObject(key: String, maxBytes: Int) async throws -> (data: Data, lastModified: Date?)? {
        try await withRetries {
            let (data, response) = try await send(try request("GET", url: try fileURL(key)))
            if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
            let http = try check(response, data: data)
            guard data.count <= maxBytes else { throw StorageError.unknown("The object is too large.") }
            return (data, http.value(forHTTPHeaderField: "Last-Modified").flatMap(WebDAVListing.date))
        }
    }

    func download(key: String, to destination: URL, maxBytes: Int64) async throws -> Bool {
        try await withRetries {
            let request = try request("GET", url: try fileURL(key))
            let (location, response) = try await Self.session.download(for: request, delegate: TaskDelegate(followsRedirects: true, origin: request.url))
            defer { try? FileManager.default.removeItem(at: location) }
            if (response as? HTTPURLResponse)?.statusCode == 404 { return false }
            try check(response, data: Data())
            guard try S3Provider.fileSize(of: location) <= maxBytes else {
                throw StorageError.unknown("The object is too large.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return true
        }
    }

    func objectExists(key: String) async throws -> Bool {
        try await objectInfo(key: key) != nil
    }

    /// HEAD: the size from Content-Length, the date from Last-Modified.
    func objectInfo(key: String) async throws -> (size: Int64, lastModified: Date?)? {
        try await withRetries {
            // Uncompressed: a server that would gzip the file (rclone does
            // for text) gives the compressed size as the Content-Length.
            let (data, response) = try await send(try request("HEAD", url: try fileURL(key), headers: ["Accept-Encoding": "identity"]))
            if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
            let http = try check(response, data: data)
            let size = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? max(0, response.expectedContentLength)
            return (size, http.value(forHTTPHeaderField: "Last-Modified").flatMap(WebDAVListing.date))
        }
    }

    // MARK: - Listing

    /// One PROPFIND with `Depth: 1` on the folder `prefix` is in, keeping
    /// what starts with `prefix` (S3 lists by any prefix, not only whole
    /// folders). One page: WebDAV has no continuation. A folder that isn't
    /// there lists as empty, like a prefix nothing has on S3.
    func list(prefix: String, continuationToken: String?) async throws -> BucketListing {
        let folder = Self.folder(of: prefix)
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

    /// Everything under `prefix`, listing one folder after another (servers
    /// often refuse `Depth: infinity`). The continuation token holds the
    /// folders still to list; a page ends after about 1000 files.
    func listRecursively(prefix: String, continuationToken: String?) async throws -> BucketListing {
        var pending = continuationToken.flatMap(Self.decodePending) ?? [Self.folder(of: prefix)]
        var folders: [String] = []
        var objects: [BucketObject] = []
        while !pending.isEmpty, objects.count < Self.recursivePageSize {
            let folder = pending.removeFirst()
            guard let entries = try await entries(in: folder) else { continue }
            for entry in entries {
                if entry.isFolder {
                    // A folder above `prefix` (when it ends mid-name) is
                    // only walked through, not listed.
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

    static let recursivePageSize = 1000

    /// The folder's contents, without itself; nil when there's no such
    /// folder.
    private func entries(in folder: String) async throws -> [WebDAVListing.Entry]? {
        try await withRetries {
            let url = try folderURL(folder)
            let (data, response) = try await send(try request("PROPFIND", url: url, headers: ["Depth": "1"], body: Self.propfindBody))
            if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
            try check(response, data: data)
            guard let entries = WebDAVListing.entries(in: data, endpointPath: baseComponents()?.percentEncodedPath ?? "", folder: folder) else {
                throw StorageError.unknown(String(localized: "The server\u{2019}s list of files couldn\u{2019}t be read."))
            }
            return entries
        }
    }

    /// A pending folder list as one opaque string.
    private static func encodePending(_ folders: [String]) -> String? {
        (try? JSONEncoder().encode(folders)).map { $0.base64EncodedString() }
    }

    private static func decodePending(_ token: String) -> [String]? {
        Data(base64Encoded: token).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    // MARK: - Changing

    /// 404 counts as deleted.
    func delete(objectKey: String) async throws {
        // On S3 deleting a folder key only drops its placeholder and the
        // files stay. A WebDAV DELETE on a folder takes everything in it,
        // so a folder is only deleted when it's already empty.
        if objectKey.hasSuffix("/") {
            let listing = try await list(prefix: objectKey, continuationToken: nil)
            guard listing.folders.isEmpty, listing.objects.isEmpty else { return }
        }
        try await withRetries {
            let url = objectKey.hasSuffix("/") ? try folderURL(objectKey) : try fileURL(objectKey)
            let (data, response) = try await send(try request("DELETE", url: url), followsRedirects: false)
            if (response as? HTTPURLResponse)?.statusCode == 404 { return }
            try check(response, data: data)
        }
        if objectKey.hasSuffix("/") { knownFolders.removeAll() }
    }

    /// One at a time: WebDAV has no batch delete.
    func delete(objectKeys: [String]) async throws {
        for key in objectKeys {
            try await delete(objectKey: key)
        }
    }

    /// COPY on the server, after the target's folders are made.
    func copy(from sourceKey: String, to destinationKey: String) async throws {
        try await createParents(of: destinationKey)
        let target = try fileURL(destinationKey)
        try await withRetries {
            let request = try request("COPY", url: try fileURL(sourceKey), headers: ["Destination": target.absoluteString, "Overwrite": "T"])
            let (data, response) = try await send(request, followsRedirects: false)
            try check(response, data: data)
        }
    }

    /// MKCOL for the folder and each one above it.
    func createFolder(prefix: String) async throws {
        var path = prefix
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return }
        for folder in Self.parentFolders(of: path + "/x") where !knownFolders.contains(folder) {
            try await makeFolder(folder)
        }
    }

    func publicURL(for objectKey: String) -> URL? {
        PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: objectKey)
    }

    // MARK: - Addresses

    /// The rule for a Server URL: `https://`, or `http://` only on this
    /// Mac (`localhost`, `127.0.0.1`, `::1`), since the password goes with
    /// every request. A bare host counts as `https://`. Nil when it's fine.
    static func problem(withServerURL serverURL: String) -> String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = components(trimmed), let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.query == nil, components.fragment == nil, components.user == nil else {
            return String(localized: "Enter the folder\u{2019}s full address, such as https://cloud.example.com/remote.php/dav/files/me/aktar.")
        }
        switch components.scheme?.lowercased() {
        case "https":
            return nil
        case "http" where ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()):
            return nil
        default:
            return String(localized: "The Server URL has to start with https://. Only localhost can use http://.")
        }
    }

    /// `endpoint` as URL parts, `https://` added to a bare host and spaces
    /// or other characters a URL can't hold encoded.
    private static func components(_ endpoint: String) -> URLComponents? {
        let address = endpoint.contains("://") ? endpoint : "https://\(endpoint)"
        if let components = URLComponents(string: address) { return components }
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%#"))
        return address.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URLComponents.init(string:))
    }

    /// The endpoint without a trailing slash, or nil when it breaks the
    /// Server URL rule.
    private func baseComponents() -> URLComponents? {
        guard Self.problem(withServerURL: config.endpoint) == nil,
              var components = Self.components(config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components
    }

    /// The address of the file at `key` under the endpoint.
    func fileURL(_ key: String) throws -> URL {
        guard var components = baseComponents() else { throw Self.invalidServerURL }
        components.percentEncodedPath += "/" + Self.encodeKey(key)
        guard let url = components.url else { throw Self.invalidServerURL }
        return url
    }

    /// The address of the folder `folder` ("" for the endpoint itself, or
    /// "a/b/"), with a trailing slash: servers redirect a folder without
    /// one, and a redirect isn't followed for writes.
    func folderURL(_ folder: String) throws -> URL {
        guard var components = baseComponents() else { throw Self.invalidServerURL }
        var path = folder
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath += "/" + (path.isEmpty ? "" : Self.encodeKey(path) + "/")
        guard let url = components.url else { throw Self.invalidServerURL }
        return url
    }

    private static var invalidServerURL: StorageError {
        .unknown(problem(withServerURL: "") ?? "")
    }

    /// Each `/`-separated part of `key` percent-encoded, keeping only RFC
    /// 3986's unreserved characters as they are, so a `+`, `#`, `?` or `%`
    /// in a file name is never read as anything else.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// "a/b/c.png" -> ["a/", "a/b/"].
    static func parentFolders(of key: String) -> [String] {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).dropLast()
        var folders: [String] = []
        var running = ""
        for part in parts where !part.isEmpty {
            running += part + "/"
            folders.append(running)
        }
        return folders
    }

    /// The folder a prefix lists in: "a/b/" for "a/b/" and "a/b/fo", ""
    /// for "fo".
    static func folder(of prefix: String) -> String {
        guard let slash = prefix.lastIndex(of: "/") else { return "" }
        return String(prefix[...slash])
    }

    // MARK: - Requests

    static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """.utf8)

    private func request(_ method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let login = Data("\(credentials.accessKeyId):\(credentials.secretAccessKey)".utf8).base64EncodedString()
        request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Reads follow a redirect to the same server; writes follow none.
    private func send(_ request: URLRequest, followsRedirects: Bool = true) async throws -> (Data, URLResponse) {
        try await Self.session.data(for: request, delegate: TaskDelegate(followsRedirects: followsRedirects, origin: request.url))
    }

    /// The response, when it's a success. 5xx (but 507) and 429 are thrown
    /// as `Transient`, for `withRetries`.
    @discardableResult
    private func check(_ response: URLResponse, data: Data, onEndpoint: Bool = false) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw Transient(message: String(localized: "The server didn\u{2019}t answer."))
        }
        if let error = Self.error(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"), onEndpoint: onEndpoint) {
            throw error
        }
        return http
    }

    /// What a status means, nil for a success (docs/storage-backends.md:
    /// 401 and 403, 404 on the endpoint, 507, 3xx naming where it points).
    static func error(status: Int, location: String?, onEndpoint: Bool) -> Error? {
        switch status {
        case 200..<300:
            return nil
        case 300..<400:
            let target = location ?? ""
            return StorageError.unknown(String(localized: "The server sent this to another address (\(target)). Use that address as the Server URL."))
        case 401:
            return StorageError.wrongUserNameOrPassword
        case 403:
            return StorageError.writeNotAllowed
        case 404 where onEndpoint:
            return StorageError.folderNotFound
        case 507:
            return StorageError.outOfSpace
        case 429, 500..<600:
            return Transient(message: String(localized: "The server answered with HTTP \(status)."))
        default:
            return StorageError.unknown(String(localized: "The server answered with HTTP \(status)."))
        }
    }

    /// Runs `operation` again after each of S3's retry delays while it
    /// fails in a way that might pass.
    private func withRetries<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < S3Provider.retryDelays.count, error is Transient || S3Provider.isTransient(error) else {
                    throw Self.finalError(error)
                }
                try await Task.sleep(for: .seconds(S3Provider.retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    private static func finalError(_ error: Error) -> Error {
        if let transient = error as? Transient { return StorageError.network(transient.message) }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return StorageError.network(urlError.localizedDescription)
        }
        return error
    }

    /// No cookies, no stored passwords and no cache: every request carries
    /// its own Basic authentication. 60 seconds without a byte per request;
    /// a big body takes as long as it needs.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}

/// A failure that may pass: a 5xx or 429.
private struct Transient: Error {
    let message: String
}

/// Upload progress, and the redirect rule: none for writes, and for reads
/// only one to the same scheme, host and port (URLSession would otherwise
/// send the Authorization header along wherever the server points).
private final class TaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followsRedirects: Bool
    let origin: URL?
    let onProgress: (@Sendable (Int64) -> Void)?

    init(followsRedirects: Bool, origin: URL? = nil, onProgress: (@Sendable (Int64) -> Void)? = nil) {
        self.followsRedirects = followsRedirects
        self.origin = origin
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard followsRedirects, let origin, let target = request.url, Self.sameOrigin(origin, target) else {
            // The 3xx itself comes back, and is reported with its Location.
            return completionHandler(nil)
        }
        var redirected = request
        if let original = task.originalRequest {
            for name in ["Authorization", "Depth", "Content-Type"] {
                if let value = original.value(forHTTPHeaderField: name) { redirected.setValue(value, forHTTPHeaderField: name) }
            }
            if redirected.httpMethod == "PROPFIND" { redirected.httpBody = original.httpBody }
        }
        completionHandler(redirected)
    }

    /// Basic authentication is sent up front, so a 401 is an answer to
    /// report, not a question for the Keychain.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate:
            completionHandler(.rejectProtectionSpace, nil)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
    }
}

/// Folder keys, thread-safe.
private final class FolderSet: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: Set<String> = []

    func contains(_ folder: String) -> Bool {
        lock.withLock { folders.contains(folder) }
    }

    func insert(_ folder: String) {
        lock.withLock { _ = folders.insert(folder) }
    }

    func removeAll() {
        lock.withLock { folders.removeAll() }
    }
}

/// A PROPFIND reply (a 207 multistatus) as keys under the endpoint.
/// Element names are matched by their local name in the `DAV:` namespace,
/// whatever prefix the server picked (`d:`, `D:`, `lp1:`, none).
enum WebDAVListing {
    struct Entry: Equatable {
        /// The key under the endpoint; a folder's ends with "/".
        let key: String
        let isFolder: Bool
        let size: Int64
        let lastModified: Date?
    }

    /// The entries of the folder `folder` ("" or "a/b/") under an endpoint
    /// whose path is `endpointPath` (percent-encoded or not), without the
    /// folder's own; nil when `data` isn't a multistatus. An href is an
    /// absolute URL or path, encoded or not: decoded, the endpoint's path
    /// is taken off and the rest is the key. When a server (behind a proxy,
    /// say) answers with paths under another root, the folder's own entry
    /// tells where its children start instead.
    static func entries(in data: Data, endpointPath: String, folder: String) -> [Entry]? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse(), reader.isMultistatus else { return nil }

        let base = trimmedSlashes(decoded(endpointPath))
        let folderPath = trimmedSlashes(folder)
        let ownPath = [base, folderPath].filter { !$0.isEmpty }.joined(separator: "/")
        let responses = reader.responses.map { response -> (path: String, response: Reader.Response) in
            (trimmedSlashes(decoded(path(ofHref: response.href))), response)
        }
        // Where the folder's children start: its path under the endpoint,
        // or else the shortest href in the reply (the folder's own).
        var root = ownPath
        if !responses.contains(where: { $0.path == ownPath || $0.path.hasPrefix(ownPath.isEmpty ? "" : ownPath + "/") }),
           let shortest = responses.map(\.path).min(by: { $0.count < $1.count }) {
            root = shortest
        }

        var entries: [Entry] = []
        for (path, response) in responses {
            guard path != root else { continue }
            let relative: String
            if root.isEmpty {
                relative = path
            } else if path.hasPrefix(root + "/") {
                relative = String(path.dropFirst(root.count + 1))
            } else {
                continue
            }
            guard !relative.isEmpty else { continue }
            let isFolder = response.isCollection || response.href.hasSuffix("/")
            let key = folderPath.isEmpty ? relative : folderPath + "/" + relative
            entries.append(Entry(
                key: isFolder ? key + "/" : key,
                isFolder: isFolder,
                size: isFolder ? 0 : response.size ?? 0,
                lastModified: response.lastModified.flatMap(date)
            ))
        }
        return entries
    }

    /// The path of an href: an absolute URL's path, or the href itself,
    /// without a query or fragment.
    private static func path(ofHref href: String) -> String {
        var path = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = path.range(of: "://") {
            let afterScheme = path[scheme.upperBound...]
            path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        }
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        return path
    }

    private static func decoded(_ string: String) -> String {
        string.removingPercentEncoding ?? string
    }

    private static func trimmedSlashes(_ string: String) -> String {
        string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// "Wed, 21 Oct 2026 07:28:00 GMT", as WebDAV writes `getlastmodified`
    /// and HTTP `Last-Modified`, or an ISO 8601 date from a server that
    /// gets it wrong.
    static func date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) { return date }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        struct Response {
            var href = ""
            var isCollection = false
            var size: Int64?
            var lastModified: String?
        }

        var responses: [Response] = []
        var isMultistatus = false
        private var current: Response?
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            // Elements outside `DAV:` (a server's own properties) keep a
            // name no DAV element has.
            let local = namespaceURI == "DAV:" ? name : "\u{0}" + name
            if path.isEmpty { isMultistatus = local == "multistatus" }
            path.append(local)
            text = ""
            switch local {
            case "response": current = Response()
            case "collection" where path.contains("resourcetype"): current?.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = path.last ?? ""
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "href" where path.dropLast().last == "response":
                current?.href = value
            case "getcontentlength" where !value.isEmpty:
                current?.size = Int64(value)
            case "getlastmodified" where !value.isEmpty:
                current?.lastModified = value
            case "response":
                if let current, !current.href.isEmpty { responses.append(current) }
                current = nil
            default:
                break
            }
            path.removeLast()
            text = ""
        }
    }
}
