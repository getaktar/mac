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

    init(input: UploadInput, destination: DestinationConfig, expiryDays: Int? = nil) {
        self.input = input
        self.destination = destination
        self.expiryDays = expiryDays
    }
}
