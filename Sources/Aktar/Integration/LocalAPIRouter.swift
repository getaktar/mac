import AppKit
import Foundation
import SwiftData

/// Maps local API requests onto the same pieces the app's own UI uses, so
/// an upload started from Raycast shows up in the panel, lands in history,
/// and follows the Output settings exactly like one dropped on the menu bar.
///
///     GET    /v1/status
///     GET    /v1/destinations
///     GET    /v1/uploads?query=&destinationId=&limit=
///     POST   /v1/uploads?filename=&destinationId=&prefix=&expires=     (raw file bytes; "reused" in the reply)
///     POST   /v1/uploads/clipboard?destinationId=&expires=
///     DELETE /v1/uploads/{id}
///     GET    /v1/uploads/{id}/thumbnail?px=&generate=             (PNG; 204 when there's none)
///     GET    /v1/destinations/{id}/objects?prefix=&continuationToken=
///     DELETE /v1/destinations/{id}/objects?key=
///     POST   /v1/destinations/{id}/objects/move                {"from", "to"}
///     POST   /v1/destinations/{id}/folders                     {"prefix", "name"}
///     POST   /v1/destinations/{id}/links                       {"key", "expiresIn"}
///     GET    /v1/destinations/{id}/thumbnail?key=&objectSize=&lastModified=&px=&generate=  (PNG; 204 when there's none)
///
/// A thumbnail that doesn't exist yet is made, which can mean downloading
/// the file (up to 25 MB); `generate=0` only returns one that's at hand, for
/// asking about many files at once.
///     GET    /v1/watched-folders
///     POST   /v1/watched-folders/pause                         {"minutes"} (omitted or null: until resumed)
///     POST   /v1/watched-folders/resume
///     POST   /v1/watched-folders/{id}                          {"enabled"}
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
        case ("GET", 3) where route[0] == "uploads" && route[2] == "thumbnail":
            return await uploadThumbnail(id: route[1], request: request)
        case ("GET", 1) where route[0] == "watched-folders":
            return .json(200, watchedFoldersDTO())
        case ("POST", 2) where route == ["watched-folders", "pause"]:
            return pauseWatching(request)
        case ("POST", 2) where route == ["watched-folders", "resume"]:
            appState.watchService.resume()
            return .json(200, watchedFoldersDTO())
        case ("POST", 2) where route[0] == "watched-folders":
            return setWatchedFolderEnabled(id: route[1], request: request)
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
            outputFormat: appState.uploadManager.outputMode.rawValue,
            watching: .init(paused: appState.watchService.isPaused, folders: appState.watchService.folders.count)
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

    // MARK: - Thumbnails

    /// The thumbnail of an upload, as the app shows it (made or fetched now
    /// if it has none yet), unless thumbnails are off for its destination.
    private func uploadThumbnail(id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let uuid = UUID(uuidString: id), let record = record(id: uuid) else {
            return .error(404, "No upload with that ID.")
        }
        let destination = destination(id: record.destinationID.uuidString)
        if destination?.thumbnailMode == .off { return .noContent }
        if ThumbnailStore.shared.image(for: uuid) == nil, let destination, Self.generates(request) {
            await RemoteThumbnailLoader.shared.loadThumbnail(for: record, destination: destination)
        }
        return Self.thumbnailResponse(ThumbnailStore.shared.image(for: uuid), request: request)
    }

    private static func generates(_ request: HTTPRequest) -> Bool {
        !["0", "false"].contains(request.query["generate"] ?? "")
    }

    /// PNG (any image viewer and Raycast can show it), its longest side at
    /// most `px` (default 128, up to 512) pixels; 204 for no thumbnail.
    private static func thumbnailResponse(_ image: NSImage?, request: HTTPRequest) -> HTTPResponse {
        let px = min(max(Int(request.query["px"] ?? "") ?? 128, 16), ThumbnailGenerator.maxPixelSize)
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let resized = ImageProcessor.resize(cgImage, longestSide: px),
              let png = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else {
            return .noContent
        }
        return HTTPResponse(status: 200, body: png, contentType: "image/png")
    }

    // MARK: - Watched folders

    private func pauseWatching(_ request: HTTPRequest) -> HTTPResponse {
        var minutes: Int?
        if !request.body.isEmpty {
            do {
                minutes = try decode(PauseBody.self, from: request).minutes
            } catch {
                return .error(400, "Invalid request body: \(error.localizedDescription)")
            }
        }
        if let minutes, minutes <= 0 {
            return .error(400, "minutes must be a positive number, or null to pause until resumed.")
        }
        appState.watchService.pause(minutes: minutes)
        return .json(200, watchedFoldersDTO())
    }

    private func setWatchedFolderEnabled(id: String, request: HTTPRequest) -> HTTPResponse {
        let service = appState.watchService
        guard let folder = service.folders.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            return .error(404, "No watched folder with that ID.")
        }
        guard let body = try? decode(EnabledBody.self, from: request) else {
            return .error(400, "The body must be {\"enabled\": true} or {\"enabled\": false}.")
        }
        service.setEnabled(body.enabled, folderID: folder.id)
        guard let updated = service.store.folder(id: folder.id) else { return .error(404, "No watched folder with that ID.") }
        return .json(200, watchedFolderDTO(updated))
    }

    private func watchedFoldersDTO() -> WatchedFoldersDTO {
        let service = appState.watchService
        let pausedUntil: String? = switch service.manualPause {
        case .until(let date): WatchDates.format(date)
        case .forever: "forever"
        case nil: nil
        }
        return WatchedFoldersDTO(
            paused: service.isPaused,
            pausedUntil: pausedUntil,
            folders: service.folders.map(watchedFolderDTO)
        )
    }

    private func watchedFolderDTO(_ folder: WatchedFolder) -> WatchedFolderDTO {
        let service = appState.watchService
        let engine = service.engine(id: folder.id)
        return WatchedFolderDTO(
            id: folder.id.uuidString,
            name: folder.name,
            path: folder.path,
            enabled: folder.enabled,
            status: service.status(for: folder).rawValue,
            destinationID: folder.destinationID?.uuidString,
            waiting: engine?.waitingCount ?? 0,
            uploading: engine?.uploadingCount ?? 0,
            failed: engine?.failedCount ?? service.ledger.count(folderID: folder.id, state: .failed),
            awaitingConfirmation: engine?.awaitingConfirmation ?? 0,
            onDelete: folder.onDelete.rawValue,
            confirmDelete: folder.confirmDelete,
            deleting: engine?.deletingCount ?? 0,
            awaitingDeleteConfirmation: engine?.awaitingDeleteConfirmation ?? 0,
            lastUploadAt: (engine?.lastUploadAt ?? service.ledger.lastUploadAt(folderID: folder.id)).map(WatchDates.format)
        )
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
            if let problem = Self.problem(withFolder: rawPrefix) { return .error(400, "prefix: \(problem)") }
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
                // `reused`: nothing was uploaded, the same file was already
                // there and this is its earlier upload.
                return .json(201, ["upload": uploadDTO(record, reused: job.reused)])
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
        let thumbnailPrefixes = appState.uploadManager.thumbnailPrefixes(for: destination)

        do {
            switch (request.method, route) {
            case ("GET", ["objects"]):
                let prefix = Self.normalizedFolder(request.query["prefix"] ?? "")
                let token = request.query["continuationToken"].flatMap { $0.isEmpty ? nil : $0 }
                let page = try await storage.list(prefix: prefix, continuationToken: token)
                // Thumbnail folders are Aktar's own, as in the bucket view.
                let listing = BucketListing(
                    prefix: page.prefix,
                    folders: page.folders.filter { !ThumbnailKeys.isHiddenFolder($0, prefixes: thumbnailPrefixes) },
                    objects: page.objects.filter { !ThumbnailKeys.isThumbnail($0.key, prefixes: thumbnailPrefixes) },
                    nextContinuationToken: page.nextContinuationToken
                )
                return .json(200, listingDTO(listing, destination: destination))

            case ("GET", ["thumbnail"]):
                guard let key = request.query["key"], !key.isEmpty else {
                    return .error(400, "The key query parameter is required.")
                }
                if let problem = Self.problem(withExistingKey: key) { return .error(400, "key: \(problem)") }
                guard destination.thumbnailMode != .off else { return .noContent }
                // The listing gives both; without them the bucket is asked.
                var object: BucketObject
                if let size = request.query["objectSize"].flatMap(Int64.init) {
                    let modified = request.query["lastModified"].flatMap { try? Date($0, strategy: .iso8601) }
                    object = BucketObject(key: key, size: size, lastModified: modified)
                } else {
                    guard let info = try await storage.objectInfo(key: key) else { return .error(404, "No object with that key.") }
                    object = BucketObject(key: key, size: info.size, lastModified: info.lastModified)
                }
                let image = await RemoteThumbnailLoader.shared.image(
                    for: object, destination: destination, prefixes: thumbnailPrefixes, allowDownload: Self.generates(request)
                )
                return Self.thumbnailResponse(image, request: request)

            case ("DELETE", ["objects"]):
                guard let key = request.query["key"], !key.isEmpty else {
                    return .error(400, "The key query parameter is required.")
                }
                if let problem = Self.problem(withExistingKey: key) { return .error(400, "key: \(problem)") }
                try await BucketThumbnails.delete(for: key, prefixes: thumbnailPrefixes, provider: storage)
                try await storage.delete(objectKey: key)
                RemoteThumbnailLoader.shared.forget(destinationID: destination.id, key: key)
                appState.repository.objectDeleted(key: key, destinationID: destination.id)
                return .json(200, ["deleted": key])

            case ("POST", ["objects", "move"]):
                let body = try decode(MoveBody.self, from: request)
                let newKey = body.to.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newKey.isEmpty, newKey != body.from else {
                    return .error(400, "Pick a different name or folder.")
                }
                if let problem = Self.problem(withExistingKey: body.from) { return .error(400, "from: \(problem)") }
                if let problem = Self.problem(withKey: newKey) { return .error(400, "to: \(problem)") }
                if ThumbnailKeys.isThumbnail(newKey, prefixes: thumbnailPrefixes) {
                    return .error(400, "to: That folder holds this bucket's thumbnails.")
                }
                if try await storage.objectExists(key: newKey) {
                    return .error(409, "An object named \u{201C}\(newKey)\u{201D} already exists.")
                }
                try await storage.copy(from: body.from, to: newKey)
                await BucketThumbnails.copy(from: body.from, to: newKey, prefixes: thumbnailPrefixes, provider: storage)
                try await BucketThumbnails.delete(for: body.from, prefixes: thumbnailPrefixes, provider: storage)
                try await storage.delete(objectKey: body.from)
                RemoteThumbnailLoader.shared.forget(destinationID: destination.id, key: body.from)
                appState.repository.objectMoved(
                    from: body.from,
                    to: newKey,
                    destination: destination,
                    rulesActive: ExpiryRuleStore.shared.isActive(destination.id)
                )
                return .json(200, objectDTO(BucketObject(key: newKey, size: 0, lastModified: .now), destination: destination))

            case ("POST", ["folders"]):
                let body = try decode(FolderBody.self, from: request)
                var name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let problem = ObjectKeyGenerator.problem(withUserKey: name, allowsTrailingSlash: true) {
                    return .error(400, "name: \(problem.errorDescription ?? "")")
                }
                if let problem = Self.problem(withFolder: body.prefix ?? "") { return .error(400, "prefix: \(problem)") }
                while name.hasSuffix("/") { name.removeLast() }
                guard !name.isEmpty else { return .error(400, "The folder name is required.") }
                let folder = Self.normalizedFolder(body.prefix ?? "") + name + "/"
                try await storage.createFolder(prefix: folder)
                return .json(201, FolderDTO(prefix: folder))

            case ("POST", ["links"]):
                let body = try decode(LinkBody.self, from: request)
                if let problem = Self.problem(withExistingKey: body.key) { return .error(400, "key: \(problem)") }
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

    /// Why a folder prefix can't be used, or nil. A lone "/" is the bucket
    /// root, as the Raycast extension sends it.
    private static func problem(withFolder raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return ObjectKeyGenerator.problem(withUserKey: trimmed, allowsTrailingSlash: true)?.errorDescription
    }

    /// Why the key of an object that's already there can't be used, or nil.
    /// Buckets can hold keys with empty segments or a leading "/", so only
    /// what could be resolved to another object is refused.
    private static func problem(withExistingKey key: String) -> String? {
        if ObjectKeyGenerator.problem(withUserKey: key) == .controlCharacter {
            return UserKeyProblem.controlCharacter.errorDescription
        }
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        return segments.contains { $0 == "." || $0 == ".." } ? UserKeyProblem.dotSegment.errorDescription : nil
    }

    /// Why a new object key can't be used, or nil.
    private static func problem(withKey key: String) -> String? {
        if let problem = ObjectKeyGenerator.problem(withUserKey: key) { return problem.errorDescription }
        return key.hasSuffix("/") ? "A key can\u{2019}t end with \u{201C}/\u{201D}." : nil
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
        uploadDTO(record, reused: nil)
    }

    private func uploadDTO(_ record: UploadRecord, reused: Bool?) -> UploadDTO {
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
            formats: .init(url: formatted(.url), markdown: formatted(.markdown), html: formatted(.html), custom: formatted(.custom)),
            reused: reused
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
            url: hasPublicURL ? PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: object.key)?.absoluteString : nil
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
    let watching: Watching

    struct Watching: Encodable {
        let paused: Bool
        let folders: Int
    }
}

/// Nulls are written out, as the Windows app does.
private struct WatchedFoldersDTO: Encodable {
    let paused: Bool
    let pausedUntil: String?
    let folders: [WatchedFolderDTO]

    private enum CodingKeys: String, CodingKey { case paused, pausedUntil, folders }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paused, forKey: .paused)
        try c.encode(pausedUntil, forKey: .pausedUntil)
        try c.encode(folders, forKey: .folders)
    }
}

