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
    var state: UploadJobState = .waiting
    var task: Task<Void, Never>?

    init(input: UploadInput) {
        self.input = input
    }
}
