import Foundation
import SwiftData

@MainActor
final class UploadRepository {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init() {
        let schema = Schema([UploadRecord.self])
        let configuration = ModelConfiguration(schema: schema)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContext = modelContainer.mainContext
    }

    @discardableResult
    /// `uploadedFileURL` is the file that was actually sent when it isn't
    /// `input.fileURL` itself, such as the ZIP of a folder. `thumbnail` is
    /// the one made from it, nil when none could be made (or thumbnails
    /// are off for the destination).
    func record(result: UploadResult, input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil, uploadedFileURL: URL? = nil, contentHash: String? = nil, thumbnail: Data? = nil) -> UploadRecord {
        let fileURL = uploadedFileURL ?? input.fileURL
        let createdAt = Date.now
        let record = UploadRecord(
            localFilename: input.originalFilename,
            objectKey: result.objectKey,
            publicURLString: result.publicURL.absoluteString,
            destinationID: destination.id,
            destinationName: destination.name,
            mimeType: ContentTypeResolver.resolve(for: fileURL),
            byteSize: result.byteSize,
            createdAt: createdAt,
            expiresAt: expiryDays.map { createdAt.addingTimeInterval(TimeInterval($0) * 86_400) },
            contentHash: contentHash,
            watchedFolderID: input.watch?.folderID,
            watchedFolderName: input.watch?.folderName
        )
        modelContext.insert(record)
        try? modelContext.save()
        if let thumbnail {
            ThumbnailStore.shared.store(thumbnail, for: record.id)
        } else if destination.thumbnailMode != .off {
            // Nothing could be made from the file itself; downloading it
            // again later wouldn't do better.
            ThumbnailStore.shared.markUnavailable(record.id)
        }
        return record
    }

    /// A replace (`UploadManager.replace`): the entry keeps its ID, key and
    /// link, and gets the new file's size, hash, type and thumbnail, a
    /// "Replaced" date, and, for an expiring key, a new expiry. Without an
    /// entry (a bucket object Aktar didn't upload, or one removed from
    /// history), the replace is added to history.
    @discardableResult
    func replace(recordID: UUID?, result: UploadResult, input: UploadInput, destination: DestinationConfig, expiryDays: Int?, uploadedFileURL: URL, contentHash: String?, thumbnail: Data?) -> UploadRecord {
        let now = Date.now
        guard let recordID, let record = record(id: recordID) else {
            let record = self.record(result: result, input: input, destination: destination, expiryDays: expiryDays, uploadedFileURL: uploadedFileURL, contentHash: contentHash, thumbnail: thumbnail)
            record.replacedAt = now
            try? modelContext.save()
            return record
        }
        record.byteSize = result.byteSize
        record.mimeType = ContentTypeResolver.resolve(for: uploadedFileURL)
        record.contentHash = contentHash
        record.replacedAt = now
        record.remoteDeletedAt = nil
        record.expiresAt = expiryDays.map { now.addingTimeInterval(TimeInterval($0) * 86_400) }
        try? modelContext.save()
        let store = ThumbnailStore.shared
        if let thumbnail {
            store.store(thumbnail, for: record.id)
        } else {
            store.remove(for: record.id)
            if destination.thumbnailMode != .off { store.markUnavailable(record.id) }
        }
        return record
    }

    func record(id: UUID) -> UploadRecord? {
        let descriptor = FetchDescriptor<UploadRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func delete(_ record: UploadRecord) {
        modelContext.delete(record)
        try? modelContext.save()
        ThumbnailStore.shared.remove(for: record.id)
    }

    /// Turning a destination's thumbnails off removes the ones made for it.
    func removeThumbnails(destinationID: UUID) {
        let descriptor = FetchDescriptor<UploadRecord>(predicate: #Predicate { $0.destinationID == destinationID })
        ThumbnailStore.shared.remove(((try? modelContext.fetch(descriptor)) ?? []).map(\.id))
    }

    /// Keeps history in step with changes made from the bucket browser: an
    /// object that was deleted there drops out of history, and one that was
    /// renamed or moved gets its new key and link.
    func objectDeleted(key: String, destinationID: UUID) {
        for record in records(key: key, destinationID: destinationID) {
            delete(record)
        }
    }

    /// Moving a file out of its expiring prefix keeps it, and moving one into
    /// a prefix makes it expire (a copy counts from now), but only when
    /// `rulesActive`: without Aktar's rules in the bucket nothing deletes it,
    /// and a folder that happens to be called `tmp/7d/` is just a folder.
    func objectMoved(from oldKey: String, to newKey: String, destination: DestinationConfig, rulesActive: Bool) {
        for record in records(key: oldKey, destinationID: destination.id) {
            record.objectKey = newKey
            if let days = UploadExpiry.days(forKey: newKey) {
                if UploadExpiry.days(forKey: oldKey) == days {
                    // Renamed inside its folder: expires on the same day.
                } else if rulesActive {
                    record.expiresAt = Date.now.addingTimeInterval(TimeInterval(days) * 86_400)
                } else {
                    record.expiresAt = nil
                }
            } else {
                record.expiresAt = nil
            }
            if let url = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: newKey) {
                record.publicURLString = url.absoluteString
            }
        }
        try? modelContext.save()
    }

    /// Uploads to `destinationID` stop expiring: its bucket no longer has
    /// Aktar's rules, so those files stay for good, and neither the history
    /// nor the expiry sweep may treat them as due.
    func clearExpiry(destinationID: UUID) {
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.destinationID == destinationID && $0.expiresAt != nil }
        )
        for record in (try? modelContext.fetch(descriptor)) ?? [] {
            record.expiresAt = nil
        }
        try? modelContext.save()
    }

    /// Expiring uploads whose time is up. The bucket's lifecycle rule usually
    /// deletes the object first; these are what the app still has to clean up.
    func expiredRecords(now: Date = .now) -> [UploadRecord] {
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { record in
                if let expiresAt = record.expiresAt {
                    return expiresAt <= now
                } else {
                    return false
                }
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// An earlier upload of the same bytes to the same destination whose
    /// link can be handed out again: not deleted, and expiring the same
    /// way the new upload would. Both never expire, or both are in the
    /// same `tmp/{N}d/` folder and the earlier one hasn't expired yet.
    /// Not one whose key something else was uploaded to later (a `{filename}`
    /// path gives the same key to different files): that link shows the
    /// newer file now. Whether the file is still in the bucket, unchanged,
    /// is up to the caller.
    func reusableRecord(destinationID: UUID, contentHash: String, expiryDays: Int?, now: Date = .now) -> UploadRecord? {
        let hash: String? = contentHash
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.destinationID == destinationID && $0.contentHash == hash && $0.remoteDeletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).first { record in
            if let expiryDays {
                guard let expiresAt = record.expiresAt, expiresAt > now else { return false }
                guard UploadExpiry.days(forKey: record.objectKey) == expiryDays else { return false }
            } else if record.expiresAt != nil {
                return false
            }
            return !records(key: record.objectKey, destinationID: destinationID).contains {
                $0.createdAt > record.createdAt && $0.contentHash != record.contentHash
            }
        }
    }

    /// History entries of the object at `key`.
    func records(key: String, destinationID: UUID) -> [UploadRecord] {
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.objectKey == key && $0.destinationID == destinationID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
