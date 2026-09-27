import Foundation

struct ConnectionResult {
    let bucketReachable: Bool
    let writable: Bool
    let publicURLReachable: Bool?
}

/// One level of a bucket, as S3 lists it with a "/" delimiter: the
/// "folders" (common prefixes) and objects directly under `prefix`.
struct BucketListing: Sendable {
    let prefix: String
    let folders: [String]
    let objects: [BucketObject]
    let nextContinuationToken: String?
}

struct BucketObject: Sendable, Identifiable, Hashable {
    let key: String
    let size: Int64
    let lastModified: Date?

    var id: String { key }
    var name: String { String(key.split(separator: "/", omittingEmptySubsequences: false).last ?? "") }
}

struct UploadResult: Sendable {
    let objectKey: String
    let publicURL: URL
    let byteSize: Int
}

enum StorageError: Error, LocalizedError {
    case invalidCredentials
    case bucketNotFound(String)
    case accessDenied
    case network(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return String(localized: "Could not authenticate. Check your Access Key ID and Secret Access Key.")
        case .bucketNotFound(let bucket):
            return String(localized: "Bucket \u{201C}\(bucket)\u{201D} could not be found.")
        case .accessDenied:
            return String(localized: "Connected successfully, but this key cannot upload files.")
        case .network(let message):
            return String(localized: "Upload interrupted. \(message)")
        case .unknown(let message):
            return message
        }
    }
}

protocol StorageProvider {
    func testConnection() async throws -> ConnectionResult
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult
    func delete(objectKey: String) async throws
    func list(prefix: String, continuationToken: String?) async throws -> BucketListing
    func listRecursively(prefix: String, continuationToken: String?) async throws -> BucketListing
    func objectExists(key: String) async throws -> Bool
    func copy(from sourceKey: String, to destinationKey: String) async throws
    func createFolder(prefix: String) async throws
    func temporaryURL(for objectKey: String, expiresIn seconds: Int64) async throws -> URL
}
