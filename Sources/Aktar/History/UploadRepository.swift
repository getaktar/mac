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
    func record(result: UploadResult, input: UploadInput, destination: DestinationConfig) -> UploadRecord {
        let record = UploadRecord(
            localFilename: input.originalFilename,
            objectKey: result.objectKey,
            publicURLString: result.publicURL.absoluteString,
            destinationID: destination.id,
            destinationName: destination.name,
            mimeType: ContentTypeResolver.resolve(for: input.fileURL),
            byteSize: result.byteSize
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
}