private struct WatchedFolderDTO: Encodable {
    let id: String
    let name: String
    let path: String
    let enabled: Bool
    let status: String
    let destinationID: String?
    let waiting: Int
    let uploading: Int
    let failed: Int
    let awaitingConfirmation: Int
    let onDelete: String
    let confirmDelete: Bool
    let deleting: Int
    let awaitingDeleteConfirmation: Int
    let lastUploadAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, path, enabled, status, destinationID, waiting, uploading, failed, awaitingConfirmation
        case onDelete, confirmDelete, deleting, awaitingDeleteConfirmation, lastUploadAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(status, forKey: .status)
        try c.encode(destinationID, forKey: .destinationID)
        try c.encode(waiting, forKey: .waiting)
        try c.encode(uploading, forKey: .uploading)
        try c.encode(failed, forKey: .failed)
        try c.encode(awaitingConfirmation, forKey: .awaitingConfirmation)
        try c.encode(onDelete, forKey: .onDelete)
        try c.encode(confirmDelete, forKey: .confirmDelete)
        try c.encode(deleting, forKey: .deleting)
        try c.encode(awaitingDeleteConfirmation, forKey: .awaitingDeleteConfirmation)
        try c.encode(lastUploadAt, forKey: .lastUploadAt)
    }
}

private struct PauseBody: Decodable {
    let minutes: Int?
}

private struct EnabledBody: Decodable {
    let enabled: Bool
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
    /// Only in the response to an upload.
    let reused: Bool?
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
