import Foundation

struct ConnectionResult {
    let bucketReachable: Bool
    let writable: Bool
    /// What opening the test file's public link returned. Nil when nothing
    /// was uploaded to open.
    let publicLink: PublicLinkCheck?
    /// SFTP: the server's public key the test connected to, in OpenSSH
    /// format, for the form to show (its fingerprint) and save.
    var sshHostKey: String? = nil
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
    /// A conditional write found the key taken; see `ShortKeys`.
    case alreadyExists
    /// Every {short} key tried was taken; see `ShortKeys`.
    case noFreeShortKey
    /// WebDAV's counterparts of `invalidCredentials`, `bucketNotFound` and
    /// `accessDenied`, worded for a user name, a folder and an account
    /// instead of keys and a bucket.
    case wrongUserNameOrPassword
    case folderNotFound
    case writeNotAllowed
    /// WebDAV's 507 Insufficient Storage.
    case outOfSpace
    /// SFTP: the server turned the user name with the password or key down.
    case sshAuthenticationFailed
    /// SFTP: an encrypted private key without its passphrase, or a wrong one.
    case keyPassphrase
    /// SFTP: a private key of a type or format Aktar can't use, by name.
    case unsupportedKey(String)
    /// SFTP: the destination's Folder isn't on the server.
    case serverFolderNotFound(String)
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
        case .alreadyExists:
            return String(localized: "A file with this name is already in the bucket.")
        case .noFreeShortKey:
            return String(localized: "Couldn\u{2019}t find an unused short name for this file after \(ShortKeys.maxAttempts) tries. Nothing was overwritten. Try again.")
        case .wrongUserNameOrPassword:
            return String(localized: "Could not sign in. Check your user name and password.")
        case .folderNotFound:
            return String(localized: "Folder not found. Check the Server URL.")
        case .writeNotAllowed:
            return String(localized: "The server refused this. Check that this account can write to the folder.")
        case .outOfSpace:
            return String(localized: "The server is out of space.")
        case .sshAuthenticationFailed:
            return String(localized: "Could not sign in. Check your user name, password or key.")
        case .keyPassphrase:
            return String(localized: "The key\u{2019}s passphrase is missing or wrong.")
        case .unsupportedKey(let name):
            return String(localized: "Aktar can\u{2019}t use this type of key (\(name)). Use an ed25519 or RSA key.")
        case .serverFolderNotFound(let path):
            return String(localized: "Folder not found on the server (\(path)). Check the Folder.")
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
