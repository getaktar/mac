import Foundation

/// What kind of storage a destination is (docs/storage-backends.md). It's
/// told by the destination's preset rather than a field of its own, so an
/// older version that doesn't know a kind can't read it as S3 by mistake.
enum StorageKind: String, Sendable {
    case s3
    case webdav
    case sftp
}

extension ProviderPreset {
    var kind: StorageKind {
        switch self {
        case .cloudflareR2, .amazonS3, .minIO, .backblazeB2, .digitalOceanSpaces, .customS3:
            return .s3
        }
    }
}

/// What a destination's storage can do, beyond uploading, deleting,
/// checking for and linking to a file, which every kind can. Code asks
/// this rather than the preset, and a control for something the kind
/// can't do is hidden rather than shown and failing.
struct StorageCapabilities: Equatable, Sendable {
    /// Listing a folder or everything under a prefix: the bucket browser,
    /// the library, file requests, thumbnail cleanup.
    var list: Bool
    /// Copying (and so moving and renaming) on the server.
    var copy: Bool
    /// A write that fails when the key is taken (`If-None-Match: *`).
    /// Without it, short keys ask `objectExists` first.
    var conditionalWrites: Bool
    /// Multipart uploads, for files over `S3Provider.multipartThreshold`
    /// and resuming them.
    var multipart: Bool
    /// Presigned links: Link (5 min ... 7 days), Copy Temporary Link.
    var temporaryLinks: Bool
    /// Bucket lifecycle rules, which "Delete after" relies on.
    var expiryRules: Bool
    /// Request Files: presigned PUTs and the bucket's CORS rule.
    var fileRequests: Bool
    /// Thumbnails kept "In the Bucket".
    var bucketThumbnails: Bool
    /// Share pages, galleries and encrypted links, which are files next
    /// to the file.
    var sharePages: Bool
    /// Set Up Cloudflare R2.
    var cloudflareSetup: Bool

    init(kind: StorageKind, preset: ProviderPreset) {
        switch kind {
        case .s3:
            list = true
            copy = true
            // Of the S3 providers, only these two refuse a taken key.
            conditionalWrites = preset == .amazonS3 || preset == .cloudflareR2
            multipart = true
            temporaryLinks = true
            expiryRules = true
            fileRequests = true
            bucketThumbnails = true
            sharePages = true
            cloudflareSetup = preset == .cloudflareR2
        case .webdav, .sftp:
            list = true
            copy = true
            conditionalWrites = false
            multipart = false
            temporaryLinks = false
            expiryRules = false
            fileRequests = false
            bucketThumbnails = true
            sharePages = true
            cloudflareSetup = false
        }
    }

    init(preset: ProviderPreset) {
        self.init(kind: preset.kind, preset: preset)
    }
}

extension DestinationConfig {
    var kind: StorageKind { preset.kind }
    var capabilities: StorageCapabilities { StorageCapabilities(preset: preset) }
}

/// The operations every kind of storage has (docs/storage-backends.md,
/// "The backend interface"). Code that only needs these goes through
/// `StorageBackends.make` and this type; what only S3 has (presigned URLs,
/// lifecycle rules, CORS, multipart sessions) stays on `S3Provider`, which
/// `s3(for:)` hands out after checking the destination can do it.
protocol StorageBackend: Sendable {
    var config: DestinationConfig { get }

    func testConnection() async throws -> ConnectionResult
    /// Sends the file at `fileURL` to `objectKey`. `onlyIfNew` writes only a
    /// key that isn't taken yet and throws `StorageError.alreadyExists`
    /// otherwise; it's only asked for where `conditionalWrites` is.
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        onlyIfNew: Bool,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult
    /// One small write from memory: share pages, thumbnails, request files.
    /// `cacheControl` replaces the destination's own.
    func putObject(data: Data, objectKey: String, contentType: String, cacheControl: String?) async throws
    /// A small object and when it was last written, or nil when there's
    /// none. Anything over `maxBytes` is refused.
    func getObject(key: String, maxBytes: Int) async throws -> (data: Data, lastModified: Date?)?
    /// Downloads the object at `key` to `destination`. False when there's
    /// no such object.
    func download(key: String, to destination: URL, maxBytes: Int64) async throws -> Bool
    func delete(objectKey: String) async throws
    func delete(objectKeys: [String]) async throws
    func objectExists(key: String) async throws -> Bool
    /// Size and last change of the object at exactly `key`, or nil when
    /// there's none.
    func objectInfo(key: String) async throws -> (size: Int64, lastModified: Date?)?
    /// One level under `prefix`, with "/" separating folders.
    func list(prefix: String, continuationToken: String?) async throws -> BucketListing
    /// Everything under `prefix`, a page at a time.
    func listRecursively(prefix: String, continuationToken: String?) async throws -> BucketListing
    func copy(from sourceKey: String, to destinationKey: String) async throws
    func createFolder(prefix: String) async throws
    /// The link to `objectKey` under the destination's Public Base URL, or
    /// nil when that isn't a valid address.
    func publicURL(for objectKey: String) -> URL?
}

extension StorageBackend {
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult {
        try await upload(fileURL: fileURL, objectKey: objectKey, contentType: contentType, onlyIfNew: false, progress: progress)
    }

    func putObject(data: Data, objectKey: String, contentType: String) async throws {
        try await putObject(data: data, objectKey: objectKey, contentType: contentType, cacheControl: nil)
    }

    /// When the object at exactly `key` was last written, or nil when
    /// there's no such object (`.distantPast` when the storage leaves the
    /// date out).
    func lastModified(key: String) async throws -> Date? {
        guard let info = try await objectInfo(key: key) else { return nil }
        return info.lastModified ?? .distantPast
    }

    /// The size of the object at exactly `key`, or nil when there's none.
    func objectSize(key: String) async throws -> Int64? {
        try await objectInfo(key: key)?.size
    }

    /// The S3 type behind this backend, for an operation only S3 has, when
    /// the destination has `capability`; nil otherwise. Callers check this
    /// instead of casting, so a destination of another kind never reaches
    /// an S3 request.
    func s3(for capability: KeyPath<StorageCapabilities, Bool>) -> S3Provider? {
        guard config.capabilities[keyPath: capability] else { return nil }
        return self as? S3Provider
    }
}

/// The one place a destination's backend is made, so a new kind only adds
/// a case here.
enum StorageBackends {
    static func make(config: DestinationConfig, credentials: StorageCredentials) -> any StorageBackend {
        switch config.kind {
        case .s3:
            return S3Provider(config: config, credentials: credentials)
        case .webdav, .sftp:
            // No preset has these kinds yet (phase 2 adds WebDAV).
            fatalError("No storage backend for \(config.kind.rawValue) destinations yet")
        }
    }

    /// The backend's S3 type for an S3-only operation, nil when the
    /// destination doesn't have `capability`.
    static func s3(
        config: DestinationConfig,
        credentials: StorageCredentials,
        for capability: KeyPath<StorageCapabilities, Bool>
    ) -> S3Provider? {
        make(config: config, credentials: credentials).s3(for: capability)
    }
}

extension StorageError {
    /// What a destination's kind can't do; the control asking for it is
    /// normally hidden, so this is only reached by a stale setting.
    static var unsupported: StorageError {
        .unknown("This destination\u{2019}s kind of storage can\u{2019}t do this.")
    }
}
