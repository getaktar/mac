import AppKit
import CoreGraphics

/// The clipboard as it was before a capture tool copied its image: Undo
/// puts this back, never the image (docs/capture-tools.md).
struct CapturedClipboard {
    /// Nil when it couldn't be kept (too big, or marked private).
    let snapshot: ClipboardSnapshot?
}

struct CaptureResult {
    var input: UploadInput
    /// Set when the image came over the clipboard.
    var clipboardBefore: CapturedClipboard?
}

/// Capture: the screenshot tool picked in Settings (macOS's own by
/// default) takes the image, which goes up like a pasted one
/// (docs/capture-and-instant-links.md, "Capture"; docs/capture-tools.md).
///
/// macOS's tool (`screencapture -i`) runs in Aktar's sandbox, which allows
/// it as it is: the system's App Sandbox profile lets apps run `/usr/sbin`
/// tools and lets this one register its `com.apple.screencapture.interactive`
/// service. macOS asks for Screen Recording permission for Aktar, which the
/// tool runs on behalf of. Other tools run as their own apps, with their
/// own permission.
@MainActor
enum ScreenCapture {
    private static var isRunning = false
    /// Editing takes its time.
    static let toolTimeout: TimeInterval = 10 * 60

    /// Whether Aktar may record the screen.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The image from the tool picked in Settings, or nil when the capture
    /// was cancelled, ran out of time, or couldn't start.
    static func capture() async -> CaptureResult? {
        let tool = CaptureTool.current
        if tool == .system {
            return await captureWithSystemTool().map { CaptureResult(input: $0) }
        }
        guard let appURL = tool.appURL else {
            showNotInstalled(tool)
            return nil
        }
        if tool == .flameshot, !FlameshotHelper.isInstalled {
            guard askForFlameshotHelper() else { return nil }
        }
        // A new capture ends the one still waiting.
        CaptureWaiting.shared.stop()
        return await captureWithTool(tool, appURL: appURL)
    }

    /// Lets the user pick an area (Space switches to picking a window, Esc
    /// cancels) and returns the screenshot as an upload, or nil when it was
    /// cancelled, couldn't start, or Aktar may not record the screen yet.
    static func captureWithSystemTool() async -> UploadInput? {
        guard !isRunning else { return nil }
        guard ensurePermission() else { return nil }
        isRunning = true
        defer { isRunning = false }

        let filename = Self.filename(for: .now)
        guard let folder = try? TempFiles.newFolder(in: TempFiles.clipboard) else { return nil }
        let url = folder.appendingPathComponent(filename)
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", url.path]
        process.standardError = errors

        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard status != nil, size > 0 else {
            try? FileManager.default.removeItem(at: folder)
            // Esc ends the tool quietly; a tool that couldn't start says why.
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if status == nil || !message.isEmpty {
                showFailure(message)
            }
            return nil
        }
        return UploadInput(fileURL: url, originalFilename: filename, source: .capture)
    }

    // MARK: - Other tools

