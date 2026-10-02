import Foundation
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class AppState {
    let destinationStore = DestinationStore()
    let repository = UploadRepository()
    let uploadManager: UploadManager
    let watchService: WatchService
    let updater = AppUpdater()
    /// The Settings tab to show next, by `SettingsTab` raw value; Settings
    /// switches to it and clears it.
    var requestedSettingsTab: String?

    init() {
        uploadManager = UploadManager(destinationStore: destinationStore, repository: repository)
        watchService = WatchService(uploadManager: uploadManager, destinationStore: destinationStore)
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

    /// Opens Settings on the tab with this raw value ("watchedFolders").
    func openSettings(tab: String) {
        requestedSettingsTab = tab
        NotificationCenter.default.post(name: .aktarOpenWindow, object: "settings")
    }

    /// "Watch Folder with Aktar" and the like: Settings opens on Watched
    /// Folders and asks to confirm `url` there (the folder picker grants
    /// lasting access, which the Finder service can't).
    func watchFolder(_ url: URL) {
        watchService.pendingAddURL = url
        openSettings(tab: "watchedFolders")
    }

    /// `rename` asks for the file's name first; see `RenamePrompt`.
    func uploadFromClipboard(rename: Bool = false) {
        guard let input = ClipboardService.readFileInput() else { return }
        let inputs = rename ? RenamePrompt.rename([input]) : [input]
        guard !inputs.isEmpty else { return }
        uploadManager.upload(inputs)
    }
}
