import AppKit

/// The "Upload with Aktar" service, which Finder shows when you right-click
/// files (Quick Actions or Services) and which can have a keyboard shortcut
/// in System Settings > Keyboard > Keyboard Shortcuts > Services.
///
/// Files arrive on the service pasteboard, which also gives the sandboxed
/// app read access to them, so this is how Aktar uploads the Finder
/// selection without asking to read the whole disk. Folders go up as the
/// destination's Folders setting says (a ZIP, or file by file).
///
/// "Watch Folder with Aktar" (folders only) opens Settings > Watched
/// Folders to add it. The access a service gets ends with the app, so the
/// folder is confirmed in a folder picker there, which grants lasting
/// access.
@MainActor
final class FinderService: NSObject {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Named by `NSMessage` in the NSServices entry of Info.plist.
    @objc func uploadFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !files.isEmpty else { return }
        guard appState.destinationStore.defaultDestination != nil else {
            error.pointee = String(localized: "Add a destination in Aktar's Settings first.") as NSString
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "settings")
            return
        }
        let inputs = files.map { UploadInput(fileURL: $0, originalFilename: $0.lastPathComponent, source: .finderExtension) }
        appState.uploadManager.upload(inputs)
    }

    /// Named by `NSMessage` in the second NSServices entry.
    @objc func watchFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let folder = urls.first(where: FolderUpload.isFolder) else { return }
        appState.watchFolder(folder)
    }
}
