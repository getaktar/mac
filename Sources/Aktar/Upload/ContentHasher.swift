import CryptoKit
import Foundation

/// Hashes of the bytes that are actually uploaded, for the {md5} and
/// {sha256} path variables and for reusing the link of a file that's
/// already in the bucket. Read in chunks, so a file of any size is never
/// loaded into memory whole.
struct ContentHashes: Sendable, Equatable {
    /// Lowercase hex, or nil when it wasn't asked for.
    var md5: String?
    var sha256: String?
}

enum ContentHasher {
    private static let chunkSize = 1024 * 1024

    static func hashes(of url: URL, md5: Bool, sha256: Bool) throws -> ContentHashes {
        guard md5 || sha256 else { return ContentHashes() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5Hasher = Insecure.MD5()
        var sha256Hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            if md5 { md5Hasher.update(data: chunk) }
            if sha256 { sha256Hasher.update(data: chunk) }
        }
        return ContentHashes(
            md5: md5 ? hex(md5Hasher.finalize()) : nil,
            sha256: sha256 ? hex(sha256Hasher.finalize()) : nil
        )
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
