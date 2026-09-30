import AppKit

/// The "Upload with Aktar" service, which Finder shows when you right-click
/// files (Quick Actions or Services) and which can have a keyboard shortcut
/// in System Settings > Keyboard > Keyboard Shortcuts > Services.
///
/// Files arrive on the service pasteboard, which also gives the sandboxed
/// app read access to them, so this is how Aktar uploads the Finder
/// selection without asking to read the whole disk. Folders are skipped:
/// uploads are single objects.
@MainActor
final class FinderService: NSObject {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Named by `NSMessage` in the NSServices entry of Info.plist.
    @objc func uploadFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        guard !files.isEmpty else {
            error.pointee = String(localized: "Aktar can only upload files, not folders.") as NSString
            return
        }
        guard appState.destinationStore.defaultDestination != nil else {
            error.pointee = String(localized: "Add a destination in Aktar's Settings first.") as NSString
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "settings")
            return
        }
        let inputs = files.map { UploadInput(fileURL: $0, originalFilename: $0.lastPathComponent, source: .finderExtension) }
        appState.uploadManager.upload(inputs)
    }
}
