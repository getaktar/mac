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
    /// the file). Uploads to an exact key, such as from the bucket browser,
    /// never expire, and neither does anything sent to a destination whose
    /// bucket doesn't have the lifecycle rules.
    func upload(_ inputs: [UploadInput], to destination: DestinationConfig? = nil, expiryDays: Int? = nil) {
        guard let destination = destination ?? destinationStore.defaultDestination else { return }
        let days = ExpiryRuleStore.shared.isActive(destination.id) ? expiryDays ?? self.expiryDays : 0
        let newJobs = inputs.map {
            UploadJob(
                input: $0,
                destination: destination,
                expiryDays: $0.objectKey == nil && UploadExpiry.options.contains(days) ? days : nil
            )
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
    /// lifecycle rule normally deleted the object already (deleting a missing
    /// object still succeeds); this also covers rules removed since. A
    /// failure leaves the record for the next pass.
    func deleteExpired() async {
        for record in repository.expiredRecords() {
            try? await deleteRemote(record)
        }
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
