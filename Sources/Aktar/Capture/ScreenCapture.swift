import AppKit
import CoreGraphics

/// Capture: the system's own screenshot tool (`screencapture -i`) picks
/// an area or a window, and the image goes up like a pasted one
/// (docs/capture-and-instant-links.md, "Capture"). macOS asks for Screen
/// Recording permission for Aktar, which the tool runs on behalf of.
///
/// The tool runs in Aktar's sandbox, which allows it as it is: the
/// system's App Sandbox profile lets apps run `/usr/sbin` tools and lets
/// this one register its `com.apple.screencapture.interactive` service.
@MainActor
enum ScreenCapture {
    private static var isRunning = false

    /// Whether Aktar may record the screen.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Lets the user pick an area (Space switches to picking a window, Esc
    /// cancels) and returns the screenshot as an upload, or nil when it was
    /// cancelled, couldn't start, or Aktar may not record the screen yet.
    static func capture() async -> UploadInput? {
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

    /// "Screenshot 2026-11-02 at 14.03.12.png", the way macOS names them
    /// (in English, as file names in Aktar are).
    static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
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
