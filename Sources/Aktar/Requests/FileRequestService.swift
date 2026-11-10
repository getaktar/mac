import Foundation
import Observation

/// File requests (docs/share-pages.md, part 4): making their links,
/// collecting what's sent through them into history, and closing them.
@MainActor
@Observable
final class FileRequestService {
    let store: FileRequestStore
    @ObservationIgnored private let uploadManager: UploadManager
    @ObservationIgnored private let destinationStore: DestinationStore
    /// Requests being checked right now, so two checks never collect the
    /// same slot.
    private(set) var checking: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?

    /// How often open requests are checked while Aktar runs.
    static let checkInterval: TimeInterval = 120

    init(uploadManager: UploadManager, destinationStore: DestinationStore, store: FileRequestStore = FileRequestStore()) {
        self.uploadManager = uploadManager
        self.destinationStore = destinationStore
        self.store = store
    }

    /// Checks at launch, then every 2 minutes.
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    // MARK: - Creating

    struct Draft {
        var destination: DestinationConfig
        var title = ""
        var note = ""
        var duration = FileRequests.defaultDuration
        var slots = FileRequests.defaultSlots
        var maxBytes = FileRequests.defaultMaxBytes
    }

    enum CreateError: LocalizedError {
        /// The bucket doesn't let browsers on `origin` upload to it.
        case cors(origin: String, reason: String)
        case other(String)

        var errorDescription: String? {
            switch self {
            case .cors(let origin, _):
                return String(localized: "This bucket doesn\u{2019}t let browsers upload to it. Allow PUT from \(origin) in its CORS settings, then try again.")
            case .other(let message):
                return message
            }
        }
    }

    /// Where the page is served from and where the browser sends the
    /// files: the public base URL (or the S3 endpoint, for a destination
    /// that copies temporary links) and the S3 endpoint.
    static func origins(for destination: DestinationConfig, provider: S3Provider, id: String) throws -> (page: String?, upload: String?) {
        let uploadOrigin = SharePages.origin(of: try provider.endpointURL(for: FileRequests.fileKey(id: id, slot: 1)).absoluteString)
        let pageOrigin = destination.temporaryLink != nil
            ? SharePages.origin(of: try provider.endpointURL(for: FileRequests.pageKey(id: id)).absoluteString)
            : SharePages.origin(of: destination.publicBaseURL)
        return (pageOrigin, uploadOrigin)
    }

