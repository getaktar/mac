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
    /// `input.fileURL` itself, such as the ZIP of a folder.
    func record(result: UploadResult, input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil, uploadedFileURL: URL? = nil, contentHash: String? = nil) -> UploadRecord {
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
            contentHash: contentHash
        )
        modelContext.insert(record)
        try? modelContext.save()
        ThumbnailCache.store(sourceURL: fileURL, for: record.id)
        return record
    }

    func delete(_ record: UploadRecord) {
        modelContext.delete(record)
        try? modelContext.save()
        ThumbnailCache.remove(for: record.id)
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
            record.publicURLString = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: newKey).absoluteString
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
    /// Whether the file is still in the bucket is up to the caller.
    func reusableRecord(destinationID: UUID, contentHash: String, expiryDays: Int?, now: Date = .now) -> UploadRecord? {
        let hash: String? = contentHash
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.destinationID == destinationID && $0.contentHash == hash && $0.remoteDeletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return ((try? modelContext.fetch(descriptor)) ?? []).first { record in
            if let expiryDays {
                guard let expiresAt = record.expiresAt, expiresAt > now else { return false }
                return UploadExpiry.days(forKey: record.objectKey) == expiryDays
            }
            return record.expiresAt == nil
        }
    }

    private func records(key: String, destinationID: UUID) -> [UploadRecord] {
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.objectKey == key && $0.destinationID == destinationID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
