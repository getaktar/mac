import Foundation
import Observation

enum UploadJobState: Equatable {
    case waiting
    case uploading(progress: Double)
    case succeeded(publicURLString: String)
    case failed(String)
    case cancelled
}

@Observable
final class UploadJob: Identifiable {
    let id = UUID()
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

    /// Waiting or uploading: its file is still needed.
    var isActive: Bool {
        switch state {
        case .waiting, .uploading: return true
        case .succeeded, .failed, .cancelled: return false
        }
    }

    init(input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil) {
        self.input = input
        self.destination = destination
        self.expiryDays = expiryDays
    }
}
