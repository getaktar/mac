import Foundation

/// The link copied before an upload finished (docs/capture-and-instant-links.md,
/// "Instant link"). From then on the upload goes to `objectKey` and nowhere
/// else, also when it's retried or continued after a restart, so the link
/// that was handed out starts working once the bytes are there.
struct EarlyLink: Codable, Sendable, Equatable {
    var objectKey: String
    /// The public URL or temporary link that was copied (or shortened).
    var link: URL
    /// When `link` is a temporary link, when it stops working.
    var temporaryExpiresAt: Date?
    /// The short link made for `link`, not in history yet.
    var shortLink: EarlyShortLink?
    /// Why the short link couldn't be made (the long link was copied);
    /// said once the upload is done, when Retry has an upload to work on.
    var shortLinkError: String?
    /// What was put on the clipboard.
    var copiedText: String
}

/// A short link made at the provider for an early link.
struct EarlyShortLink: Codable, Sendable, Equatable {
    var shortUrl: String
    var providerId: String?
    var provider: String
    var providerName: String
    var domain: String?
    var targetUrl: String
    var expiresAt: Date?
}

/// An upload whose link was copied and that hasn't finished: what it needs
/// to go on after Aktar quits, crashes or the Mac restarts.
struct OutboxEntry: Codable, Sendable, Identifiable, Equatable {
    /// The upload job's ID.
    let id: UUID
    let destinationID: UUID
    var originalFilename: String
    /// The file's name inside the entry's folder.
    var storedName: String
    var expiryDays: Int?
    /// The upload's own Short Links override (the local API's short=).
    var shortLinkOverride: Bool?
    var earlyLink: EarlyLink
    /// When the first try started: an object at the key written after
    /// this is the upload's own, from a try whose answer was lost.
    var firstAttemptAt: Date
    /// A failure that won't pass by itself; such an entry isn't started at
    /// launch, it waits for Retry or Cancel.
    var failure: String?

    /// Older entries are dropped at launch, with their copy of the file,
    /// like unfinished multipart uploads.
    static let maxAge: TimeInterval = 7 * 86_400

    func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(firstAttemptAt) > Self.maxAge
    }
}

/// Uploads whose link was copied but whose bytes aren't all in the bucket
/// yet, one folder each in Application Support: `entry.json` and a copy of
/// the file. On the same disk the copy is a clone, which takes no time or
/// space whatever the size. A file on another disk is copied only up to
/// `maxCrossVolumeBytes`; a bigger one isn't kept, and its upload only
/// goes on while Aktar runs.
@MainActor
final class UploadOutbox {
    nonisolated static let maxCrossVolumeBytes: Int64 = 512 * 1024 * 1024

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
    }

    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func manifestURL(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("entry.json")
    }

    func fileURL(for entry: OutboxEntry) -> URL {
        folder(entry.id).appendingPathComponent("file", isDirectory: true).appendingPathComponent(entry.storedName)
    }

    func contains(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(id).path)
    }

    /// Writes the entry, copying `file` in the first time (off the main
    /// thread: a copy from another disk takes a moment). False when the
    /// file couldn't (or shouldn't) be kept; nothing is left behind then.
    @discardableResult
    func save(_ entry: OutboxEntry, file: URL) async -> Bool {
        if contains(entry.id) { return update(entry) }
        let target = fileURL(for: entry)
        let directory = directory
        let copied = await Task.detached(priority: .utility) { () -> Bool in
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard UploadOutbox.canCopy(file, into: directory) else { return false }
                try manager.copyItem(at: file, to: target)
                return true
            } catch {
                return false
            }
        }.value
        guard copied, update(entry) else {
            remove(entry.id)
            return false
        }
        return true
    }

    /// Rewrites the entry of an upload that's already kept.
    @discardableResult
    func update(_ entry: OutboxEntry) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return false }
        do {
            try data.write(to: manifestURL(entry.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// Every kept upload whose file is still there, oldest first. Folders
    /// that can't be read, and entries older than `OutboxEntry.maxAge`, are
    /// removed.
    func load(now: Date = .now) -> [(entry: OutboxEntry, fileURL: URL)] {
        let manager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [(entry: OutboxEntry, fileURL: URL)] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: manifestURL(id)),
                  let entry = try? decoder.decode(OutboxEntry.self, from: data),
                  entry.id == id, !entry.isStale(now: now), manager.fileExists(atPath: fileURL(for: entry).path) else {
                try? manager.removeItem(at: folder)
                continue
            }
            result.append((entry, fileURL(for: entry)))
        }
        return result.sorted { $0.entry.firstAttemptAt < $1.entry.firstAttemptAt }
    }

    /// Same disk (a clone), or another disk and small enough to copy.
    nonisolated static func canCopy(_ file: URL, into directory: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let source = (try? file.resourceValues(forKeys: keys))?.volumeIdentifier as? NSObject
        let target = (try? directory.resourceValues(forKeys: keys))?.volumeIdentifier as? NSObject
        if let source, let target, source.isEqual(target) { return true }
        return totalSize(of: file) <= maxCrossVolumeBytes
    }

    /// A file's size, or everything in a folder.
    nonisolated static func totalSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if total > maxCrossVolumeBytes { break }
        }
        return total
    }
}
