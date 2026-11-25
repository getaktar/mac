import AppKit
import Observation

/// The screenshot tool Capture runs, so what goes up can be an annotated
/// image (docs/capture-tools.md). macOS's own tool is the default.
enum CaptureTool: String, CaseIterable, Identifiable, Sendable {
    case system
    case cleanShot
    case shottr
    case macshot
    case flameshot

    var id: String { rawValue }

    static let settingKey = "captureTool"

    /// The tool picked in Settings > General > Capture.
    static var current: CaptureTool {
        get { UserDefaults.standard.string(forKey: settingKey).flatMap(CaptureTool.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: settingKey) }
    }

    /// Tool names are never translated.
    var name: String {
        switch self {
        case .system: String(localized: "macOS Screenshot")
        case .cleanShot: "CleanShot X"
        case .shottr: "Shottr"
        case .macshot: "macshot"
        case .flameshot: "Flameshot"
        }
    }

    var website: URL? {
        switch self {
        case .system: nil
        case .cleanShot: URL(string: "https://cleanshot.com")
        case .shottr: URL(string: "https://shottr.cc")
        case .macshot: URL(string: "https://github.com/sw33tlie/macshot")
        case .flameshot: URL(string: "https://flameshot.org")
        }
    }

    /// How the image comes back.
    enum Kind: Equatable {
        /// `screencapture` writes the file Aktar names.
        case systemTool
        /// Aktar runs it and reads the clipboard when it quits.
        case process
        /// Aktar opens its URL and waits for the image on the clipboard or
        /// in the save folder.
        case urlScheme(URL)
    }

    var kind: Kind {
        switch self {
        case .system: .systemTool
        case .flameshot: .process
        // Area capture straight into the tool's editor.
        case .cleanShot: .urlScheme(URL(string: "cleanshot://capture-area?action=annotate")!)
        case .shottr: .urlScheme(URL(string: "shottr://grab/area?then=edit")!)
        case .macshot: .urlScheme(URL(string: "macshot://capture")!)
        }
    }

    /// Whether the image can also come from a folder the tool saves to.
    var usesSaveFolder: Bool {
        if case .urlScheme = kind { return true }
        return false
    }

    /// Where the tool is installed, or nil when it isn't (or for macOS's
    /// own tool, which always is).
    var appURL: URL? {
        switch kind {
        case .systemTool:
            return nil
        case .urlScheme(let url):
            return NSWorkspace.shared.urlForApplication(toOpen: url)
        case .process:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.flameshot.Flameshot") {
                return url
            }
            let candidates = ["/Applications/flameshot.app", "/Applications/Flameshot.app"]
                .map { URL(fileURLWithPath: $0) }
            return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    var isInstalled: Bool { self == .system || appURL != nil }

    /// What the user sets up in the tool, and how to finish a capture there.
    var setupSteps: [String] {
        switch self {
        case .system:
            return []
        case .cleanShot:
            return [
                String(localized: "The first time, CleanShot X asks whether other apps may control it: click Launch & Allow."),
                String(localized: "Select an area. It opens in CleanShot\u{2019}s editor: annotate it, then copy it (\u{2318}C) or save it to the folder below. That image is uploaded."),
            ]
        case .shottr:
            return [
                String(localized: "The first time, Shottr asks to turn on deep links: click OK, then capture again."),
                String(localized: "Select an area. It opens in Shottr\u{2019}s editor: annotate it, then click Copy in its toolbar or save it (\u{2318}S) to the folder below. That image is uploaded."),
            ]
        case .macshot:
            return [
                String(localized: "Select an area and annotate it in macshot, then copy it (\u{2318}C) or save it to the folder below. That image is uploaded."),
                String(localized: "If nothing happens, turn on the URL scheme in macshot\u{2019}s settings. Leave macshot\u{2019}s own upload off."),
            ]
        case .flameshot:
            return [
                String(localized: "Install Aktar\u{2019}s Flameshot helper below, once: macOS only lets Aktar start a Flameshot capture through it."),
                String(localized: "Select an area and annotate it, then accept it with the check mark in Flameshot\u{2019}s toolbar. Esc cancels."),
                String(localized: "Flameshot asks for Screen Recording permission for itself the first time."),
            ]
        }
    }

    /// The tools that work on this Mac, macOS's own first, then the
    /// installed ones, then the rest.
    static var ordered: [CaptureTool] {
        let others = allCases.filter { $0 != .system }
        return [.system] + others.filter(\.isInstalled) + others.filter { !$0.isInstalled }
    }

    // MARK: - Save folder

    private var folderKey: String { "captureToolFolder.\(rawValue)" }

    /// The folder the tool saves to, picked by the user: Aktar's sandbox
    /// can't read the tool's own settings to find it.
    var saveFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: folderKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: folderKey) }
    }

    /// The save folder's path, for showing it.
    var saveFolderPath: String? {
        guard let bookmark = saveFolderBookmark else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return url?.path
    }

    /// The save folder, opened for reading; the caller stops accessing it.
    func openSaveFolder() -> URL? {
        guard let bookmark = saveFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            saveFolderBookmark = fresh
        }
        return url
    }
}

// MARK: - Flameshot helper

