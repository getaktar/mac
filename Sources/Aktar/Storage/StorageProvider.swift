import Foundation

struct ConnectionResult {
    let bucketReachable: Bool
    let writable: Bool
    /// What opening the test file's public link returned. Nil when nothing
    /// was uploaded to open.
    let publicLink: PublicLinkCheck?
}

/// The outcome of opening a link the way someone it's shared with would.
enum PublicLinkCheck: Equatable {
    case reachable
    /// The server answered with a status outside 2xx, such as 403 from a
    /// bucket that accepts uploads but doesn't allow public reads.
    case status(Int)
    /// No HTTP answer at all: DNS, TLS or a timeout.
    case noResponse
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
    case lifecycleNotAllowed
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
        case .lifecycleNotAllowed:
            return String(localized: "This key can't change the bucket's lifecycle rules.")
        case .network(let message):
            return String(localized: "Upload interrupted. \(message)")
        case .unknown(let message):
            return message
        }
    }
}

extension StorageError {
    /// A destination saved before the Public Base URL was checked.
    static var invalidPublicBaseURL: StorageError {
        .unknown(String(localized: "This destination\u{2019}s Public Base URL isn\u{2019}t a valid web address. Fix it in Settings > Destinations."))
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
    func ensureExpiryRules() async throws
    func removeExpiryRules() async throws
}
