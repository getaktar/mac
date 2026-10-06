import Foundation
import CryptoKit
import NIOHTTP1
import SotoS3

/// S3-compatible storage adapter. Every provider preset (AWS S3, Cloudflare
/// R2, MinIO, Backblaze B2, DigitalOcean Spaces, custom) goes through this
/// single adapter, never a separate upload engine per provider.
final class S3Provider: StorageProvider, Sendable {
    let config: DestinationConfig
    private let client: AWSClient
    let s3: S3
    /// For signing the uploads sent with URLSession; see S3Transfer.
    let credentials: StorageCredentials

    init(config: DestinationConfig, credentials: StorageCredentials) {
        self.config = config
        self.credentials = credentials
        self.client = AWSClient(
            credentialProvider: .static(
                accessKeyId: credentials.accessKeyId,
                secretAccessKey: credentials.secretAccessKey,
                sessionToken: credentials.sessionToken
            )
        )
        // Soto defaults to path-style addressing, which is what most
        // S3-compatible providers (MinIO, R2, B2, Spaces) expect. Virtual
        // hosted-style is opted into explicitly for providers that prefer it.
        // Every request made through Soto (listing, deleting, copying,
        // creating, completing and aborting multipart uploads) has 60
        // seconds in all, retries and reading the reply included; see
        // `OverallTimeout`. The file bytes go through S3Transfer instead.
        self.s3 = S3(
            client: client,
            region: Region(rawValue: config.region),
            endpoint: config.endpoint,
            middleware: OverallTimeout(seconds: Self.requestTimeout),
            options: config.forcePathStyle ? [] : [.s3ForceVirtualHost]
        )
    }

    deinit {
        try? client.syncShutdown()
    }

    func testConnection() async throws -> ConnectionResult {
        do {
            _ = try await s3.headBucket(.init(bucket: config.bucket))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }

        let testKey = "_aktar_test_\(UUID().uuidString.prefix(8)).txt"
        var writable = false
        do {
            _ = try await s3.putObject(.init(
                body: .init(string: "aktar connection test"),
                bucket: config.bucket,
                contentType: "text/plain",
                key: testKey
            ))
            writable = true
        } catch {
            writable = false
        }

        var publicLink: PublicLinkCheck?
        if writable, !config.publicBaseURL.isEmpty {
            if let url = PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: testKey) {
                publicLink = await Self.probe(url: url)
            } else {
                publicLink = .noResponse
            }
        }

        if writable {
            _ = try? await s3.deleteObject(.init(bucket: config.bucket, key: testKey))
        }

