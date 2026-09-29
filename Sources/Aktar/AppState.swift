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
        startExpirySweep()
    }

    /// Checks for expired uploads at launch and then hourly.
    private func startExpirySweep() {
        Task { [weak self] in
            while let manager = self?.uploadManager {
                await manager.deleteExpired()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func uploadFromClipboard() {
        guard let input = ClipboardService.readFileInput() else { return }
        uploadManager.upload([input])
    }
}
