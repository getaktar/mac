import AppIntents
import Foundation
import SwiftData

// Shortcuts, Spotlight and Siri actions. They run inside the app (launching
// it in the background if needed), go through the same upload manager as
// everything else, and wait for the upload before returning its link. An
// upload without a destination goes where "Use for" sends it.

// MARK: - Entities

struct DestinationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let defaultQuery = DestinationQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ destination: DestinationConfig) {
        id = destination.id
        name = destination.name
    }
}

struct DestinationQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [DestinationEntity] {
        let destinations = AppState.current?.destinationStore.destinations ?? []
        return destinations.filter { identifiers.contains($0.id) }.map(DestinationEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [DestinationEntity] {
        (AppState.current?.destinationStore.destinations ?? []).map(DestinationEntity.init)
    }
}

struct UploadEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Upload"
    static let defaultQuery = UploadQuery()

    let id: UUID
    @Property(title: "Name") var filename: String
    @Property(title: "Link") var link: URL
    @Property(title: "Object Key") var objectKey: String
    @Property(title: "Destination") var destinationName: String
    @Property(title: "Uploaded") var uploadedAt: Date

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(filename)", subtitle: "\(destinationName)")
    }

    init(_ record: UploadRecord, link: URL? = nil) {
        id = record.id
        filename = record.localFilename
        self.link = link ?? record.publicURL ?? URL(string: "about:blank")!
        objectKey = record.objectKey
        destinationName = record.destinationName
        uploadedAt = record.createdAt
    }
}

struct UploadQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [UploadEntity] {
        guard let repository = AppState.current?.repository else { return [] }
        return identifiers.compactMap(repository.record(id:)).map { UploadEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [UploadEntity] {
        AktarIntentSupport.recentRecords(limit: 20, destinationID: nil).map { UploadEntity($0) }
    }
}

enum DeleteAfterOption: Int, AppEnum {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Delete After"
    static let caseDisplayRepresentations: [DeleteAfterOption: DisplayRepresentation] = [
        .never: "Never",
        .oneDay: "1 day",
        .sevenDays: "7 days",
        .fourteenDays: "14 days",
        .thirtyDays: "30 days",
    ]
}

// MARK: - Actions

struct UploadFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload File"
    static let description = IntentDescription("Uploads files to your storage with Aktar and returns their links.")
    static let openAppWhenRun = false

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Destination", description: "Leave empty to use \u{201C}Use for\u{201D} and the default destination.")
    var destination: DestinationEntity?

    @Parameter(title: "Name", description: "A new name for a single file, keeping its extension.")
    var name: String?

    @Parameter(title: "Delete After")
    var deleteAfter: DeleteAfterOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Upload \(\.$files) to \(\.$destination)") {
            \.$name
            \.$deleteAfter
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> {
        let manager = try AktarIntentSupport.manager()
        let config = try AktarIntentSupport.destination(destination)
        let folder = try AktarIntentSupport.stagingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var links: [URL] = []
        for (index, file) in files.enumerated() {
            var filename = file.filename
            if files.count == 1, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                filename = RenamePrompt.keepingExtension(name, of: filename)
            }
            let url = folder.appendingPathComponent("\(index)", isDirectory: true).appendingPathComponent(file.filename)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
            let input = UploadInput(fileURL: url, originalFilename: filename, source: .filePicker)
            let days = deleteAfter.map(\.rawValue)
            if let days, days > 0 {
                let target = config ?? manager.routedDestination(for: input)
                guard let target, ExpiryRuleStore.shared.isActive(target.id) else {
                    throw AktarIntentError(String(localized: "Auto-delete isn\u{2019}t set up for this destination. Set it up from Aktar\u{2019}s menu bar (Delete after) or the destination\u{2019}s settings."))
                }
            }
            links.append(try await AktarIntentSupport.link(manager.uploadAndWait(input, to: config, expiryDays: days), manager: manager))
        }
        return .result(value: links)
    }
}