        return ConnectionResult(bucketReachable: true, writable: writable, publicLink: publicLink)
    }

    /// One streaming PUT up to `multipartThreshold`, a multipart upload
    /// above it (see `MultipartUploader`, which can also resume one).
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult {
        let size = try Self.fileSize(of: fileURL)
        await progress?(0)
        let reporter = ProgressReporter(total: size, report: progress)
        if size > Self.multipartThreshold {
            try await MultipartUploader.upload(
                provider: self,
                fileURL: fileURL,
                fileSize: size,
                objectKey: objectKey,
                contentType: contentType,
                session: nil,
                identity: nil,
                reporter: reporter
            )
        } else {
            try await putObject(fileURL: fileURL, objectKey: objectKey, contentType: contentType) { sent in
                reporter.update(part: 0, sent: sent)
            }
        }
        await progress?(1)
        guard let url = PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: objectKey) else {
            throw StorageError.invalidPublicBaseURL
        }
        return UploadResult(objectKey: objectKey, publicURL: url, byteSize: Int(size))
    }

    func delete(objectKey: String) async throws {
        do {
            _ = try await s3.deleteObject(.init(bucket: config.bucket, key: objectKey))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// Up to 1000 keys per request. A provider that doesn't take batch
    /// deletes gets them one by one.
    func delete(objectKeys: [String]) async throws {
        var start = 0
        while start < objectKeys.count {
            let batch = Array(objectKeys[start..<min(start + 1000, objectKeys.count)])
            start += batch.count
            do {
                let output = try await s3.deleteObjects(.init(
                    bucket: config.bucket,
                    delete: .init(objects: batch.map { .init(key: $0) }, quiet: true)
                ))
                if let failed = output.errors, !failed.isEmpty {
                    for key in failed.compactMap(\.key) { try await delete(objectKey: key) }
                }
            } catch {
                for key in batch { try await delete(objectKey: key) }
            }
        }
    }

    /// One level under `prefix`: its folders and the objects directly in it.
    func list(prefix: String, continuationToken: String?) async throws -> BucketListing {
        try await list(prefix: prefix, continuationToken: continuationToken, delimiter: "/")
    }

    /// Every key under `prefix`, however deep, 1000 per page. Used for
    /// search, since S3 has no server-side search. `folders` holds the
    /// "name/" placeholders of otherwise empty folders.
    func listRecursively(prefix: String, continuationToken: String?) async throws -> BucketListing {
        try await list(prefix: prefix, continuationToken: continuationToken, delimiter: nil)
    }

    private func list(prefix: String, continuationToken: String?, delimiter: String?) async throws -> BucketListing {
        do {
            let output = try await s3.listObjectsV2(
                bucket: config.bucket,
                continuationToken: continuationToken,
                delimiter: delimiter,
                maxKeys: 1000,
                prefix: prefix.isEmpty ? nil : prefix
            )
            var folders = (output.commonPrefixes ?? []).compactMap(\.prefix)
            var objects: [BucketObject] = []
            for object in output.contents ?? [] {
                guard let key = object.key, key != prefix else { continue }
                // A zero-byte "folder/" placeholder is a folder, not a file.
                if key.hasSuffix("/") {
                    if delimiter == nil { folders.append(key) }
                    continue
                }
                objects.append(BucketObject(key: key, size: object.size ?? 0, lastModified: object.lastModified))
            }
            let next = output.isTruncated == true ? output.nextContinuationToken : nil
            return BucketListing(prefix: prefix, folders: folders, objects: objects, nextContinuationToken: next)
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// Asks for the first key starting with `key` instead of sending a HEAD
    /// request: a missing object's HEAD reply is a bodyless 404, which some
    /// providers send in a form Soto can't parse ("truncatedData"). Keys are
    /// listed in order, so an exact match always comes first.
    func objectExists(key: String) async throws -> Bool {
        do {
            let output = try await s3.listObjectsV2(bucket: config.bucket, maxKeys: 1, prefix: key)
            return output.contents?.first?.key == key
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// Size and last change of the object at `key`, or nil when there's
    /// none. Listed for the same reason as `objectExists`.
    func objectInfo(key: String) async throws -> (size: Int64, lastModified: Date?)? {
        do {
            let output = try await s3.listObjectsV2(bucket: config.bucket, maxKeys: 1, prefix: key)
            guard let object = output.contents?.first, object.key == key else { return nil }
            return (object.size ?? 0, object.lastModified)
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// S3 has no rename or move: both are a server-side copy followed by
    /// deleting the original.
    func copy(from sourceKey: String, to destinationKey: String) async throws {
        do {
            _ = try await s3.copyObject(.init(
                bucket: config.bucket,
                copySource: "\(config.bucket)/\(Self.encodePath(sourceKey))",
                key: destinationKey
            ))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// S3 folders only exist while something is in them; an empty
    /// "name/" object is the conventional way to keep an empty one around.
    func createFolder(prefix: String) async throws {
        do {
            _ = try await s3.putObject(.init(body: .init(bytes: Data()), bucket: config.bucket, key: prefix))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// A presigned GET URL, which works for private buckets and doesn't
    /// depend on the public base URL being set up correctly.
    func temporaryURL(for objectKey: String, expiresIn seconds: Int64) async throws -> URL {
        guard var components = URLComponents(string: config.endpoint.contains("://") ? config.endpoint : "https://\(config.endpoint)") else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        let key = Self.encodePath(objectKey)
        if config.forcePathStyle {
            components.percentEncodedPath = "/\(config.bucket)/\(key)"
        } else {
            components.host = "\(config.bucket).\(components.host ?? "")"
            components.percentEncodedPath = "/\(key)"
        }
        guard let url = components.url else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        return try await s3.signURL(url: url, httpMethod: .GET, expires: .seconds(seconds))
    }

    /// Makes sure the bucket has one lifecycle rule per expiry duration (see
    /// `UploadExpiry`). A PUT replaces the bucket's whole lifecycle
    /// configuration, so every rule that isn't Aktar's is sent back exactly
    /// as it came (see `LifecycleXML` for why this isn't done with typed
    /// requests), and nothing is written when the rules are already there.
    /// Many keys can't manage lifecycle rules (an R2 "Object Read & Write"
    /// token, for one); that comes back as `.lifecycleNotAllowed`.
    func ensureExpiryRules() async throws {
        let url = try bucketURL(query: "lifecycle")
        let existing = try await lifecycleRules(url: url) ?? []
        guard let xml = LifecycleXML.merged(existing) else { return }
        let (putStatus, putBody) = try await lifecycleRequest(url: url, method: .PUT, body: Data(xml.utf8))
        guard (200..<300).contains(putStatus) else {
            throw Self.lifecycleError(status: putStatus, body: putBody, bucket: config.bucket)
        }
        // Read back: a provider can answer 200 to a configuration it
        // ignored, and "active" means the bucket really deletes the files.
        guard LifecycleXML.isInPlace(try await lifecycleRules(url: url) ?? []) else {
            throw StorageError.unknown(String(localized: "The provider didn't keep the lifecycle rules."))
        }
    }

    /// Whether the bucket has all of Aktar's expiry rules right now. Throws
    /// when they can't be read.
    func expiryRulesInPlace() async throws -> Bool {
        let url = try bucketURL(query: "lifecycle")
        return LifecycleXML.isInPlace(try await lifecycleRules(url: url) ?? [])
    }

    /// Takes Aktar's expiry rules back out of the bucket, leaving its other
    /// rules as they are. Files already under `tmp/` then stay for good.
    func removeExpiryRules() async throws {
        let url = try bucketURL(query: "lifecycle")
        guard let existing = try await lifecycleRules(url: url),
              let xml = LifecycleXML.removingAktarRules(existing) else { return }
        let (writeStatus, writeBody) = xml.isEmpty
            ? try await lifecycleRequest(url: url, method: .DELETE)
            : try await lifecycleRequest(url: url, method: .PUT, body: Data(xml.utf8))
        guard (200..<300).contains(writeStatus) else {
            throw Self.lifecycleError(status: writeStatus, body: writeBody, bucket: config.bucket)
        }
    }

    /// Which of the `tmp/{N}d/` folders already hold files while their rule
    /// isn't in place yet. Setting the rules up makes the bucket delete
    /// those too, including ones older than N days, so the user is asked
    /// first. Empty when the rules are all in place or can't be read
    /// (setting up then reports why).
    func expiryPrefixesInUse() async throws -> [String] {
        guard let url = try? bucketURL(query: "lifecycle"),
              let existing = try? await lifecycleRules(url: url) ?? [] else { return [] }
        var inUse: [String] = []
        for days in LifecycleXML.missingDurations(existing) {
            let prefix = UploadExpiry.prefix(days: days)
            do {
                let output = try await s3.listObjectsV2(bucket: config.bucket, maxKeys: 1, prefix: prefix)
                if !(output.contents ?? []).isEmpty { inUse.append(prefix) }
            } catch {
                throw Self.mapError(error, bucket: config.bucket)
            }
        }
        return inUse
    }

    /// When the object at exactly `key` was last written, or nil when there's
    /// no such object (`.distantPast` when the provider leaves the date out).
    /// Listed rather than HEADed, like `objectExists`.
    func lastModified(key: String) async throws -> Date? {
        do {
            let output = try await s3.listObjectsV2(bucket: config.bucket, maxKeys: 1, prefix: key)
            guard let object = output.contents?.first, object.key == key else { return nil }
            return object.lastModified ?? .distantPast
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// The size of the object at exactly `key`, or nil when there's none.
    /// Listed rather than HEADed, like `objectExists`.
    func objectSize(key: String) async throws -> Int64? {
        do {
            let output = try await s3.listObjectsV2(bucket: config.bucket, maxKeys: 1, prefix: key)
            guard let object = output.contents?.first, object.key == key else { return nil }
            return object.size
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// The bucket's lifecycle rules, or nil when it has none. Anything that
    /// doesn't read as a complete lifecycle configuration stops here, before
    /// a write could replace the bucket's own rules.
    private func lifecycleRules(url: URL) async throws -> [LifecycleXML.Rule]? {
        let (status, body) = try await lifecycleRequest(url: url, method: .GET)
        guard (200..<300).contains(status) else {
            // A bucket without any rules answers with that error rather
            // than an empty list; anything else is a real failure.
            if LifecycleXML.error(in: body).code == "NoSuchLifecycleConfiguration" { return nil }
            throw Self.lifecycleError(status: status, body: body, bucket: config.bucket)
        }
        guard let rules = LifecycleXML.configurationRules(in: body) else {
            throw StorageError.unknown(String(localized: "The bucket's lifecycle rules couldn't be read, so nothing was changed."))
        }
        return rules
    }

    private func lifecycleRequest(url: URL, method: HTTPMethod, body: Data? = nil) async throws -> (Int, String) {
        var headers = HTTPHeaders()
        if let body {
            headers.add(name: "Content-Type", value: "application/xml")
            headers.add(name: "Content-MD5", value: Data(Insecure.MD5.hash(data: body)).base64EncodedString())
        }
        let signed = try await s3.signHeaders(
            url: url,
            httpMethod: method,
            headers: headers,
            body: body.map { .init(bytes: $0) } ?? .init()
        )
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = 20
        for (name, value) in signed {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await Self.controlSession.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        } catch {
            throw StorageError.network(error.localizedDescription)
        }
    }

    private static func lifecycleError(status: Int, body: String, bucket: String) -> StorageError {
        let (code, message) = LifecycleXML.error(in: body)
        switch (status, code) {
        case (_, "NoSuchBucket"):
            return .bucketNotFound(bucket)
        case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"):
            return .invalidCredentials
        case (403, _), (_, "AccessDenied"):
            return .lifecycleNotAllowed
        case (405, _), (501, _), (_, "NotImplemented"):
            return .unknown(String(localized: "This provider doesn't support lifecycle rules."))
        default:
            return .unknown(message ?? code ?? "HTTP \(status)")
        }
    }

    /// `https://endpoint/bucket?query` (path style) or
    /// `https://bucket.endpoint/?query` (virtual hosted), like `temporaryURL`.
    private func bucketURL(query: String) throws -> URL {
        guard var components = URLComponents(string: config.endpoint.contains("://") ? config.endpoint : "https://\(config.endpoint)"),
              components.host?.isEmpty == false, !config.bucket.isEmpty else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        if config.forcePathStyle {
            components.percentEncodedPath = "/\(config.bucket)"
        } else {
            components.host = "\(config.bucket).\(components.host ?? "")"
            components.percentEncodedPath = "/"
        }
        components.percentEncodedQuery = query
        guard let url = components.url else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        return url
    }

    /// The most any request that carries no file bytes may take in all.
    static let requestTimeout: TimeInterval = 60

    /// For the lifecycle requests: 20 seconds without a byte, 60 in all
    /// (the reply's body included).
    private static let controlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func encodePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }

    private static func probe(url: URL) async -> PublicLinkCheck {
        let head = await status(of: url, method: "HEAD")
        // Some servers and CDNs don't answer HEAD; ask again the way a
        // browser would before calling the link broken.
        let status = head == 405 || head == 501 ? await status(of: url, method: "GET") : head
        guard let status else { return .noResponse }
        return (200..<300).contains(status) ? .reachable : .status(status)
    }

    private static func status(of url: URL, method: String) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let response = try? await URLSession.shared.data(for: request).1
        return (response as? HTTPURLResponse)?.statusCode
    }

    static func mapError(_ error: Error, bucket: String) -> StorageError {
        let description = String(describing: error).lowercased()
        if (error as? AWSErrorType)?.context?.responseCode == .preconditionFailed
            || description.contains("preconditionfailed") || description.contains("conditionalrequestconflict") {
            return .alreadyExists
        }
        if description.contains("nosuchbucket") {
            return .bucketNotFound(bucket)
        }
        if description.contains("accessdenied") || description.contains("forbidden") {
            return .accessDenied
        }
        if description.contains("invalidaccesskeyid") || description.contains("signaturedoesnotmatch")
            || description.contains("unauthorized") {
            return .invalidCredentials
        }
        return .unknown((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}

/// Gives a request made through Soto `seconds` in all, its retries and
/// reading the whole reply included; Soto's own timeout only covers the
/// wait for each attempt's first bytes. Past that it fails as timed out.
private struct OverallTimeout: AWSMiddlewareProtocol {
    let seconds: TimeInterval

    func handle(_ request: AWSHTTPRequest, context: AWSMiddlewareContext, next: AWSMiddlewareNextHandler) async throws -> AWSHTTPResponse {
        let seconds = seconds
        // The group waits for both tasks before it returns, so `next` is
        // done with by then; it's only called once, from one task.
        return try await withoutActuallyEscaping(next) { next in
            nonisolated(unsafe) let next = next
            return try await withThrowingTaskGroup(of: AWSHTTPResponse.self) { group in
                group.addTask { try await next(request, context) }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw URLError(.timedOut) }
                return response
            }
        }
    }
}
