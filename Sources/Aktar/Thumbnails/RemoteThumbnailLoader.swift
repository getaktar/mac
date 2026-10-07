import AppKit
import CryptoKit
import Foundation

/// Thumbnails for files that are already in a bucket: the rows of the
/// bucket view, and history entries that have none on this Mac (uploaded
/// before thumbnails were made for their kind of file). In order:
///
/// 1. The thumbnail this Mac made when it uploaded the file.
/// 2. With `ThumbnailMode.bucket`, the one saved in the bucket, unless the
///    file was replaced after it was made.
/// 3. One made here from the file, if it's small enough to download
///    (`maxSourceBytes`), and then saved to the bucket too in that mode.
/// 4. Nothing; the row keeps its file icon, and that's remembered.
///
/// With `ThumbnailMode.off` nothing is looked up or downloaded at all.
@MainActor
final class RemoteThumbnailLoader {
    static let shared = RemoteThumbnailLoader()

    /// Larger files aren't downloaded just to make a thumbnail.
    static let maxSourceBytes: Int64 = 25 * 1024 * 1024
    /// Thumbnails of bucket files are made again after this long unused.
    private nonisolated static let cacheLifetime: TimeInterval = 30 * 86_400

    /// Set at launch, for the thumbnails this Mac made when uploading.
    weak var repository: UploadRepository?

    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var historyInFlight: Set<UUID> = []
    private var providers: [UUID: S3Provider] = [:]
    /// Downloads and generation running at once, and those waiting.
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let maxRunning = 3

    nonisolated static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aktar", isDirectory: true)
        .appendingPathComponent("BucketThumbnails", isDirectory: true)

    private init() {
        directory = Self.cacheDirectory
        let directory = directory
        Task.detached(priority: .background) { Self.prune(directory) }
    }

    // MARK: - Bucket view

    /// A cached thumbnail, without waiting; nil when it has to be loaded.
    func cachedImage(for object: BucketObject, destination: DestinationConfig) -> NSImage? {
        guard destination.thumbnailMode != .off else { return nil }
        return memory.object(forKey: memoryKey(destination.id, object) as NSString)
    }