struct UploadClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload Clipboard"
    static let description = IntentDescription("Uploads the file or image on the clipboard with Aktar and returns its link.")
    static let openAppWhenRun = false

    @Parameter(title: "Destination", description: "Leave empty to use \u{201C}Use for\u{201D} and the default destination.")
    var destination: DestinationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Upload the clipboard to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let manager = try AktarIntentSupport.manager()
        let config = try AktarIntentSupport.destination(destination)
        guard let input = ClipboardService.readFileInput() else {
            throw AktarIntentError(String(localized: "The clipboard has no file or image to upload."))
        }
        defer { TempFiles.removeIfOwned(input.fileURL) }
        return .result(value: try await AktarIntentSupport.link(manager.uploadAndWait(input, to: config), manager: manager))
    }
}

struct ReplaceFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Replace File"
    static let description = IntentDescription("Writes a new file over an upload, so its link keeps working, and returns the link.")
    static let openAppWhenRun = false

    @Parameter(title: "Upload")
    var upload: UploadEntity

    @Parameter(title: "File")
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Replace \(\.$upload) with \(\.$file)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        let manager = try AktarIntentSupport.manager()
        guard let record = AppState.current?.repository.record(id: upload.id) else {
            throw AktarIntentError(String(localized: "That upload is no longer in Aktar\u{2019}s history."))
        }
        let folder = try AktarIntentSupport.stagingFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(file.filename)
        try file.data.write(to: url)
        return .result(value: try await AktarIntentSupport.link(manager.replaceAndWait(record, with: url), manager: manager))
    }
}

struct GetRecentUploadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Uploads"
    static let description = IntentDescription("Returns your most recent uploads with their links.")
    static let openAppWhenRun = false

    @Parameter(title: "Count", default: 10, inclusiveRange: (1, 200))
    var count: Int

    @Parameter(title: "Destination")
    var destination: DestinationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the last \(\.$count) uploads to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[UploadEntity]> {
        let records = AktarIntentSupport.recentRecords(limit: count, destinationID: destination?.id)
        return .result(value: records.map { UploadEntity($0) })
    }
}

struct AktarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UploadClipboardIntent(),
            phrases: ["Upload the clipboard with \(.applicationName)"],
            shortTitle: "Upload Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: GetRecentUploadsIntent(),
            phrases: ["Show my \(.applicationName) uploads"],
            shortTitle: "Recent Uploads",
            systemImageName: "clock"
        )
    }
}

// MARK: - Support

struct AktarIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
enum AktarIntentSupport {
    static func manager() throws -> UploadManager {
        guard let manager = AppState.current?.uploadManager else {
            throw AktarIntentError(String(localized: "Aktar isn\u{2019}t ready yet. Try again in a moment."))
        }
        return manager
    }

    /// The destination picked in the action, or nil for routing.
    static func destination(_ entity: DestinationEntity?) throws -> DestinationConfig? {
        guard let entity else { return nil }
        guard let destination = AppState.current?.destinationStore.destinations.first(where: { $0.id == entity.id }) else {
            throw AktarIntentError(String(localized: "That destination was removed from Aktar."))
        }
        return destination
    }

    /// A folder of its own in Aktar's temporary folders, removed by the
    /// caller (and at the next launch if it isn't).
    static func stagingFolder() throws -> URL {
        try TempFiles.newFolder(in: TempFiles.intents)
    }

    /// The link copying the upload gives: a temporary link when its
    /// destination is set to one, otherwise the public URL.
    static func link(_ result: UploadWaitResult?, manager: UploadManager) async throws -> URL {
        switch result {
        case .succeeded(let record, _):
            guard let link = await manager.shareLink(for: record) else {
                throw AktarIntentError(String(localized: "The upload finished but its link isn\u{2019}t valid."))
            }
            return link
        case .failed(let message):
            throw AktarIntentError(message)
        case .cancelled:
            throw AktarIntentError(String(localized: "The upload was cancelled in Aktar."))
        case nil:
            throw AktarIntentError(String(localized: "No destination to upload to. Add one in Aktar\u{2019}s Settings."))
        }
    }

    static func recentRecords(limit: Int, destinationID: UUID?) -> [UploadRecord] {
        guard let repository = AppState.current?.repository else { return [] }
        var descriptor = FetchDescriptor<UploadRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let destinationID {
            descriptor.predicate = #Predicate { $0.destinationID == destinationID }
        }
        descriptor.fetchLimit = limit
        return (try? repository.modelContext.fetch(descriptor)) ?? []
    }
}
