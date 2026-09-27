import Foundation
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
