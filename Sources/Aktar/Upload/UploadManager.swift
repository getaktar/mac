import Foundation
import Observation

/// Coordinates the upload pipeline: validate -> generate object key -> upload
/// -> resolve public URL -> store history -> format output -> copy clipboard
/// -> notify. Runs up to `maxConcurrent` jobs at once.
@MainActor
@Observable
final class UploadManager {
    private(set) var jobs: [UploadJob] = []
    private var activeCount = 0
    private let maxConcurrent = 3
    /// Folders uploaded with their structure that still have files going:
    /// what's been copied so far, by position in the folder.
    private var openGroups: [UUID: [Int: (link: URL, filename: String)]] = [:]

    /// Settings > Output: what's copied after an upload, unless the
    /// destination has its own choice.
    var outputMode: OutputMode = UserDefaults.standard.string(forKey: "outputMode").flatMap(OutputMode.init(rawValue:)) ?? .url {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") }
    }
    var customTemplate: String = UserDefaults.standard.string(forKey: "customTemplate") ?? "![{filename}]({url})" {
        didSet { UserDefaults.standard.set(customTemplate, forKey: "customTemplate") }
    }

    /// The last "Delete after" choice, in days (0 = keep), from before
    /// destinations kept their own. It still applies to a destination that
    /// hasn't had one picked yet.
    var expiryDays: Int = UserDefaults.standard.integer(forKey: UploadExpiry.defaultsKey) {
        didSet { UserDefaults.standard.set(expiryDays, forKey: UploadExpiry.defaultsKey) }
    }

    /// Settings > General: a file that's already in the destination is
    /// not uploaded again; its link is copied instead.
    static let reuseDuplicatesKey = "reuseDuplicateLinks"
    var reuseDuplicateLinks: Bool {
        UserDefaults.standard.object(forKey: Self.reuseDuplicatesKey) as? Bool ?? true
    }

    private let destinationStore: DestinationStore
    private let repository: UploadRepository

    init(destinationStore: DestinationStore, repository: UploadRepository) {
        self.destinationStore = destinationStore
        self.repository = repository
    }

    /// The "Delete after" choice that actually applies to `destination`:
    /// none until its bucket has Aktar's lifecycle rules.
    func effectiveExpiryDays(for destination: DestinationConfig?) -> Int {
        guard let destination, ExpiryRuleStore.shared.isActive(destination.id) else { return 0 }
        return expiryDays(for: destination)
    }

    /// The "Delete after" choice for `destination`, whether or not its
    /// bucket has the rules yet.
    func expiryDays(for destination: DestinationConfig) -> Int {
        destination.expiryDays ?? expiryDays
    }

    /// Picking "Delete after" in the menu bar sets it for that destination.
    func setExpiryDays(_ days: Int, for destination: DestinationConfig) {
        var destination = destination
        destination.expiryDays = days
        destinationStore.update(destination)
    }

    func outputMode(for destination: DestinationConfig) -> OutputMode {
        destination.outputMode ?? outputMode
    }

    /// Picking "Link" in the menu bar sets it for that destination.
    func setTemporaryLink(_ duration: TemporaryLinkDuration?, for destination: DestinationConfig) {
        var destination = destination
        destination.temporaryLink = duration
        destinationStore.update(destination)
    }

    /// A new temporary link to an uploaded file, for sharing it from
    /// history, e.g. when the bucket is private.
    func temporaryURL(for record: UploadRecord, validFor duration: TemporaryLinkDuration) async throws -> URL {
        guard let destination = destinationStore.destinations.first(where: { $0.id == record.destinationID }) else {
            throw StorageError.unknown(String(localized: "This upload's destination was removed."))
        }
        let provider = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        return try await provider.temporaryURL(for: record.objectKey, expiresIn: duration.rawValue)
    }

    /// The link copying an upload would give now: a fresh temporary link
    /// when its destination is set to them, otherwise the public URL
    /// (also when the destination is gone or signing fails).
    func shareLink(for record: UploadRecord) async -> URL? {
        if let destination = destinationStore.destinations.first(where: { $0.id == record.destinationID }),
           let duration = destination.temporaryLink,
           let url = try? await temporaryURL(for: record, validFor: duration) {
            return url
        }
        return record.publicURL
    }