    /// Starts the tool, then takes the first image it copies, or (for one
    /// with a save folder) saves there. Flameshot runs as a new instance
    /// of its own (each one hosts its capture on macOS), started by the
    /// helper script, that copies the image and quits; quitting without
    /// one is a cancel.
    private static func captureWithTool(_ tool: CaptureTool, appURL: URL) async -> CaptureResult? {
        let pasteboard = NSPasteboard.general
        let before = CapturedClipboard(snapshot: ClipboardSnapshot.take(from: pasteboard))
        var changeCount = pasteboard.changeCount
        let folder = tool.usesSaveFolder ? tool.openSaveFolder() : nil
        defer { folder?.stopAccessingSecurityScopedResource() }
        var detector = folder.map { NewImageDetector(baseline: CaptureImageFiles.list($0)) }

        var ended: TaskEnded?
        switch tool.kind {
        case .urlScheme(let url):
            let opened = await withCheckedContinuation { continuation in
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
            guard opened else {
                showFailure(String(localized: "\(tool.name) didn\u{2019}t open. Check that it\u{2019}s set up as Settings > General > Capture tool describes, or pick another tool there."))
                return nil
            }
        case .process:
            guard let helper = FlameshotHelper.url else { return nil }
            let task: NSUserUnixTask
            do {
                task = try NSUserUnixTask(url: helper)
            } catch {
                showFailure(error.localizedDescription)
                return nil
            }
            let taskEnded = TaskEnded()
            ended = taskEnded
            task.execute(withArguments: [appURL.path]) { _ in taskEnded.set() }
        case .systemTool:
            return nil
        }

        let generation = CaptureWaiting.shared.begin(tool)
        defer { CaptureWaiting.shared.end(generation) }
        let deadline = Date.now.addingTimeInterval(toolTimeout)
        var quitAt: Date?
        while Date.now < deadline, CaptureWaiting.shared.isCurrent(generation) {
            try? await Task.sleep(for: .milliseconds(250))
            guard CaptureWaiting.shared.isCurrent(generation) else { break }

            if pasteboard.changeCount != changeCount {
                changeCount = pasteboard.changeCount
                if let found = PasteboardImage.read(from: pasteboard), let input = input(for: found) {
                    return CaptureResult(input: input, clipboardBefore: before)
                }
            }
            if let folder, var current = detector {
                let ready = current.observe(CaptureImageFiles.list(folder), at: .now)
                detector = current
                if let ready {
                    let url = folder.appendingPathComponent(ready)
                    CaptureClaims.claim(url)
                    return copiedInput(from: url).map { CaptureResult(input: $0) }
                }
            }
            // The tool may still be handing its copy over as it quits.
            if let ended, ended.isSet {
                if let quitAt {
                    if Date.now.timeIntervalSince(quitAt) > 1 { break }
                } else {
                    quitAt = .now
                }
            }
        }
        return nil
    }

    /// An upload of what the tool copied, in a temporary file of Aktar's
    /// own (deleted after the upload), named like macOS's screenshots.
    private static func input(for found: PasteboardImage.Found) -> UploadInput? {
        switch found {
        case .file(let url):
            return copiedInput(from: url)
        case .data(let data, let fileExtension):
            let filename = Self.filename(for: .now, fileExtension: fileExtension)
            guard let folder = try? TempFiles.newFolder(in: TempFiles.clipboard) else { return nil }
            let url = folder.appendingPathComponent(filename)
            do {
                try data.write(to: url)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            return UploadInput(fileURL: url, originalFilename: filename, source: .capture)
        }
    }

    /// A copy of the tool's file, which stays where the tool put it.
    private static func copiedInput(from source: URL) -> UploadInput? {
        let fileExtension = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let filename = Self.filename(for: .now, fileExtension: fileExtension)
        guard let folder = try? TempFiles.newFolder(in: TempFiles.clipboard) else { return nil }
        let url = folder.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return UploadInput(fileURL: url, originalFilename: filename, source: .capture)
    }

    /// Flameshot is picked but its helper isn't there (or is outdated):
    /// installs it, then the capture goes on.
    private static func askForFlameshotHelper() -> Bool {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Flameshot needs Aktar\u{2019}s helper")
        alert.informativeText = String(localized: "macOS only lets Aktar start a Flameshot capture through a small script in Aktar\u{2019}s Application Scripts folder. Install it once; the next window opens on that folder.")
        alert.addButton(withTitle: String(localized: "Install Helper\u{2026}"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return FlameshotHelper.install()
    }

    private static func showNotInstalled(_ tool: CaptureTool) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "\(tool.name) isn\u{2019}t installed")
        alert.informativeText = String(localized: "Capture is set to use \(tool.name). Install it, or pick another tool in Settings > General > Capture tool.")
        alert.addButton(withTitle: String(localized: "Get \(tool.name)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn, let website = tool.website {
            NSWorkspace.shared.open(website)
        }
    }

    /// "Screenshot 2026-11-02 at 14.03.12.png", the way macOS names them
    /// (in English, as file names in Aktar are).
    static func filename(for date: Date, fileExtension: String = "png") -> String {
        CaptureImageFiles.filename(for: date, fileExtension: fileExtension)
    }

    /// Without the permission, Aktar explains first: macOS doesn't always
    /// show its own request, and nothing at all would happen then.
    private static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        showPermissionAlert()
        return false
    }

    static func showPermissionAlert() {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Aktar to record the screen")
        alert.informativeText = String(localized: "Capture uses macOS\u{2019}s screenshot tool, which needs Screen Recording permission for Aktar. Turn on Aktar in System Settings > Privacy & Security > Screen & System Audio Recording, then try again.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            // Lists Aktar on that page (the first time, macOS may also ask
            // itself); the page opens when it doesn't.
            if !CGRequestScreenCaptureAccess() { SystemSettingsLink.open(.screenRecording) }
        }
    }

    private static func showFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Capture couldn\u{2019}t start")
        alert.informativeText = message.isEmpty
            ? String(localized: "macOS\u{2019}s screenshot tool didn\u{2019}t run. Try again, or take the screenshot with the system shortcut and paste it into Aktar.")
            : message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

/// Pages of System Settings > Privacy & Security.
enum SystemSettingsLink {
    case screenRecording
    case accessibility

    static func open(_ page: SystemSettingsLink) {
        let anchor = switch page {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