/// macOS drops the arguments a sandboxed app passes when it opens another
/// app (NSWorkspace and `open` alike, checked on macOS 15), and Flameshot
/// can't run inside Aktar's sandbox, so Aktar can't start its capture
/// (`gui --clipboard`) by itself. A script in Aktar's Application Scripts
/// folder runs outside the sandbox (NSUserUnixTask). Only the user can
/// put it there, through a save panel Aktar opens on that folder.
enum FlameshotHelper {
    static let filename = "flameshot-capture.sh"

    /// Opens a new Flameshot instance with the capture's arguments and
    /// waits until it quits (`-W`), so Aktar knows when it's done. The
    /// app's path is the only argument.
    static let script = """
        #!/bin/sh
        # Installed by Aktar (Settings > General > Capture tool): starts a
        # Flameshot capture that copies the image, and waits until it quits.
        exec /usr/bin/open -n -W -a "$1" --args gui --clipboard

        """

    static var folder: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    static var url: URL? { folder?.appendingPathComponent(filename) }

    /// Installed as this version of Aktar wrote it; an older or edited one
    /// is installed again.
    static var isInstalled: Bool {
        guard let url, let data = try? Data(contentsOf: url) else { return false }
        return data == Data(script.utf8)
    }

    /// Asks the user to save the helper in Aktar's Application Scripts
    /// folder; true once it's there.
    @MainActor
    static func install() -> Bool {
        guard let folder, let url else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = false
        panel.message = String(localized: "Click Save to install the Flameshot helper in this folder.")
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        guard chosen.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "The helper wasn\u{2019}t installed")
            alert.informativeText = String(localized: "It only works in the folder the window opens in, with the name it suggests. Try again and click Save without changing them.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return false
        }
        do {
            try Data(script.utf8).write(to: chosen)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chosen.path)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
        return isInstalled
    }
}

/// Set once a helper task has ended; its completion runs on another queue.
final class TaskEnded: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    func set() { lock.withLock { ended = true } }
    var isSet: Bool { lock.withLock { ended } }
}

// MARK: - Spotting the image

/// Image files Capture takes from a tool's save folder.
enum CaptureImageFiles {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "avif"]

    /// "Screenshot 2026-11-02 at 14.03.12.png", the way macOS names them
    /// (in English, as file names in Aktar are).
    static func filename(for date: Date, fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(fileExtension)"
    }

    static func isImage(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        return extensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The image files directly in `folder` and their sizes.
    static func list(_ folder: URL) -> [String: Int64] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var files: [String: Int64] = [:]
        for url in urls where isImage(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files[url.lastPathComponent] = Int64(values?.fileSize ?? 0)
        }
        return files
    }
}

/// Spots the first new image in a folder and says when it's written:
/// its size has stayed the same, and above zero, for `settle` seconds.
/// Files there when the wait began are never taken, and neither is one
/// that only changed.
struct NewImageDetector {
    let baseline: Set<String>
    var settle: TimeInterval = 0.5
    /// The file being followed, its last size and since when.
    private(set) var candidate: (name: String, size: Int64, since: Date)?

    init(baseline: [String: Int64], settle: TimeInterval = 0.5) {
        self.baseline = Set(baseline.keys)
        self.settle = settle
    }

    /// The name of the file once it's ready, else nil.
    mutating func observe(_ files: [String: Int64], at now: Date) -> String? {
        if let current = candidate {
            guard let size = files[current.name] else {
                // Renamed or removed while being written: look again.
                candidate = nil
                return observe(files, at: now)
            }
            if size != current.size {
                candidate = (current.name, size, now)
                return nil
            }
            return size > 0 && now.timeIntervalSince(current.since) >= settle ? current.name : nil
        }
        let new = files.keys.filter { !baseline.contains($0) }.sorted()
        guard let name = new.first, let size = files[name] else { return nil }
        candidate = (name, size, now)
        return nil
    }
}

/// An image a tool put on the clipboard: PNG as it is, anything else
/// as PNG, or an image file it copied.
enum PasteboardImage {
    enum Found {
        case data(Data, fileExtension: String)
        case file(URL)
    }

    static func read(from pasteboard: NSPasteboard) -> Found? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, CaptureImageFiles.isImage(url.lastPathComponent) {
            return .file(url)
        }
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return .data(png, fileExtension: "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return .data(png, fileExtension: "png")
        }
        return nil
    }
}

/// Files a capture took from a save folder, so a watched folder on the
/// same folder doesn't upload them a second time.
@MainActor
enum CaptureClaims {
    private static var claimed: [String: Date] = [:]
    /// Long enough for any watched folder to have seen the file.
    static let keepFor: TimeInterval = 15 * 60

    static func claim(_ url: URL) {
        let now = Date.now
        claimed = claimed.filter { now.timeIntervalSince($0.value) < keepFor }
        claimed[key(url)] = now
    }

    static func isClaimed(_ url: URL) -> Bool {
        guard let date = claimed[key(url)] else { return false }
        return Date.now.timeIntervalSince(date) < keepFor
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// A capture waiting for another tool's image, shown in the panel with
/// "Stop Waiting". A new capture ends the wait too.
@MainActor
@Observable
final class CaptureWaiting {
    static let shared = CaptureWaiting()

    /// The tool being waited for.
    private(set) var tool: CaptureTool?
    private var generation = 0

    func begin(_ tool: CaptureTool) -> Int {
        generation += 1
        self.tool = tool
        return generation
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    func end(_ generation: Int) {
        guard isCurrent(generation) else { return }
        tool = nil
    }

    func stop() {
        generation += 1
        tool = nil
    }
}
