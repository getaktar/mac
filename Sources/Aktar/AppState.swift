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
        KeyboardShortcuts.onKeyDown(for: .renameAndUploadFromClipboard) { [weak self] in
            Task { @MainActor in self?.uploadFromClipboard(rename: true) }
        }
        startExpirySweep()
        let destinations = destinationStore.destinations
        Task.detached(priority: .utility) {
            await MultipartUploader.cleanUp(destinations: destinations)
        }
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

    /// `rename` asks for the file's name first; see `RenamePrompt`.
    func uploadFromClipboard(rename: Bool = false) {
        guard let input = ClipboardService.readFileInput() else { return }
        let inputs = rename ? RenamePrompt.rename([input]) : [input]
        guard !inputs.isEmpty else { return }
        uploadManager.upload(inputs)
    }
}
