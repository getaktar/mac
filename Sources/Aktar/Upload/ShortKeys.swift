import Foundation

/// Writing a key with {short} without replacing a file that already has
/// it. Amazon S3 and Cloudflare R2 refuse the write themselves when the
/// key is taken (`If-None-Match: *`, on the PUT or on completing a
/// multipart upload), so nothing can slip in between; other providers are
/// asked first, which is practically as safe at 62^7 codes but not
/// guaranteed. A taken key gets a whole new key with a new code, never a
/// number, and after `maxAttempts` the upload fails instead of replacing
/// anything.
enum ShortKeys {
    static let maxAttempts = 5

    static func usesConditionalWrites(_ preset: ProviderPreset) -> Bool {
        preset == .amazonS3 || preset == .cloudflareR2
    }

    /// Writes with `firstKey`, then with keys from `newKey` while the key
    /// is taken, and returns the key written. `write` gets the key and
    /// whether to send it as a conditional write; it throws
    /// `StorageError.alreadyExists` when the provider refused it as taken.
    /// `exists` is asked first when `conditional` is false. A key that
    /// can't list the bucket writes without asking, as before. Runs on the
    /// caller's actor, as the closures usually belong to it.
    static func write(
        isolation: isolated (any Actor)? = #isolation,
        firstKey: String,
        conditional: Bool,
        newKey: () -> String,
        exists: (String) async throws -> Bool,
        write: (String, Bool) async throws -> Void
    ) async throws -> String {
        var key = firstKey
        for attempt in 1...maxAttempts {
            if attempt > 1 { key = newKey() }
            if !conditional {
                let taken: Bool
                do {
                    taken = try await exists(key)
                } catch StorageError.accessDenied {
                    taken = false
                }
                if taken { continue }
            }
            do {
                try await write(key, conditional)
                return key
            } catch StorageError.alreadyExists {
                continue
            }
        }
        throw StorageError.noFreeShortKey
    }
}
