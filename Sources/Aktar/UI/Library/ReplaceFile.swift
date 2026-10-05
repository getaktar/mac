import AppKit

/// Replace File… in History and the bucket view: pick a file, and it's
/// uploaded to the same key, so the link stays (see `UploadManager.replace`).
@MainActor
enum ReplaceFile {
    static func replace(_ record: UploadRecord, using manager: UploadManager) {
        guard let url = pickFile(replacing: record.localFilename) else { return }
        do {
            try manager.replace(record, with: url)
        } catch {
            showProblem(error)
        }
    }

    static func replaceObject(key: String, in destination: DestinationConfig, using manager: UploadManager) {
        guard let url = pickFile(replacing: (key as NSString).lastPathComponent) else { return }
        manager.replaceObject(key: key, in: destination, with: url)
    }

    private static func pickFile(replacing name: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Replace \u{201C}\(name)\u{201D}")
        panel.message = String(localized: "The new file goes to the same key, so the link keeps working.")
        panel.prompt = String(localized: "Replace")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func showProblem(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn\u{2019}t replace the file")
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.runModal()
    }
}