    /// `expiryDays` overrides the menu bar's "Delete after" choice (0 keeps
    /// the file). Nothing sent to a destination whose bucket doesn't have the
    /// lifecycle rules expires. An upload to an exact key (the bucket
    /// browser, the local API's prefix=) is exactly where the user put it:
    /// it stays, unless that's inside a `tmp/{N}d/` folder the bucket's rules
    /// empty, where it goes after N days like any other file there.
    func upload(_ inputs: [UploadInput], to destination: DestinationConfig? = nil, expiryDays: Int? = nil) {
        guard let destination = destination ?? destinationStore.defaultDestination else { return }
        let rulesActive = ExpiryRuleStore.shared.isActive(destination.id)
        let days = rulesActive ? expiryDays ?? self.expiryDays(for: destination) : 0
        let newJobs = expandingFolders(inputs, for: destination).map { input in
            let jobDays: Int? = if let key = input.objectKey {
                rulesActive ? UploadExpiry.days(forKey: key) : nil
            } else {
                UploadExpiry.options.contains(days) ? days : nil
            }
            return UploadJob(input: input, destination: destination, expiryDays: jobDays)
        }
        jobs.insert(contentsOf: newJobs, at: 0)
        drainQueue()
    }

    /// Stops the job: in-flight parts stop and its multipart upload is
    /// aborted (see `MultipartUploader`), also one kept from a failed try.
    /// The row says Cancelled for a moment, then goes.
    func cancel(_ job: UploadJob) {
        let wasRunning: Bool
        switch job.state {
        case .uploading: wasRunning = true
        case .waiting, .failed: wasRunning = false
        case .succeeded, .cancelled: return
        }
        job.state = .cancelled
        if wasRunning {
            job.task?.cancel()
        } else if let session = job.multipartSession {
            Self.abort(session, destination: job.destination)
        }
        job.multipartSession = nil
        if let group = job.input.group { finishGroupIfDone(group, destination: job.destination) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.dismiss(job)
        }
    }

    private static func abort(_ session: MultipartSession, destination: DestinationConfig) {
        Task.detached {
            if let credentials = try? KeychainService.load(for: destination.id) {
                await S3Provider(config: destination, credentials: credentials)
                    .abortMultipartUpload(objectKey: session.objectKey, uploadId: session.uploadId)
            }
            await MultipartSessionStore.shared.remove(session.id)
        }
    }

