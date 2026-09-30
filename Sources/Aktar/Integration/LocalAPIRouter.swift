import Foundation
import SwiftData

/// Maps local API requests onto the same pieces the app's own UI uses, so
/// an upload started from Raycast shows up in the panel, lands in history,
/// and follows the Output settings exactly like one dropped on the menu bar.
///
///     GET    /v1/status
///     GET    /v1/destinations
///     GET    /v1/uploads?query=&destinationId=&limit=
///     POST   /v1/uploads?filename=&destinationId=&prefix=&expires=     (raw file bytes)
///     POST   /v1/uploads/clipboard?destinationId=&expires=
///     DELETE /v1/uploads/{id}
///     GET    /v1/destinations/{id}/objects?prefix=&continuationToken=
///     DELETE /v1/destinations/{id}/objects?key=
///     POST   /v1/destinations/{id}/objects/move                {"from", "to"}
///     POST   /v1/destinations/{id}/folders                     {"prefix", "name"}
///     POST   /v1/destinations/{id}/links                       {"key", "expiresIn"}
@MainActor
final class LocalAPIRouter {
    static let apiVersion = 1

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "v1" else { return .error(404, "Not found.") }
        let route = Array(parts.dropFirst())

        switch (request.method, route.count) {
        case ("GET", 1) where route[0] == "status":
            return status()
        case ("GET", 1) where route[0] == "destinations":
            return .json(200, ["destinations": appState.destinationStore.destinations.map(destinationDTO)])
        case ("GET", 1) where route[0] == "uploads":
            return listUploads(request)
        case ("POST", 1) where route[0] == "uploads":
            return await uploadBody(request)
        case ("POST", 2) where route == ["uploads", "clipboard"]:
            return await uploadClipboard(request)
        case ("DELETE", 2) where route[0] == "uploads":
            return await deleteUpload(id: route[1])
        case (_, 3...) where route[0] == "destinations":
            guard let destination = destination(id: route[1]) else {
                return .error(404, "No destination with that ID.")
            }
            return await handleBucket(request, destination: destination, route: Array(route.dropFirst(2)))
        default:
            return .error(404, "Not found.")
        }
    }

    // MARK: - Status & history

    private func status() -> HTTPResponse {
        let info = Bundle.main.infoDictionary
        return .json(200, StatusDTO(
            app: "Aktar",
            version: info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "",
            apiVersion: Self.apiVersion,
            defaultDestinationId: appState.destinationStore.defaultDestination?.id.uuidString,
            outputFormat: appState.uploadManager.outputMode.rawValue
        ))
    }

    private func listUploads(_ request: HTTPRequest) -> HTTPResponse {
        let limit = min(max(Int(request.query["limit"] ?? "") ?? 200, 1), 1000)
        let query = request.query["query"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let destinationID = request.query["destinationId"].flatMap(UUID.init(uuidString:))

        var descriptor = FetchDescriptor<UploadRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if query.isEmpty, destinationID == nil {
            descriptor.fetchLimit = limit
        }
        let records = (try? appState.repository.modelContext.fetch(descriptor)) ?? []
        let matching = records.lazy
            .filter { destinationID == nil || $0.destinationID == destinationID }
            .filter {
                query.isEmpty
                    || $0.localFilename.localizedCaseInsensitiveContains(query)
                    || $0.objectKey.localizedCaseInsensitiveContains(query)
            }
            .prefix(limit)
        return .json(200, ["uploads": Array(matching).map(uploadDTO)])
    }

    private func deleteUpload(id: String) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id), let record = record(id: uuid) else {
            return .error(404, "No upload with that ID.")
        }
        do {
            try await appState.uploadManager.deleteRemote(record)
            return .json(200, ["deleted": id])
        } catch {
            return failure(error)
        }
    }

    // MARK: - Uploading

    /// The sandbox keeps Aktar from reading arbitrary paths, so callers send
    /// the file's bytes rather than its path. They're written back out under
    /// the original name (content type comes from the extension) and handed
    /// to the upload manager like any other file.
    private func uploadBody(_ request: HTTPRequest) async -> HTTPResponse {
        let filename = (request.query["filename"] ?? "").split(separator: "/").last.map(String.init) ?? ""
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            return .error(400, "The filename query parameter is required.")
        }
        guard let destination = destination(id: request.query["destinationId"]) else {
            return .error(404, "No destination to upload to. Add one in Aktar's Settings.")
        }
        guard let expiryDays = Self.expiryDays(request) else {
            return .error(400, Self.invalidExpiryMessage)
        }
        if expiryDays > 0, !ExpiryRuleStore.shared.isActive(destination.id) {
            return .error(409, Self.expiryNotSetUpMessage)
        }
        if expiryDays > 0, request.query["prefix"] != nil {
            return .error(400, "The expires and prefix query parameters can't be combined.")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarLocalAPI", isDirectory: true)
            .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let bodyFile = request.bodyFile {
                try FileManager.default.moveItem(at: bodyFile, to: fileURL)
            } else {
                try request.body.write(to: fileURL)
            }
        } catch {
            return .error(500, "Could not stage the file for upload.")
        }

        var input = UploadInput(fileURL: fileURL, originalFilename: filename, source: .filePicker)
        if let rawPrefix = request.query["prefix"] {
            let prefix = Self.normalizedFolder(rawPrefix)
            do {
                input.objectKey = try await availableKey(for: filename, in: prefix, destination: destination)
            } catch {
                return failure(error)
            }
        }
        return await run(input, to: destination, expiryDays: expiryDays)
    }

    private func uploadClipboard(_ request: HTTPRequest) async -> HTTPResponse {
        guard let destination = destination(id: request.query["destinationId"]) else {
            return .error(404, "No destination to upload to. Add one in Aktar's Settings.")
        }
        guard let expiryDays = Self.expiryDays(request) else {
            return .error(400, Self.invalidExpiryMessage)
        }
        if expiryDays > 0, !ExpiryRuleStore.shared.isActive(destination.id) {
            return .error(409, Self.expiryNotSetUpMessage)
        }
        guard let input = ClipboardService.readFileInput() else {
            return .error(422, "The clipboard has no file or image to upload.")
        }
        return await run(input, to: destination, expiryDays: expiryDays)
    }

    /// `expires` is in days. Leaving it out keeps the file, whatever the menu
    /// bar's "Delete after" is set to, so scripts are never surprised.
    private static func expiryDays(_ request: HTTPRequest) -> Int? {
        guard let raw = request.query["expires"], !raw.isEmpty else { return 0 }
        guard let days = Int(raw), UploadExpiry.isValid(days) else { return nil }
        return days
    }

    private static let expiryNotSetUpMessage = "Auto-delete isn't set up for this destination. Set it up from Aktar's menu bar (Delete after) or the destination's settings."
    private static let invalidExpiryMessage = "expires must be 0, 1, 7, 14 or 30 (days)."

    /// Queues the upload and waits for it to settle, so the caller gets the
    /// finished history entry (and its links) back in the response.
    private func run(_ input: UploadInput, to destination: DestinationConfig, expiryDays: Int) async -> HTTPResponse {
        let manager = appState.uploadManager
        // One request, one upload: a folder (from the clipboard) always
        // goes up as a ZIP here, whatever the destination does with folders.
        var destination = destination
        if FolderUpload.isFolder(input.fileURL) { destination.folderUpload = .zip }
        manager.upload([input], to: destination, expiryDays: expiryDays)
        guard let job = manager.jobs.first(where: { $0.input.fileURL == input.fileURL }) else {
            return .error(500, "The upload could not be queued.")
        }
        while true {
            switch job.state {
            case .succeeded(let publicURLString):
                guard let record = record(publicURLString: publicURLString, destinationID: destination.id) else {
                    return .error(500, "The upload finished but its history entry is missing.")
                }
                return .json(201, ["upload": uploadDTO(record)])
            // The staged copy of the file is deleted once this returns, so
            // a failed job can't be retried from the panel; remove it and
            // let the caller (Raycast) show the error instead.
            case .failed(let message):
                manager.dismiss(job)
                return .error(502, message)
            case .cancelled:
                manager.dismiss(job)
                return .error(409, "The upload was cancelled in Aktar.")
            case .waiting, .uploading:
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    // MARK: - Bucket browsing

    private func handleBucket(_ request: HTTPRequest, destination: DestinationConfig, route: [String]) async -> HTTPResponse {
        let storage: S3Provider
        do {
            storage = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        } catch {
            return failure(error)
        }

        do {
            switch (request.method, route) {
            case ("GET", ["objects"]):
                let prefix = Self.normalizedFolder(request.query["prefix"] ?? "")
                let token = request.query["continuationToken"].flatMap { $0.isEmpty ? nil : $0 }
                let listing = try await storage.list(prefix: prefix, continuationToken: token)
                return .json(200, listingDTO(listing, destination: destination))

            case ("DELETE", ["objects"]):
                guard let key = request.query["key"], !key.isEmpty else {
                    return .error(400, "The key query parameter is required.")
                }
                try await storage.delete(objectKey: key)
                appState.repository.objectDeleted(key: key, destinationID: destination.id)
                return .json(200, ["deleted": key])

            case ("POST", ["objects", "move"]):
                let body = try decode(MoveBody.self, from: request)
                let newKey = body.to.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !newKey.isEmpty, newKey != body.from else {
                    return .error(400, "Pick a different name or folder.")
                }
                if try await storage.objectExists(key: newKey) {
                    return .error(409, "An object named \u{201C}\(newKey)\u{201D} already exists.")
                }
                try await storage.copy(from: body.from, to: newKey)
                try await storage.delete(objectKey: body.from)
                appState.repository.objectMoved(
                    from: body.from,
                    to: newKey,
                    destination: destination,
                    rulesActive: ExpiryRuleStore.shared.isActive(destination.id)
                )
                return .json(200, objectDTO(BucketObject(key: newKey, size: 0, lastModified: .now), destination: destination))

            case ("POST", ["folders"]):
                let body = try decode(FolderBody.self, from: request)
                let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !name.isEmpty else { return .error(400, "The folder name is required.") }
                let folder = Self.normalizedFolder(body.prefix ?? "") + name + "/"
                try await storage.createFolder(prefix: folder)
                return .json(201, FolderDTO(prefix: folder))

            case ("POST", ["links"]):
                let body = try decode(LinkBody.self, from: request)
                // SigV4 presigned URLs are capped at seven days.
                let seconds = min(max(body.expiresIn ?? 3600, 60), 604_800)
                let url = try await storage.temporaryURL(for: body.key, expiresIn: seconds)
                return .json(200, LinkDTO(url: url.absoluteString, expiresAt: Date.now.addingTimeInterval(TimeInterval(seconds))))

            default:
                return .error(404, "Not found.")
            }
        } catch let error as DecodingError {
            return .error(400, "Invalid request body: \(error.localizedDescription)")
        } catch {
            return failure(error)
        }
    }

    /// Same rule as the Library's bucket browser: keep the file's own name,
    /// adding " 2", " 3"… when it's taken so nothing gets overwritten.
    private func availableKey(for filename: String, in folder: String, destination: DestinationConfig) async throws -> String {
        let storage = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder + filename
        var counter = 2
        while try await storage.objectExists(key: candidate), counter < 1000 {
            candidate = folder + (ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Lookups

    private func destination(id: String?) -> DestinationConfig? {
        guard let id, !id.isEmpty else { return appState.destinationStore.defaultDestination }
        return appState.destinationStore.destinations.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func record(id: UUID) -> UploadRecord? {
        let descriptor = FetchDescriptor<UploadRecord>(predicate: #Predicate { $0.id == id })
        return try? appState.repository.modelContext.fetch(descriptor).first
    }

    private func record(publicURLString: String, destinationID: UUID) -> UploadRecord? {
        var descriptor = FetchDescriptor<UploadRecord>(
            predicate: #Predicate { $0.publicURLString == publicURLString && $0.destinationID == destinationID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? appState.repository.modelContext.fetch(descriptor).first
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest) throws -> T {
        try JSONDecoder().decode(type, from: request.body)
    }

    private func failure(_ error: Error) -> HTTPResponse {
        if let error = error as? KeychainError, case .notFound = error {
            return .error(409, error.errorDescription ?? "")
        }
        return .error(502, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// "" for the bucket root, otherwise "a/b/" with exactly one trailing slash.
    private static func normalizedFolder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    // MARK: - DTOs

    private func destinationDTO(_ destination: DestinationConfig) -> DestinationDTO {
        DestinationDTO(
            id: destination.id.uuidString,
            name: destination.name,
            provider: destination.preset.rawValue,
            providerName: destination.preset.displayName,
            bucket: destination.bucket,
            publicBaseURL: destination.publicBaseURL,
            isDefault: destination.id == appState.destinationStore.defaultDestination?.id
        )
    }

    private func uploadDTO(_ record: UploadRecord) -> UploadDTO {
        let url = record.publicURL
        let manager = appState.uploadManager
        func formatted(_ mode: OutputMode) -> String {
            guard let url else { return record.publicURLString }
            return OutputFormatter.format(publicURL: url, mode: mode, filename: record.localFilename, customTemplate: manager.customTemplate)
        }
        return UploadDTO(
            id: record.id.uuidString,
            filename: record.localFilename,
            objectKey: record.objectKey,
            url: url?.absoluteString ?? record.publicURLString,
            destinationId: record.destinationID.uuidString,
            destinationName: record.destinationName,
            mimeType: record.mimeType,
            size: record.byteSize,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            formats: .init(url: formatted(.url), markdown: formatted(.markdown), html: formatted(.html), custom: formatted(.custom))
        )
    }

    private func listingDTO(_ listing: BucketListing, destination: DestinationConfig) -> ListingDTO {
        ListingDTO(
            prefix: listing.prefix,
            folders: listing.folders.map(FolderDTO.init(prefix:)),
            objects: listing.objects.map { objectDTO($0, destination: destination) },
            nextContinuationToken: listing.nextContinuationToken
        )
    }

    private func objectDTO(_ object: BucketObject, destination: DestinationConfig) -> ObjectDTO {
        let hasPublicURL = !destination.publicBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        return ObjectDTO(
            key: object.key,
            name: object.name,
            size: object.size,
            lastModified: object.lastModified,
            url: hasPublicURL ? PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: object.key).absoluteString : nil
        )
    }
}

private struct StatusDTO: Encodable {
    let app: String
    let version: String
    let build: String
    let apiVersion: Int
    let defaultDestinationId: String?
    let outputFormat: String
}

private struct DestinationDTO: Encodable {
    let id: String
    let name: String
    let provider: String
    let providerName: String
    let bucket: String
    let publicBaseURL: String
    let isDefault: Bool
}

private struct UploadDTO: Encodable {
    struct Formats: Encodable {
        let url: String
        let markdown: String
        let html: String
        let custom: String
    }

    let id: String
    let filename: String
    let objectKey: String
    let url: String
    let destinationId: String
    let destinationName: String
    let mimeType: String
    let size: Int
    let createdAt: Date
    let expiresAt: Date?
    let formats: Formats
}

private struct ListingDTO: Encodable {
    let prefix: String
    let folders: [FolderDTO]
    let objects: [ObjectDTO]
    let nextContinuationToken: String?
}

private struct FolderDTO: Encodable {
    let prefix: String
    let name: String

    init(prefix: String) {
        self.prefix = prefix
        name = String(prefix.dropLast().split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }
}

private struct ObjectDTO: Encodable {
    let key: String
    let name: String
    let size: Int64
    let lastModified: Date?
    let url: String?
}

private struct LinkDTO: Encodable {
    let url: String
    let expiresAt: Date
}

private struct MoveBody: Decodable {
    let from: String
    let to: String
}

private struct FolderBody: Decodable {
    let prefix: String?
    let name: String
}

private struct LinkBody: Decodable {
    let key: String
    let expiresIn: Int64?
}
