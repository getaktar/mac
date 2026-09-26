import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    let destinationStore = DestinationStore()
    let repository = UploadRepository()
    let uploadManager: UploadManager

    init() {
        uploadManager = UploadManager(destinationStore: destinationStore, repository: repository)
        NotificationService.requestAuthorizationIfNeeded()
    }
}
