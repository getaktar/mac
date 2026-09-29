import Foundation
import CryptoKit
import NIOHTTP1
import SotoS3

/// S3-compatible storage adapter. Every provider preset (AWS S3, Cloudflare
/// R2, MinIO, Backblaze B2, DigitalOcean Spaces, custom) goes through this
/// single adapter, never a separate upload engine per provider.
final class S3Provider: StorageProvider, Sendable {
    private let config: DestinationConfig
    private let client: AWSClient
    private let s3: S3

    init(config: DestinationConfig, credentials: StorageCredentials) {
        self.config = config
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
        self.s3 = S3(
            client: client,
            region: Region(rawValue: config.region),
            endpoint: config.endpoint,
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

        var publicURLReachable: Bool?
        if writable, !config.publicBaseURL.isEmpty {
            let url = PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: testKey)
            publicURLReachable = await Self.probe(url: url)
        }

        if writable {
            _ = try? await s3.deleteObject(.init(bucket: config.bucket, key: testKey))
        }

        return ConnectionResult(bucketReachable: true, writable: writable, publicURLReachable: publicURLReachable)
    }

    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult {
        let data = try Data(contentsOf: fileURL)
        await progress?(0)
        do {
            _ = try await s3.putObject(.init(
                body: .init(bytes: data),
                bucket: config.bucket,
                contentType: contentType,
                key: objectKey
            ))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
        await progress?(1)
        let url = PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: objectKey)
        return UploadResult(objectKey: objectKey, publicURL: url, byteSize: data.count)
    }

    func delete(objectKey: String) async throws {
        do {
            _ = try await s3.deleteObject(.init(bucket: config.bucket, key: objectKey))
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
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
        let (status, body) = try await lifecycleRequest(url: url, method: .GET)
        var existing: [LifecycleXML.Rule] = []
        if (200..<300).contains(status) {
            existing = LifecycleXML.rules(in: body)
        } else if LifecycleXML.error(in: body).code != "NoSuchLifecycleConfiguration" {
            // A bucket without any rules answers with that error rather
            // than an empty list; anything else is a real failure.
            throw Self.lifecycleError(status: status, body: body, bucket: config.bucket)
        }

        guard let xml = LifecycleXML.merged(existing) else { return }
        let (putStatus, putBody) = try await lifecycleRequest(url: url, method: .PUT, body: Data(xml.utf8))
        guard (200..<300).contains(putStatus) else {
            throw Self.lifecycleError(status: putStatus, body: putBody, bucket: config.bucket)
        }
    }

    /// Takes Aktar's expiry rules back out of the bucket, leaving its other
    /// rules as they are. Files already under `tmp/` then stay for good.
    func removeExpiryRules() async throws {
        let url = try bucketURL(query: "lifecycle")
        let (status, body) = try await lifecycleRequest(url: url, method: .GET)
        guard (200..<300).contains(status) else {
            if LifecycleXML.error(in: body).code == "NoSuchLifecycleConfiguration" { return }
            throw Self.lifecycleError(status: status, body: body, bucket: config.bucket)
        }
        guard let xml = LifecycleXML.removingAktarRules(LifecycleXML.rules(in: body)) else { return }
        let (writeStatus, writeBody) = xml.isEmpty
            ? try await lifecycleRequest(url: url, method: .DELETE)
            : try await lifecycleRequest(url: url, method: .PUT, body: Data(xml.utf8))
        guard (200..<300).contains(writeStatus) else {
            throw Self.lifecycleError(status: writeStatus, body: writeBody, bucket: config.bucket)
        }
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
            let (data, response) = try await URLSession.shared.data(for: request)
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

    private static func encodePath(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }

    private static func probe(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse { return (200..<300).contains(http.statusCode) }
            return false
        } catch {
            return false
        }
    }

    private static func mapError(_ error: Error, bucket: String) -> StorageError {
        let description = String(describing: error).lowercased()
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
