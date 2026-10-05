import AppKit
import Foundation
import Observation

/// History is metadata-first: the original uploaded file is never copied
/// permanently, only a small thumbnail. They're kept next to the history
/// in Application Support rather than in Caches, which the system or a
/// cleaner app may empty: the file they were made from is usually gone,
/// so one that's deleted can't simply be made again.
///
/// Observable through `revision`, so rows show a thumbnail as soon as it's
/// made (they're made while the upload's link is already copied).
@MainActor
@Observable
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private(set) var revision = 0

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let images = NSCache<NSUUID, NSImage>()
    /// IDs looked up on disk with nothing there, so rows that show icons
    /// don't touch the disk on every redraw.
    @ObservationIgnored private var missing: Set<UUID> = []

    private init() {
        let manager = FileManager.default
        directory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.moveOldThumbnails(to: directory)
    }

    func image(for id: UUID) -> NSImage? {
        _ = revision
        if let image = images.object(forKey: id as NSUUID) { return image }
        guard !missing.contains(id) else { return nil }
        guard let image = fileURLs(for: id).lazy.compactMap({ NSImage(contentsOf: $0) }).first else {
            missing.insert(id)
            return nil
        }
        images.setObject(image, forKey: id as NSUUID)
        return image
    }

    /// WebP, or PNG (made by versions before 0.13, or when WebP couldn't
    /// be encoded).
    func store(_ data: Data, for id: UUID) {
        let isWebP = ThumbnailGenerator.isWebP(data)
        let target = isWebP ? fileURLs(for: id)[0] : fileURLs(for: id)[1]
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return
        }
        try? FileManager.default.removeItem(at: isWebP ? fileURLs(for: id)[1] : fileURLs(for: id)[0])
        try? FileManager.default.removeItem(at: unavailableURL(for: id))
        images.removeObject(forKey: id as NSUUID)
        missing.remove(id)
        revision += 1
    }

    func remove(for id: UUID) {
        remove([id])
    }

    func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            for url in fileURLs(for: id) + [unavailableURL(for: id)] {
                try? FileManager.default.removeItem(at: url)
            }
            images.removeObject(forKey: id as NSUUID)
            missing.insert(id)
        }
        revision += 1
    }

    /// Settings > General > Clear: every thumbnail of every upload, and
    /// what couldn't be made, so it's tried again when shown.
    func removeAll() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        images.removeAllObjects()
        missing = []
        revision += 1
    }

    /// Space taken by the thumbnails of uploads and of bucket files.
    static func diskUsage() async -> Int64 {
        let folders = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Aktar/Thumbnails", isDirectory: true),
            RemoteThumbnailLoader.cacheDirectory,
        ]
        return await Task.detached(priority: .utility) {
            folders.reduce(0) { $0 + Self.size(of: $1) }
        }.value
    }

    private nonisolated static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Remembers that no thumbnail could be made for this upload, so it
    /// isn't tried again (which could mean downloading the file).
    func markUnavailable(_ id: UUID) {
        FileManager.default.createFile(atPath: unavailableURL(for: id).path, contents: nil)
    }

    func isUnavailable(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: unavailableURL(for: id).path)
    }

    private func fileURLs(for id: UUID) -> [URL] {
        ["webp", "png"].map { directory.appendingPathComponent("\(id.uuidString).\($0)") }
    }

    private func unavailableURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).none")
    }

    /// Versions before 0.13 kept them in Caches.
    private static func moveOldThumbnails(to directory: URL) {
        let manager = FileManager.default
        let old = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        guard let names = try? manager.contentsOfDirectory(atPath: old.path) else { return }
        for name in names where name.hasSuffix(".png") {
            let target = directory.appendingPathComponent(name)
            if !manager.fileExists(atPath: target.path) {
                try? manager.moveItem(at: old.appendingPathComponent(name), to: target)
            }
        }
        try? manager.removeItem(at: old)
    }
}
