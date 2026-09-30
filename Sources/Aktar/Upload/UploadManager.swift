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

    var outputMode: OutputMode = .url
    var customTemplate: String = "![{filename}]({url})"

    /// The "Delete after" choice in the menu bar, in days (0 = keep). It
    /// sticks between uploads and launches, like the default destination.
    var expiryDays: Int = UserDefaults.standard.integer(forKey: UploadExpiry.defaultsKey) {
        didSet { UserDefaults.standard.set(expiryDays, forKey: UploadExpiry.defaultsKey) }
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
        return expiryDays
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
        let days = rulesActive ? expiryDays ?? self.expiryDays : 0
        let newJobs = inputs.map { input in
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

    func cancel(_ job: UploadJob) {
        job.task?.cancel()
        job.state = .cancelled
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

        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try KeychainService.load(for: destination.id)
                let provider = S3Provider(config: destination, credentials: credentials)
                let objectKey = job.input.objectKey ?? UploadExpiry.key(
                    ObjectKeyGenerator.generate(
                        template: destination.objectPathTemplate,
                        originalFilename: job.input.originalFilename
                    ),
                    days: job.expiryDays
                )
                let contentType = ContentTypeResolver.resolve(for: job.input.fileURL)

                let result = try await provider.upload(
                    fileURL: job.input.fileURL,
                    objectKey: objectKey,
                    contentType: contentType
                ) { progress in
                    job.state = .uploading(progress: progress)
                }

                self.finish(job: job, result: result, destination: destination)
            } catch {
                self.fail(job: job, error: error, destination: destination)
            }
        }
    }

    private func finish(job: UploadJob, result: UploadResult, destination: DestinationConfig) {
        job.state = .succeeded(publicURLString: result.publicURL.absoluteString)
        repository.record(result: result, input: job.input, destination: destination, expiryDays: job.expiryDays)

        let output = OutputFormatter.format(
            publicURL: result.publicURL,
            mode: outputMode,
            filename: job.input.originalFilename,
            customTemplate: customTemplate
        )
        ClipboardService.copy(output)
        NotificationService.notifyUploadSucceeded(filename: job.input.originalFilename, expiryDays: job.expiryDays)
        NotificationCenter.default.post(
            name: .aktarUploadSucceeded,
            object: destination.id,
            userInfo: ["objectKey": result.objectKey, "byteSize": Int64(result.byteSize)]
        )

        let closeAfterUpload = UserDefaults.standard.object(forKey: "closePopoverAfterUpload") as? Bool ?? true
        if closeAfterUpload {
            NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        }

        activeCount -= 1
        drainQueue()
    }

    private func fail(job: UploadJob, error: Error, destination: DestinationConfig) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        job.state = .failed(message)
        NotificationService.notifyUploadFailed(filename: job.input.originalFilename, reason: message)

        activeCount -= 1
        drainQueue()
    }
}
