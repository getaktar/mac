import Foundation

/// Thumbnails saved in the bucket (`ThumbnailMode.bucket`), kept in step
/// with their files: whatever deletes, renames or moves a file does the
/// same to its thumbnail in every thumbnail folder of that bucket (see
/// `ThumbnailKeys.bucketPrefixes`). With no such folder, none of these
/// sends anything.
enum BucketThumbnails {
    /// A thumbnail is a few dozen kilobytes; anything far bigger at a
    /// thumbnail's key isn't one.
    static let maxThumbnailBytes = 2 * 1024 * 1024

    static func save(_ webp: Data, for objectKey: String, prefix: String, provider: S3Provider) async throws {
        guard let key = ThumbnailKeys.key(for: objectKey, prefix: prefix) else { return }
        try await provider.putObject(data: webp, objectKey: key, contentType: ThumbnailKeys.contentType)
    }

    /// Called before the file itself is deleted, so a failure leaves both
    /// in place rather than a thumbnail of a file that's gone. Deleting one
    /// that isn't there succeeds.
    static func delete(for objectKey: String, prefixes: [String], provider: S3Provider) async throws {
        let keys = prefixes.compactMap { ThumbnailKeys.key(for: objectKey, prefix: $0) }
        guard !keys.isEmpty else { return }
        if keys.count == 1 {
            try await provider.delete(objectKey: keys[0])
        } else {
            try await provider.delete(objectKeys: keys)
        }
    }

    /// After a file was copied to `newKey`: its thumbnails go along. One
    /// that can't be copied is made again when it's next shown.
    static func copy(from oldKey: String, to newKey: String, prefixes: [String], provider: S3Provider) async {
        for prefix in prefixes {
            guard let source = ThumbnailKeys.key(for: oldKey, prefix: prefix),
                  let target = ThumbnailKeys.key(for: newKey, prefix: prefix),
                  (try? await provider.objectExists(key: source)) == true else { continue }
            try? await provider.copy(from: source, to: target)
        }
    }

    /// The thumbnail of the file at `objectKey`, unless it's older than
    /// `writtenAfter` (the file was replaced after it was made). Nil when
    /// there's none or it can't be read.
    static func fetch(for objectKey: String, prefix: String, writtenAfter: Date?, provider: S3Provider) async -> Data? {
        guard let key = ThumbnailKeys.key(for: objectKey, prefix: prefix),
              let result = try? await provider.getObject(key: key, maxBytes: maxThumbnailBytes) else { return nil }
        if let writtenAfter, let lastModified = result.lastModified, lastModified < writtenAfter { return nil }
        return result.data
    }

    /// Deletes every thumbnail in a thumbnail folder, at the root and in
    /// the expiring folders. Only `.webp` files, the only kind Aktar puts
    /// there, so nothing else that ended up in that folder is touched.
    static func deleteAll(prefix: String, provider: S3Provider) async throws {
        for root in ThumbnailKeys.roots(prefix: prefix) {
            var token: String?
            repeat {
                let page = try await provider.listRecursively(prefix: root, continuationToken: token)
                let keys = page.objects.map(\.key).filter { $0.hasSuffix("." + ThumbnailKeys.fileExtension) }
                try await provider.delete(objectKeys: keys)
                token = page.nextContinuationToken
            } while token != nil
        }
    }
}

extension BucketThumbnails {
    /// Empties a thumbnail folder the destination no longer uses, in the
    /// background, and says how it went. `config` and `credentials` are the
    /// ones the folder was used with: the form may have pointed the
    /// destination at another bucket, with other keys, since.
    @MainActor
    static func deleteFolderInBackground(prefix: String, config: DestinationConfig, credentials: StorageCredentials) {
        Task {
            do {
                try await deleteAll(prefix: prefix, provider: S3Provider(config: config, credentials: credentials))
                NotificationService.notifyThumbnailsDeleted(destinationName: config.name)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NotificationService.notifyThumbnailsDeleteFailed(destinationName: config.name, reason: reason)
            }
        }
    }
}
