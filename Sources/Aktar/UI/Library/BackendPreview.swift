import CryptoKit
import Foundation

/// Previews of files on storage without temporary links (WebDAV, SFTP),
/// for when the public link doesn't load: the folder may not be served on
/// the web at all, or the Public Base URL points somewhere else
/// (docs/storage-backends.md, "Phase 4"). The file is then downloaded
/// through the destination's own connection, with a size cap, into a
/// cache folder, and the preview loads that copy. S3 keeps using presigned
/// links, which work for private buckets already.
@MainActor
enum BackendPreview {
    /// Images, PDFs and text: the same cap as previews from a link
    /// (`RemoteFileLoader.maxBytes`).
    static let maxBytes: Int64 = 25 * 1024 * 1024
    /// Video and audio, played from the downloaded copy.
    static let maxMediaBytes: Int64 = 200 * 1024 * 1024
    /// Copies older than this are deleted the first time one is needed.
    private static let cacheLifetime: TimeInterval = 86_400

    /// Whether each public link loaded, for this run of the app.
    private static var linkWorks: [URL: Bool] = [:]
    /// Copies made this run, by destination, key, size and date.
    private static var copies: [String: URL] = [:]
    private static var inFlight: [String: Task<URL?, Never>] = [:]
    private static var pruned = false

    nonisolated static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aktar", isDirectory: true)
        .appendingPathComponent("Previews", isDirectory: true)

    /// Where a preview of `key` loads from: `publicURL` when it's an S3
    /// destination or the link loads, otherwise a copy downloaded through
    /// the backend (nil when that fails or the file is over the cap).
    static func url(
        for key: String,
        destination: DestinationConfig,
        publicURL: URL?,
        size: Int64?,
        modified: Date? = nil,
        media: Bool = false
    ) async -> URL? {
        guard destination.kind != .s3, !destination.capabilities.temporaryLinks else { return publicURL }
        if let publicURL, await loads(publicURL) { return publicURL }
        let cap = media ? maxMediaBytes : maxBytes
        if let size, size > cap { return publicURL }
        let cacheKey = [destination.id.uuidString, key, String(size ?? -1), String(modified?.timeIntervalSince1970 ?? 0)].joined(separator: "\n")
        if let copy = copies[cacheKey], FileManager.default.fileExists(atPath: copy.path) { return copy }
        if let task = inFlight[cacheKey] { return await task.value }
        guard let credentials = try? KeychainService.load(for: destination.id) else { return publicURL }
        pruneOnce()
        let backend = StorageBackends.make(config: destination, credentials: credentials)
        let file = directory.appendingPathComponent(hash(cacheKey)).appendingPathExtension((key as NSString).pathExtension.lowercased())
        let folder = directory
        let task = Task<URL?, Never>.detached {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard try await backend.download(key: key, to: file, maxBytes: cap) else { return nil }
                return file
            } catch {
                return nil
            }
        }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        if let result { copies[cacheKey] = result }
        return result ?? publicURL
    }

    /// Opens the link once as someone it's shared with would.
    private static func loads(_ url: URL) async -> Bool {
        if let known = linkWorks[url] { return known }
        let works = await S3Provider.probe(url: url) == .reachable
        linkWorks[url] = works
        return works
    }

    private static func pruneOnce() {
        guard !pruned else { return }
        pruned = true
        let directory = directory
        let lifetime = cacheLifetime
        Task.detached(priority: .background) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) > lifetime { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// Settings > General > Clear, with the thumbnails.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        copies.removeAll()
        linkWorks.removeAll()
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

