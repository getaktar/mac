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
    func record(result: UploadResult, input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil) -> UploadRecord {
        let createdAt = Date.now
        let record = UploadRecord(
            localFilename: input.originalFilename,
            objectKey: result.objectKey,
            publicURLString: result.publicURL.absoluteString,
            destinationID: destination.id,
            destinationName: destination.name,
            mimeType: ContentTypeResolver.resolve(for: input.fileURL),
            byteSize: result.byteSize,
            createdAt: createdAt,
            expiresAt: expiryDays.map { createdAt.addingTimeInterval(TimeInterval($0) * 86_400) }
        )
        modelContext.insert(record)
        try? modelContext.save()
        ThumbnailCache.store(sourceURL: input.fileURL, for: record.id)
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

    func objectMoved(from oldKey: String, to newKey: String, destination: DestinationConfig) {
        for record in records(key: oldKey, destinationID: destination.id) {
            record.objectKey = newKey
            // Moving a file out of its expiring prefix keeps it, and moving
            // one into a prefix makes it expire (a copy counts from now).
            if let days = UploadExpiry.days(forKey: newKey) {
                if UploadExpiry.days(forKey: oldKey) != days {
                    record.expiresAt = Date.now.addingTimeInterval(TimeInterval(days) * 86_400)
                }
            } else {
                record.expiresAt = nil
            }
            record.publicURLString = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: newKey).absoluteString
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

    private func records(key: String, destinationID: UUID) -> [UploadRecord] {
        let descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.objectKey == key && $0.destinationID == destinationID }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