    /// `allowDownload` false: only what's at hand (this Mac's, the cache,
    /// the bucket's own thumbnail), never the file itself, for callers that
    /// ask for many at once (the local API's list icons).
    func image(for object: BucketObject, destination: DestinationConfig, prefixes: [String], allowDownload: Bool = true) async -> NSImage? {
        guard destination.thumbnailMode != .off, !object.key.hasSuffix("/"),
              !ThumbnailKeys.isThumbnail(object.key, prefixes: prefixes) else { return nil }
        let key = memoryKey(destination.id, object)
        if let image = memory.object(forKey: key as NSString) { return image }
        if allowDownload, let task = inFlight[key] { return await task.value }

        let task = Task<NSImage?, Never> {
            let file = cacheFile(destinationID: destination.id, object: object)
            if FileManager.default.fileExists(atPath: file.appendingPathExtension("none").path) { return nil }
            if let data = try? Data(contentsOf: file.appendingPathExtension("thumb")), let image = NSImage(data: data) { return image }
            if let image = uploadedThumbnail(for: object, destinationID: destination.id) { return image }

            let outcome = await limited {
                await self.make(objectKey: object.key, size: object.size, writtenAfter: object.lastModified, destination: destination, allowDownload: allowDownload)
            }
            switch outcome {
            case .made(let data):
                Self.write(data, to: file.appendingPathExtension("thumb"))
                return NSImage(data: data)
            case .unavailable:
                Self.write(Data(), to: file.appendingPathExtension("none"))
                return nil
            case .failed:
                return nil
            }
        }
        if allowDownload { inFlight[key] = task }
        let image = await task.value
        if allowDownload { inFlight[key] = nil }
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    /// The thumbnail this Mac made when it uploaded the object, if the
    /// object is still that upload (not replaced since).
    private func uploadedThumbnail(for object: BucketObject, destinationID: UUID) -> NSImage? {
        guard let records = repository?.records(key: object.key, destinationID: destinationID),
              let newest = records.max(by: { $0.writtenAt < $1.writtenAt }) else { return nil }
        if let written = object.lastModified, written > newest.writtenAt.addingTimeInterval(60) { return nil }
        return ThumbnailStore.shared.image(for: newest.id)
    }

    // MARK: - History

    /// Makes or fetches a thumbnail for a history entry that has none, into
    /// `ThumbnailStore`. Not for one whose file was deleted, has expired or
    /// was replaced by a later upload to the same key.
    func loadThumbnail(for record: UploadRecord, destination: DestinationConfig) async {
        let store = ThumbnailStore.shared
        let id = record.id
        guard destination.thumbnailMode != .off, record.destinationID == destination.id,
              record.remoteDeletedAt == nil, (record.expiresAt ?? .distantFuture) > .now,
              !historyInFlight.contains(id), store.image(for: id) == nil, !store.isUnavailable(id) else { return }
        let newer = repository?.records(key: record.objectKey, destinationID: destination.id)
            .contains { $0.id != id && $0.writtenAt > record.writtenAt } ?? false
        guard !newer else {
            store.markUnavailable(id)
            return
        }
        historyInFlight.insert(id)
        defer { historyInFlight.remove(id) }
        let objectKey = record.objectKey
        let size = Int64(record.byteSize)
        // The bucket's own thumbnail is written just after the file.
        let writtenAfter = record.writtenAt.addingTimeInterval(-120)
        let uploadedAt = record.writtenAt
        let outcome = await limited {
            await self.make(objectKey: objectKey, size: size, writtenAfter: writtenAfter, destination: destination, uploadedAt: uploadedAt)
        }
        switch outcome {
        case .made(let data): store.store(data, for: id)
        case .unavailable: store.markUnavailable(id)
        case .failed: break
        }
    }

    // MARK: - Making one

    private enum Outcome: Sendable {
        case made(Data)
        /// There's no thumbnail to be had; not tried again.
        case unavailable
        /// Offline or the like; tried again next time.
        case failed
    }

    /// `uploadedAt`: for a history entry, the file must still be that
    /// upload, or the thumbnail would show another file.
    private func make(objectKey: String, size: Int64, writtenAfter: Date?, destination: DestinationConfig, uploadedAt: Date? = nil, allowDownload: Bool = true) async -> Outcome {
        guard let provider = provider(for: destination) else { return .failed }
        let prefix = destination.bucketThumbnailPrefix
        if let prefix, let data = await BucketThumbnails.fetch(for: objectKey, prefix: prefix, writtenAfter: writtenAfter, provider: provider),
           Self.isThumbnail(data) {
            return .made(data)
        }

        let name = (objectKey as NSString).lastPathComponent
        // Not known to be unavailable: left for a caller that may download.
        guard allowDownload else { return .failed }
        guard size <= Self.maxSourceBytes, ThumbnailGenerator.canHaveThumbnail(filename: name) else { return .unavailable }
        if let uploadedAt {
            do {
                guard let written = try await provider.lastModified(key: objectKey) else { return .unavailable }
                if written > uploadedAt.addingTimeInterval(60) { return .unavailable }
            } catch {
                return .failed
            }
        }
        let folder: URL
        do {
            folder = try TempFiles.newFolder(in: TempFiles.thumbnails)
        } catch {
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        // A key's last part is anyone's choice: one safe name inside the folder.
        let file = folder.appendingPathComponent(ObjectKeyGenerator.sanitizedFilename(name))
        do {
            guard try await provider.download(key: objectKey, to: file, maxBytes: Self.maxSourceBytes) else { return .unavailable }
        } catch {
            return .failed
        }
        guard let thumbnail = await ThumbnailGenerator.make(from: file) else { return .unavailable }
        if let prefix, thumbnail.isWebP {
            try? await BucketThumbnails.save(thumbnail.data, for: objectKey, prefix: prefix, provider: provider)
        }
        return .made(thumbnail.data)
    }

    /// Whether what's at a thumbnail's key really is one: a WebP image
    /// of thumbnail size (another app's, or one made at an older size,
    /// is kept as it is).
    private static func isThumbnail(_ data: Data) -> Bool {
        guard ThumbnailGenerator.isWebP(data), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return max(width, height) <= ThumbnailGenerator.maxPixelSize * 2
    }

    private func limited<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        if running >= maxRunning {
            await withCheckedContinuation { waiting.append($0) }
        }
        running += 1
        defer {
            running -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return await work()
    }

    private func provider(for destination: DestinationConfig) -> S3Provider? {
        if let provider = providers[destination.id], provider.config == destination { return provider }
        guard let credentials = try? KeychainService.load(for: destination.id) else { return nil }
        let provider = S3Provider(config: destination, credentials: credentials)
        providers[destination.id] = provider
        return provider
    }

    // MARK: - Cache

    /// Thumbnails of a file the bucket no longer has under that key.
    func forget(destinationID: UUID, key: String) {
        try? FileManager.default.removeItem(at: keyFolder(destinationID: destinationID, key: key))
        memory.removeAllObjects()
    }

    /// Settings > General > Clear: every bucket's.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        memory.removeAllObjects()
    }

    /// Everything made for a destination's bucket, when its thumbnails are
    /// turned off or it points at another bucket.
    func forget(destinationID: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(destinationID.uuidString, isDirectory: true))
        providers[destinationID] = nil
        memory.removeAllObjects()
    }

    private func memoryKey(_ destinationID: UUID, _ object: BucketObject) -> String {
        [destinationID.uuidString, object.key, String(object.size), String(object.lastModified?.timeIntervalSince1970 ?? 0)]
            .joined(separator: "\n")
    }

    private func keyFolder(destinationID: UUID, key: String) -> URL {
        directory.appendingPathComponent(destinationID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.hash(key), isDirectory: true)
    }

    /// Named after the object's size and date too, so a replaced file
    /// doesn't show the old file's thumbnail. Without an extension.
    private func cacheFile(destinationID: UUID, object: BucketObject) -> URL {
        keyFolder(destinationID: destinationID, key: object.key)
            .appendingPathComponent(Self.hash(memoryKey(destinationID, object)))
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Drops what hasn't been written for `cacheLifetime`.
    private nonisolated static func prune(_ directory: URL) {
        let manager = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-cacheLifetime)
        guard let files = manager.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let date = values?.contentModificationDate, date < cutoff {
                try? manager.removeItem(at: file)
            }
        }
    }
}
