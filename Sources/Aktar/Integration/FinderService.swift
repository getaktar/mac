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
/// Any app can call a service, also from the background, so unless Finder
/// is in front (the user picked it there, from the menu or its shortcut),
/// Aktar asks before uploading, naming the files and where they'd go.
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
        guard Self.isFinderInFront || confirmUpload(inputs) else { return }
        appState.uploadManager.upload(inputs)
    }

    private static var isFinderInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    /// Asked when the service was called with another app in front: from
    /// the Share menu, or by an app that wants a link on your bucket.
    private func confirmUpload(_ inputs: [UploadInput]) -> Bool {
        var names: [String] = []
        for input in inputs {
            guard let name = appState.uploadManager.routedDestination(for: input)?.name else { continue }
            if !names.contains(name) { names.append(name) }
        }
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if inputs.count == 1, let input = inputs.first {
            alert.messageText = String(localized: "Upload \u{201C}\(input.originalFilename)\u{201D} with Aktar?")
        } else {
            alert.messageText = String(localized: "Upload \(inputs.count) items with Aktar?")
        }
        let destinations = ListFormatter.localizedString(byJoining: names)
        alert.informativeText = String(localized: "Another app asked Aktar to upload to \(destinations). Only upload if you chose Upload with Aktar or Aktar in the Share menu yourself.")
        alert.addButton(withTitle: String(localized: "Upload"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Named by `NSMessage` in the second NSServices entry.
    @objc func watchFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let folder = urls.first(where: FolderUpload.isFolder) else { return }
        appState.watchFolder(folder)
    }
}
