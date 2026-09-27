import Foundation
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class AppState {
    let destinationStore = DestinationStore()
    let repository = UploadRepository()
    let uploadManager: UploadManager
    let updater = AppUpdater()

    init() {
        uploadManager = UploadManager(destinationStore: destinationStore, repository: repository)
        NotificationService.requestAuthorizationIfNeeded()
        KeyboardShortcuts.onKeyDown(for: .uploadFromClipboard) { [weak self] in
            Task { @MainActor in self?.uploadFromClipboard() }
        }
    }

    func uploadFromClipboard() {
        guard let input = ClipboardService.readFileInput() else { return }
        uploadManager.upload([input])
    }
}
