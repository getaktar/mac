import Foundation
import SotoS3

/// S3-compatible storage adapter. Every provider preset (AWS S3, Cloudflare
/// R2, MinIO, Backblaze B2, DigitalOcean Spaces, custom) goes through this
/// single adapter, never a separate upload engine per provider.
final class S3Provider: StorageProvider {
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
