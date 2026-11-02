import AppKit
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
    /// A link from aktar://import for Settings > Destinations to open the
    /// import with; it clears it.
    var pendingImportLink: String?

    init() {
        // Before anything could be uploading from them.
        TempFiles.purgeAtLaunch()
        uploadManager = UploadManager(destinationStore: destinationStore, repository: repository)
        watchService = WatchService(uploadManager: uploadManager, destinationStore: destinationStore)
        NotificationService.requestAuthorizationIfNeeded()
        KeyboardShortcuts.onKeyDown(for: .uploadFromClipboard) { [weak self] in
            Task { @MainActor in self?.uploadFromClipboard() }
        }
        KeyboardShortcuts.onKeyDown(for: .renameAndUploadFromClipboard) { [weak self] in
            Task { @MainActor in self?.uploadFromClipboard(rename: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .uploadClipboardAndPaste) { [weak self] in
            Task { @MainActor in self?.uploadFromClipboard(paste: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .captureAndUpload) { [weak self] in
            Task { @MainActor in self?.capture(paste: false) }
        }
        KeyboardShortcuts.onKeyDown(for: .captureUploadAndPaste) { [weak self] in
            Task { @MainActor in self?.capture(paste: true) }
        }
        KeyboardShortcuts.onKeyDown(for: .undoLastUpload) { [weak self] in
            Task { @MainActor in
                if self?.uploadManager.undoLatest() != true { NSSound.beep() }
            }
        }
        startExpirySweep()
        RemoteThumbnailLoader.shared.repository = repository
        destinationStore.onUpdate = { [weak self] old, new in
            self?.destinationUpdated(from: old, to: new)
        }
        destinationStore.onListChange = { [weak self] in self?.registerDestinationShortcuts() }
        registerDestinationShortcuts()
        Self.current = self
        let destinations = destinationStore.destinations
        Task.detached(priority: .utility) {
            await MultipartUploader.cleanUp(destinations: destinations)
        }
    }

    /// Thumbnails turned off: the ones made for this destination go, here
    /// and in the bucket view's cache. Pointed at another bucket: what was
    /// made from the old one's files no longer applies. (Thumbnails saved
    /// in the bucket are left there; Settings asks about those.)
    private func destinationUpdated(from old: DestinationConfig, to new: DestinationConfig) {
        if new.thumbnailMode == .off, old.thumbnailMode != .off {
            repository.removeThumbnails(destinationID: new.id)
        }
        if new.thumbnailMode == .off || !DestinationTransfer.uploadsToSamePlace(new, as: old) || old.thumbnailMode != new.thumbnailMode
            || old.bucketThumbnailPrefix != new.bucketThumbnailPrefix {
            RemoteThumbnailLoader.shared.forget(destinationID: new.id)
        }
    }

    /// The one running app's state, for Shortcuts actions, which macOS runs
    /// in the app without going through its windows.
    nonisolated(unsafe) static weak var current: AppState?

    /// Destinations whose shortcut has its handler. A handler is added once
    /// per destination; a removed destination's shortcut is cleared, so it
    /// never fires again.
    @ObservationIgnored private var shortcutDestinations: Set<UUID> = []

    private func registerDestinationShortcuts() {
        for destination in destinationStore.destinations where !shortcutDestinations.contains(destination.id) {
            shortcutDestinations.insert(destination.id)
            let id = destination.id
            KeyboardShortcuts.onKeyDown(for: .uploadToDestination(id)) { [weak self] in
                Task { @MainActor in self?.uploadFromClipboard(toDestinationID: id) }
            }
        }
    }

    /// A destination's shortcut: the clipboard goes there, never rerouted.
    func uploadFromClipboard(toDestinationID id: UUID) {
        guard let destination = destinationStore.destinations.first(where: { $0.id == id }),
              let input = ClipboardService.readInput() else { return }
        uploadManager.upload([input], to: destination)
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

    /// aktar://import: Settings opens the import with `link` filled in.
    /// Only the transfer code and pressing Import there add anything.
    func importDestination(link: String) {
        pendingImportLink = link
        openSettings(tab: SettingsTab.destinations.rawValue)
    }

    /// `rename` asks for the file's name first; see `RenamePrompt`.
    /// `paste` pastes the link into the app in front once it's copied
    /// (Upload and Paste); without the Accessibility permission it's only
    /// copied.
    func uploadFromClipboard(rename: Bool = false, paste: Bool = false) {
        // Before anything else can come to the front.
        let target = paste ? PasteRequest.frontmost() : nil
        guard let input = ClipboardService.readInput() else {
            if paste { NSSound.beep() }
            return
        }
        let inputs = rename ? RenamePrompt.rename([input]) : [input]
        guard !inputs.isEmpty else {
            TempFiles.removeIfOwned(input.fileURL)
            return
        }
        let canPaste = paste && PasteService.ensurePermission()
        uploadManager.upload(inputs, paste: canPaste ? target : nil)
    }

    /// Capture: picks an area or window with macOS's screenshot tool and
    /// uploads it like a pasted image ("Use for" decides where). With
    /// `paste`, the link is then pasted into the app that was in front.
    func capture(paste: Bool) {
        let target = paste ? PasteRequest.frontmost(for: 300) : nil
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        Task {
            guard let input = await ScreenCapture.capture() else { return }
            // Counted from the end of the capture, which takes its time.
            let request = target.map { PasteRequest(processID: $0.processID, deadline: Date.now.addingTimeInterval(30)) }
            let canPaste = paste && PasteService.ensurePermission()
            uploadManager.upload([input], paste: canPaste ? request : nil)
        }
    }
}