    /// Makes the request: CORS when the page and the bucket are on
    /// different origins, the presigned slots, the page. Its link is
    /// returned (and kept with the request); nothing is created when any
    /// step fails. `corsDoneByHand`: the user added the CORS rule in the
    /// provider's dashboard (a key that can't read or write CORS).
    func create(_ draft: Draft, corsDoneByHand: Bool = false) async throws -> FileRequest {
        var destination = draft.destination
        let credentials: StorageCredentials
        do {
            credentials = try KeychainService.load(for: destination.id)
        } catch {
            throw CreateError.other((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let provider = S3Provider(config: destination, credentials: credentials)
        let id = FileRequests.newID()
        let seconds = Int64(min(draft.duration, 7 * 86_400))
        let origins = try Self.origins(for: destination, provider: provider, id: id)

        if let pageOrigin = origins.page, pageOrigin != origins.upload, destination.requestCorsOrigin != pageOrigin {
            if !corsDoneByHand {
                do {
                    try await provider.ensureCORSRule(origin: pageOrigin)
                } catch {
                    throw CreateError.cors(origin: pageOrigin, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            destination.requestCorsOrigin = pageOrigin
            destinationStore.update(destination)
        }

        let conditional = ShortKeys.usesConditionalWrites(destination.preset)
        var slots: [SharePage.Request.Slot] = []
        for slot in 1...max(1, draft.slots) {
            let file = try await provider.presignedPUT(for: FileRequests.fileKey(id: id, slot: slot), contentType: "application/octet-stream", ifNoneMatch: conditional, expiresIn: seconds)
            let meta = try await provider.presignedPUT(for: FileRequests.metadataKey(id: id, slot: slot), contentType: "application/json", ifNoneMatch: conditional, expiresIn: seconds)
            slots.append(.init(file: file.absoluteString, meta: meta.absoluteString))
        }
        let now = Date.now
        let expiresAt = now.addingTimeInterval(TimeInterval(seconds))
        let title = String(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FileRequests.maxTitleLength))
        let note = String(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FileRequests.maxNoteLength))
        let page = SharePage(
            kind: .request, lang: UploadManager.pageLanguage, created: now, expires: expiresAt,
            request: .init(title: title, note: note, maxBytes: draft.maxBytes, conditional: conditional, slots: slots)
        )
        let pageKey = FileRequests.pageKey(id: id)
        do {
            try await uploadManager.writePage(page, key: pageKey, provider: provider)
        } catch {
            throw CreateError.other((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        // A temporary-link destination signs the page for the request's
        // own duration.
        let link: URL
        if destination.temporaryLink != nil {
            link = try await provider.temporaryURL(for: pageKey, expiresIn: seconds)
        } else if let url = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: pageKey) {
            link = url
        } else {
            throw StorageError.invalidPublicBaseURL
        }
        let request = FileRequest(
            id: id, destinationId: destination.id, title: title, note: note, createdAt: now, expiresAt: expiresAt,
            slotCount: slots.count, maxBytes: draft.maxBytes, link: link.absoluteString, received: 0, closedAt: nil
        )
        store.add(request)
        return request
    }

    // MARK: - Collecting

    /// Checks every open request; ones an hour past their expiry get a
    /// last check and are closed.
    func checkAll() async {
        for request in store.open {
            await check(request)
            if let current = store.request(id: request.id), current.isOpen, current.isDueToClose() {
                try? await close(current)
            }
        }
    }

    /// Collects what's arrived: each slot whose file and metadata are both
    /// there (or whose file waited 10 minutes) goes through the
    /// destination's normal upload, then leaves the request's prefix. One
    /// notification for all of a check's files. Returns how many came in.
    @discardableResult
    func check(_ request: FileRequest) async -> Int {
        guard request.isOpen, !checking.contains(request.id),
              let destination = destinationStore.destinations.first(where: { $0.id == request.destinationId }),
              let credentials = try? KeychainService.load(for: destination.id) else { return 0 }
        checking.insert(request.id)
        defer { checking.remove(request.id) }
        let provider = S3Provider(config: destination, credentials: credentials)
        guard let objects = try? await listAll(prefix: FileRequests.prefix(id: request.id), provider: provider) else { return 0 }

        var collected = 0
        for ready in FileRequests.readySlots(in: objects, id: request.id, slotCount: request.slotCount) {
            let fileKey = ready.file.key
            let metaKey = FileRequests.metadataKey(id: request.id, slot: ready.slot)
            // The page enforces the limit; a bigger file is deleted unread.
            if ready.file.size > request.maxBytes + FileRequests.sizeSlack {
                try? await provider.delete(objectKeys: [fileKey, metaKey])
                continue
            }
            var name: String?
            if ready.metadata != nil,
               let meta = try? await provider.getObject(key: metaKey, maxBytes: FileRequests.maxMetadataBytes) {
                name = FileRequests.metadataName(meta.data)
            }
            let filename = FileRequests.sanitizedName(name, slot: ready.slot)
            guard let folder = try? TempFiles.newFolder(in: TempFiles.requests),
                  let fileURL = TempFiles.fileURL(named: filename, in: folder) else { continue }
            do {
                guard try await provider.download(key: fileKey, to: fileURL, maxBytes: request.maxBytes + FileRequests.sizeSlack) else {
                    try? FileManager.default.removeItem(at: folder)
                    continue
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            var input = UploadInput(fileURL: fileURL, originalFilename: filename, source: .filePicker)
            input.request = RequestUploadContext(id: request.id, title: request.title)
            guard case .succeeded? = await uploadManager.uploadAndWait(input, to: destination) else {
                // Left in the bucket for the next check.
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            try? FileManager.default.removeItem(at: folder)
            try? await provider.delete(objectKeys: [fileKey, metaKey])
            collected += 1
            if var current = store.request(id: request.id) {
                current.received += 1
                store.update(current)
            }
        }
        if collected > 0 {
            NotificationService.notifyRequestReceived(count: collected, title: request.title)
        }
        return collected
    }

    private func listAll(prefix: String, provider: S3Provider) async throws -> [BucketObject] {
        var objects: [BucketObject] = []
        var token: String?
        repeat {
            let page = try await provider.listRecursively(prefix: prefix, continuationToken: token)
            objects += page.objects
            token = page.nextContinuationToken
        } while token != nil
        return objects
    }

    // MARK: - Closing

    /// Close Now, and the close after the last check: what's left under the
    /// prefix goes, the page included, so the link stops working at once.
    func close(_ request: FileRequest) async throws {
        guard let destination = destinationStore.destinations.first(where: { $0.id == request.destinationId }) else {
            markClosed(request)
            return
        }
        let provider = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        let objects = try await listAll(prefix: FileRequests.prefix(id: request.id), provider: provider)
        // The page first: from then on nothing more can be sent.
        try await provider.delete(objectKey: FileRequests.pageKey(id: request.id))
        try await provider.delete(objectKeys: objects.map(\.key).filter { $0 != FileRequests.pageKey(id: request.id) })
        markClosed(request)
    }

    /// A destination that's about to be removed: its requests close, and
    /// their prefixes are emptied in the background with its keys as they
    /// are now.
    func closeRequests(of destination: DestinationConfig) {
        let open = store.open.filter { $0.destinationId == destination.id }
        guard !open.isEmpty else { return }
        let credentials = try? KeychainService.load(for: destination.id)
        for request in open { markClosed(request) }
        guard let credentials else { return }
        let provider = S3Provider(config: destination, credentials: credentials)
        Task {
            for request in open {
                guard let objects = try? await listAll(prefix: FileRequests.prefix(id: request.id), provider: provider) else { continue }
                try? await provider.delete(objectKeys: objects.map(\.key))
            }
        }
    }

    /// Forgets a closed request.
    func remove(_ request: FileRequest) {
        guard !request.isOpen else { return }
        store.remove(id: request.id)
    }

    private func markClosed(_ request: FileRequest) {
        guard var current = store.request(id: request.id) else { return }
        current.closedAt = .now
        store.update(current)
    }
}