    /// Folders become one ZIP input (zipped when its turn comes, so a big
    /// folder doesn't hold up the UI) or one input per file, depending on
    /// the destination. Exact keys (the bucket browser) are left alone.
    private func expandingFolders(_ inputs: [UploadInput], for destination: DestinationConfig) -> [UploadInput] {
        inputs.flatMap { input -> [UploadInput] in
            guard input.objectKey == nil, input.folderKey == nil, FolderUpload.isFolder(input.fileURL) else { return [input] }
            // The folder's own name, or the one it was given before upload.
            let name = input.originalFilename
            switch destination.folderUpload ?? .default {
            case .zip:
                var zipped = input
                zipped.originalFilename = name + ".zip"
                return [zipped]
            case .keepStructure:
                do {
                    let entries = try FolderUpload.files(in: input.fileURL)
                    let prefix = FolderUpload.keyPrefix(template: destination.objectPathTemplate, folderName: name)
                    let groupID = UUID()
                    openGroups[groupID] = [:]
                    return entries.enumerated().map { index, entry in
                        var file = UploadInput(fileURL: entry.fileURL, originalFilename: entry.fileURL.lastPathComponent, source: input.source)
                        file.folderKey = prefix + entry.relativePath
                        file.group = UploadGroup(id: groupID, name: name, index: index, count: entries.count)
                        return file
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    NotificationService.notifyUploadFailed(filename: name, reason: message)
                    return []
                }
            }
        }
    }

    /// Drops a finished job from the list, e.g. one started through the
    /// local API whose staged file is already gone, so it can't be retried.
    func dismiss(_ job: UploadJob) {
        jobs.removeAll { $0 === job }
    }

    func retry(_ job: UploadJob) {
        job.state = .waiting
        drainQueue()
    }

    /// Deletes the remote object and, on success, the local history entry.
    /// If the destination or its credentials are gone, there's nothing left
    /// to delete remotely, so the local entry is cleaned up silently. A real
    /// failure from the provider is rethrown so the caller can keep the
    /// record and offer a retry.
    func deleteRemote(_ record: UploadRecord) async throws {
        guard let destination = destinationStore.destinations.first(where: { $0.id == record.destinationID }),
              let credentials = try? KeychainService.load(for: destination.id) else {
            repository.delete(record)
            return
        }
        let provider = S3Provider(config: destination, credentials: credentials)
        try await provider.delete(objectKey: record.objectKey)
        repository.delete(record)
    }

    /// Clears expiring uploads whose time is up out of history. The bucket's
    /// lifecycle rule has normally deleted the file already; see
    /// `sweep(_:)` for when Aktar deletes it itself. A failure (offline)
    /// leaves the record for the next pass, and a destination that fails
    /// three times is skipped until then.
    func deleteExpired() async {
        var failures: [UUID: Int] = [:]
        for record in repository.expiredRecords() {
            let destinationID = record.destinationID
            if failures[destinationID, default: 0] >= 3 { continue }
            do {
                try await sweep(record)
            } catch {
                failures[destinationID, default: 0] += 1
            }
        }
    }

    /// What the sweep does with one expired upload. Aktar deletes the file
    /// itself only as a stand-in for the bucket's own rule, so only where
    /// that rule is known to be in place, and only the upload it recorded:
    /// - The destination or its keys are gone: nothing to delete from; the
    ///   record goes.
    /// - Its rules aren't active (turned off, or the destination now points
    ///   at another bucket): whatever the bucket does with the file is up to
    ///   its rules; the record goes, the file isn't touched.
    /// - The object at that key was written after this upload (the same
    ///   name uploaded again): it's someone else's upload now, so it stays.
    /// - Otherwise the file is deleted like "Delete Remote File", which
    ///   succeeds for one the rule already deleted.
    private func sweep(_ record: UploadRecord) async throws {
        guard let destination = destinationStore.destinations.first(where: { $0.id == record.destinationID }),
              let credentials = try? KeychainService.load(for: destination.id),
              ExpiryRuleStore.shared.isActive(destination.id) else {
            repository.delete(record)
            return
        }
        let provider = S3Provider(config: destination, credentials: credentials)
        guard let written = try await provider.lastModified(key: record.objectKey),
              !Self.uploadedAgain(record, writtenAt: written) else {
            repository.delete(record)
            return
        }
        try await provider.delete(objectKey: record.objectKey)
        repository.delete(record)
    }

    /// Whether the object's last write is newer than this upload: S3 keeps
    /// whole seconds, so anything more than a minute after the record was
    /// created is a later upload to the same key.
    private static func uploadedAgain(_ record: UploadRecord, writtenAt: Date) -> Bool {
        writtenAt > record.createdAt.addingTimeInterval(60)
    }

    /// Installs the bucket's lifecycle rules for a saved destination, which
    /// is what makes "Delete after" available for it.
    func setUpExpiryRules(for destination: DestinationConfig) async throws {
        let provider = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        do {
            try await provider.ensureExpiryRules()
            ExpiryRuleStore.shared.set(destination.id, active: true)
        } catch {
            ExpiryRuleStore.shared.set(destination.id, active: false)
            throw error
        }
    }

    /// The `tmp/{N}d/` folders of a saved destination that already hold
    /// files and would start expiring once the missing rules are set up.
    func expiryPrefixesInUse(for destination: DestinationConfig) async throws -> [String] {
        let provider = S3Provider(config: destination, credentials: try KeychainService.load(for: destination.id))
        return try await provider.expiryPrefixesInUse()
    }

    private func drainQueue() {
        let pending = jobs.filter {
            if case .waiting = $0.state { return true }
            return false
        }
        for job in pending {
            guard activeCount < maxConcurrent else { break }
            start(job: job, destination: job.destination)
        }
    }

    private func start(job: UploadJob, destination: DestinationConfig) {
        activeCount += 1
        job.state = .uploading(progress: 0)
        job.resuming = false
        job.reused = false
        let reuseDuplicates = reuseDuplicateLinks

        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try KeychainService.load(for: destination.id)
                let provider = S3Provider(config: destination, credentials: credentials)
                // A folder (or a package, such as a Keynote document) goes
                // up as a ZIP made on the spot, its photos cleaned the same
                // way as below.
                let policy = destination.imageMetadata ?? .default
                var fileURL = job.input.fileURL
                var filename = job.input.originalFilename
                var zipped: URL?
                if FolderUpload.isFolder(fileURL) {
                    let folder = fileURL
                    zipped = try await offMain { try FolderUpload.zip(folder, imageMetadata: policy) }
                    fileURL = zipped ?? fileURL
                }
                defer { if let zipped { FolderUpload.removeZip(zipped) } }

                // Photos are converted, recompressed or resized as the
                // destination says (not inside a ZIP), on a copy that has
                // the metadata policy applied already.
                let original = fileURL
                let originalName = filename
                let processing = zipped == nil ? destination.imageProcessing : nil
                let processed = try await offMain {
                    try ImageProcessor.process(original, filename: originalName, settings: processing, policy: policy)
                }
                defer { if let processed { ImageProcessor.removeCopy(processed.url) } }
                if let processed {
                    fileURL = processed.url
                    filename = processed.filename
                }
                let contentType = ContentTypeResolver.resolve(for: fileURL)

                // Otherwise photos lose their location (or all metadata)
                // first, on a copy; everything else is uploaded as it is.
                let unprocessed = fileURL
                let stripped = processed != nil ? nil : try await offMain {
                    try ImageMetadataStripper.strippedCopy(of: unprocessed, policy: policy)
                }
                defer { if let stripped { ImageMetadataStripper.removeCopy(stripped) } }
                let uploadURL = stripped ?? fileURL
                let fileSize = try S3Provider.fileSize(of: uploadURL)

                // Hashes of the bytes that go up, only when something needs
                // them: the path variables, reusing a link, or recognizing a
                // temporary copy when a multipart upload is resumed.
                let template = destination.objectPathTemplate
                let generatesKey = job.input.objectKey == nil && job.input.folderKey == nil
                let canReuse = reuseDuplicates && job.input.objectKey == nil && job.input.group == nil && zipped == nil
                let isCopy = uploadURL != job.input.fileURL
                let wantsMD5 = generatesKey && ObjectKeyGenerator.usesMD5(template)
                let wantsSHA256 = canReuse || (generatesKey && ObjectKeyGenerator.usesSHA256(template))
                    || (isCopy && fileSize > S3Provider.multipartThreshold)
                let hashes = try await offMain {
                    try ContentHasher.hashes(of: uploadURL, md5: wantsMD5, sha256: wantsSHA256)
                }

                // A new format means a new extension, also for an exact key
                // (the bucket browser) and a file in a folder.
                let extensionChanged = processed != nil
                    && (originalName as NSString).pathExtension != (filename as NSString).pathExtension
                func withNewExtension(_ key: String) -> String {
                    guard extensionChanged else { return key }
                    return Self.replacingExtension(of: key, with: (filename as NSString).pathExtension)
                }
                var objectKey: String
                if let exact = job.input.objectKey {
                    objectKey = withNewExtension(exact)
                    // The bucket browser checked the name the user chose,
                    // not the converted one: number it rather than replace
                    // a file that already has that name.
                    if objectKey != exact {
                        objectKey = try await Self.freeKey(objectKey, provider: provider)
                    }
                } else {
                    objectKey = UploadExpiry.key(
                        job.input.folderKey.map(withNewExtension) ?? ObjectKeyGenerator.generate(
                            template: template,
                            originalFilename: filename,
                            hashes: hashes
                        ),
                        days: job.expiryDays
                    )
                }

                // The same bytes are already in this destination: copy that
                // link instead of uploading them again. If the bucket can't
                // be asked, it's uploaded.
                if canReuse, let sha256 = hashes.sha256,
                   let record = repository.reusableRecord(destinationID: destination.id, contentHash: sha256, expiryDays: job.expiryDays),
                   let publicURL = record.publicURL,
                   (try? await provider.objectExists(key: record.objectKey)) == true {
                    var link = publicURL
                    if let duration = destination.temporaryLink,
                       let signed = try? await provider.temporaryURL(for: record.objectKey, expiresIn: duration.rawValue) {
                        link = signed
                    }
                    self.finishReused(job: job, record: record, destination: destination, link: link)
                    return
                }

                let reporter = ProgressReporter(total: fileSize) { progress in
                    guard case .uploading = job.state else { return }
                    job.state = .uploading(progress: progress)
                }
                if fileSize > S3Provider.multipartThreshold {
                    let identity = MultipartFileIdentity(fileURL: uploadURL, size: fileSize, contentHash: hashes.sha256)
                    let session = await self.resumableSession(for: job, destination: destination, identity: identity, objectKey: objectKey)
                    if let session {
                        objectKey = session.objectKey
                        job.resuming = true
                    }
                    try await MultipartUploader.upload(
                        provider: provider,
                        fileURL: uploadURL,
                        fileSize: fileSize,
                        objectKey: objectKey,
                        contentType: contentType,
                        session: session,
                        identity: identity,
                        reporter: reporter
                    ) { session in
                        job.multipartSession = session
                    }
                    job.multipartSession = nil
                } else {
                    try await provider.putObject(fileURL: uploadURL, objectKey: objectKey, contentType: contentType) { sent in
                        reporter.update(part: 0, sent: sent)
                    }
                }
                let result = UploadResult(
                    objectKey: objectKey,
                    publicURL: PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: objectKey),
                    byteSize: Int(fileSize)
                )

                // Signing happens locally, so this only fails on a broken
                // endpoint, where the public URL is the better fallback.
                var link = result.publicURL
                if let duration = destination.temporaryLink,
                   let signed = try? await provider.temporaryURL(for: result.objectKey, expiresIn: duration.rawValue) {
                    link = signed
                }

                self.finish(job: job, result: result, destination: destination, link: link, uploadedFileURL: fileURL, filename: filename, contentHash: hashes.sha256)
            } catch {
                if case .cancelled = job.state {
                    self.stopped(job: job)
                } else if error is CancellationError {
                    job.state = .cancelled
                    self.stopped(job: job)
                } else {
                    self.fail(job: job, error: error, destination: destination)
                }
            }
        }
    }

    /// The multipart upload to continue for this file, if one was started
    /// before (in this run or an earlier one). Only one that ends up where
    /// this upload would: the same key for an exact key, the same "Delete
    /// after" folder otherwise. One that's too old is aborted.
    private func resumableSession(for job: UploadJob, destination: DestinationConfig, identity: MultipartFileIdentity, objectKey: String) async -> MultipartSession? {
        let store = MultipartSessionStore.shared
        var found = job.multipartSession
        if found == nil {
            found = await store.session(destinationID: destination.id, bucket: destination.bucket, identity: identity)
        }
        guard let session = found else { return nil }
        if session.isStale || session.bucket != destination.bucket {
            Self.abort(session, destination: destination)
            job.multipartSession = nil
            return nil
        }
        if job.input.objectKey != nil || job.input.folderKey != nil {
            return session.objectKey == objectKey ? session : nil
        }
        return UploadExpiry.days(forKey: session.objectKey) == UploadExpiry.days(forKey: objectKey) ? session : nil
    }

    /// `key`, or "name 2.ext", "name 3.ext"... when it's taken, numbered the
    /// way the bucket browser numbers its uploads.
    private static func freeKey(_ key: String, provider: S3Provider) async throws -> String {
        let directory = (key as NSString).deletingLastPathComponent
        let name = (key as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = key
        var counter = 2
        while try await provider.objectExists(key: candidate), counter < 1000 {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.isEmpty ? numbered : directory + "/" + numbered
            counter += 1
        }
        return candidate
    }

    /// "a/photo.png" with "webp" gives "a/photo.webp".
    nonisolated static func replacingExtension(of key: String, with newExtension: String) -> String {
        let directory = (key as NSString).deletingLastPathComponent
        let name = (key as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let newName = newExtension.isEmpty ? base : base + "." + newExtension
        return directory.isEmpty ? newName : directory + "/" + newName
    }

    /// A job that ended without finishing: cancelled.
    private func stopped(job: UploadJob) {
        activeCount -= 1
        drainQueue()
    }

    /// Nothing was uploaded: the link of `record` is copied, and history
    /// keeps that one entry.
    private func finishReused(job: UploadJob, record: UploadRecord, destination: DestinationConfig, link: URL) {
        job.reused = true
        job.state = .succeeded(publicURLString: record.publicURLString)
        ClipboardService.copy(format(link, filename: record.localFilename, for: destination))
        NotificationService.notifyUploadReused(filename: record.localFilename)
        closePanelIfWanted()
        activeCount -= 1
        drainQueue()
    }

    /// `link` is what's copied: the public URL, or a temporary link when
    /// the destination is set to one. History keeps the public URL.
    /// `filename` is the name the upload goes by, with the extension of a
    /// converted photo.
    private func finish(job: UploadJob, result: UploadResult, destination: DestinationConfig, link: URL, uploadedFileURL: URL, filename: String, contentHash: String?) {
        job.state = .succeeded(publicURLString: result.publicURL.absoluteString)
        var input = job.input
        input.originalFilename = filename
        repository.record(result: result, input: input, destination: destination, expiryDays: job.expiryDays, uploadedFileURL: uploadedFileURL, contentHash: contentHash)
        NotificationCenter.default.post(
            name: .aktarUploadSucceeded,
            object: destination.id,
            userInfo: ["objectKey": result.objectKey, "byteSize": Int64(result.byteSize)]
        )

        // A file from a folder waits for the rest of it: the links are
        // copied together, with one notification, once the last is done.
        if let group = job.input.group, openGroups[group.id] != nil {
            openGroups[group.id]?[group.index] = (link, filename)
            finishGroupIfDone(group, destination: destination)
        } else {
            ClipboardService.copy(format(link, filename: filename, for: destination))
            NotificationService.notifyUploadSucceeded(filename: filename, expiryDays: job.expiryDays)
            closePanelIfWanted()
        }

        activeCount -= 1
        drainQueue()
    }

    private func format(_ link: URL, filename: String, for destination: DestinationConfig) -> String {
        OutputFormatter.format(publicURL: link, mode: outputMode(for: destination), filename: filename, customTemplate: customTemplate)
    }

    private func closePanelIfWanted() {
        let closeAfterUpload = UserDefaults.standard.object(forKey: "closePopoverAfterUpload") as? Bool ?? true
        if closeAfterUpload {
            NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        }
    }

    /// Once none of a folder's files is waiting or uploading, copies the
    /// links of the ones that made it, one per line and in folder order.
    /// Failed files have their own notifications and can still be retried;
    /// a retry then copies just its own link.
    private func finishGroupIfDone(_ group: UploadGroup, destination: DestinationConfig) {
        guard let links = openGroups[group.id] else { return }
        let stillGoing = jobs.contains { job in
            guard job.input.group?.id == group.id else { return false }
            switch job.state {
            case .waiting, .uploading: return true
            case .succeeded, .failed, .cancelled: return false
            }
        }
        guard !stillGoing else { return }
        openGroups[group.id] = nil
        guard !links.isEmpty else { return }
        let output = links.keys.sorted().compactMap { links[$0] }
            .map { format($0.link, filename: $0.filename, for: destination) }
            .joined(separator: "\n")
        ClipboardService.copy(output)
        let summary = links.count == group.count
            ? String(localized: "\(group.name) (\(group.count) files)")
            : String(localized: "\(group.name) (\(links.count) of \(group.count) files)")
        NotificationService.notifyUploadSucceeded(filename: summary)
        closePanelIfWanted()
    }

    private func fail(job: UploadJob, error: Error, destination: DestinationConfig) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        job.state = .failed(message)
        NotificationService.notifyUploadFailed(filename: job.input.originalFilename, reason: message)
        if let group = job.input.group { finishGroupIfDone(group, destination: destination) }

        activeCount -= 1
        drainQueue()
    }
}

/// Runs `body` off the main actor, cancelled along with the calling task.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated, operation: body)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
