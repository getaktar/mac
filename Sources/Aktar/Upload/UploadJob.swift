import Foundation
import Observation

enum UploadJobState: Equatable {
    case waiting
    case uploading(progress: Double)
    case succeeded(publicURLString: String)
    case failed(String)
    /// Failed for want of a connection; tried again when the network comes
    /// back, and every so often until then (see `UploadManager.retryOffline`).
    case offline(String)
    case cancelled
}

@Observable
final class UploadJob: Identifiable {
    let id: UUID
    let input: UploadInput
    let destination: DestinationConfig
    /// Days until the upload is deleted, or nil to keep it.
    let expiryDays: Int?
    var state: UploadJobState = .waiting
    var task: Task<Void, Never>?
    /// Continuing a multipart upload started earlier, rather than from
    /// the start.
    var resuming = false
    /// Finished by reusing the link of the same file uploaded before.
    var reused = false
    /// The multipart upload this job is sending, kept after a failure so
    /// Retry continues it and Cancel can abort it.
    var multipartSession: MultipartSession?
    /// SHA-256 of the file as it is on disk, when the upload hashed the
    /// original bytes (for a watched folder's ledger).
    var originalContentHash: String?
    /// The history entry the job made or updated (or reused), once it
    /// has succeeded.
    var recordID: UUID?
    /// Why its short link couldn't be made (the original link was copied
    /// instead), for whoever waits for the upload.
    var shortLinkError: String?

    /// The upload (one drop, paste, capture...) this job is part of, for
    /// Undo and Upload and Paste; nil for a watched folder's files.
    var actionID: UUID?
    /// The link copied before the upload finished; see `EarlyLink`.
    var earlyLink: EarlyLink?
    /// Kept in `UploadOutbox`, so it goes on after a restart.
    var isInOutbox = false
    /// A copied link's file, once downloaded (`input.remote`).
    var downloaded: RemoteDownloader.Result?
    /// Downloading `input.remote` right now.
    var isDownloading = false
    /// When the first try started.
    var firstAttemptAt: Date?
    /// Tries made while offline, for the wait before the next.
    var offlineRetries = 0
    var nextRetryAt: Date?
    /// Someone (the local API, a Shortcuts action) waits for the outcome:
    /// a failure is reported to them instead of waiting for the network.
    var isWaitedFor = false

    /// Waiting or uploading: its file is still needed.
    var isActive: Bool {
        switch state {
        case .waiting, .uploading: return true
        case .succeeded, .failed, .offline, .cancelled: return false
        }
    }

    /// Not finished yet: going, waiting to go, or waiting for the network.
    var isPending: Bool {
        switch state {
        case .waiting, .uploading, .offline: return true
        case .succeeded, .failed, .cancelled: return false
        }
    }

    /// The name the upload goes by: a downloaded file's own, unless the
    /// upload was renamed (then with the download's extension when the new
    /// name has none).
    var displayName: String {
        guard let downloaded, let remote = input.remote else { return input.originalFilename }
        if remote.suggestedName == input.originalFilename { return downloaded.filename }
        let ext = (downloaded.filename as NSString).pathExtension
        guard (input.originalFilename as NSString).pathExtension.isEmpty, !ext.isEmpty else { return input.originalFilename }
        return input.originalFilename + "." + ext
    }

    init(id: UUID = UUID(), input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil) {
        self.id = id
        self.input = input
        self.destination = destination
        self.expiryDays = expiryDays
    }
}
