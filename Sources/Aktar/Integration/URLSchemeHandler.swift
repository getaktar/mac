import AppKit

extension Notification.Name {
    /// Asks the menu bar view to open a SwiftUI window; `object` is the
    /// window ID ("library", "settings"). Only views can call `openWindow`.
    static let aktarOpenWindow = Notification.Name("aktarOpenWindow")
}

/// Handles `aktar://` links:
///
///     aktar://upload-clipboard   upload whatever is on the clipboard (only
///                                while Aktar is already running, and only
///                                after the user confirms it)
///     aktar://library            open the Library window
///     aktar://settings           open Settings
///     aktar://watch              open Settings > Watched Folders
///     aktar://watch/pause?minutes=60   pause watching after the user confirms
///                                (no minutes: until resumed; 1 to 525600)
///     aktar://watch/resume       resume watching
///     aktar://connect?callback=raycast://extensions/<author>/<extension>/<command>
///     aktar://import#<data>      open Settings > Destinations to import a
///                                destination shared from another device
///                                (the transfer code is still asked for)
///
/// `connect` is how the Raycast extension pairs: after the user approves,
/// the local API is turned on and its port and token are handed back to
/// the callback as Raycast launch context. Only `raycast://extensions/…`
/// callbacks into the official extension (`merttopuz/aktar`) are accepted,
/// so a link from a web page or another extension can't collect the token.
@MainActor
enum URLSchemeHandler {
    /// `launchedApp` is true when this link is what started Aktar. A web
    /// page can open aktar:// links, so uploading the clipboard only works
    /// in an app the user already had running, never as a side effect of
    /// launching it.
    static func handle(_ url: URL, appState: AppState, launchedApp: Bool = false) {
        guard url.scheme?.lowercased() == "aktar" else { return }
        switch url.host?.lowercased() {
        case "upload-clipboard":
            guard !launchedApp else { return }
            confirmClipboardUpload(appState: appState)
        case "library":
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "library")
        case "settings":
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "settings")
        case "connect":
            connect(url)
        case "watch":
            watch(url, appState: appState)
        case "import":
            // Never saves by itself: it only fills in the link, and the
            // transfer code and Import are still up to the user.
            appState.importDestination(link: url.absoluteString)
        default:
            break
        }
    }

    private static func watch(_ url: URL, appState: AppState) {
        let service = appState.watchService
        switch url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "":
            appState.openSettings(tab: SettingsTab.watchedFolders.rawValue)
        case "pause":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // A minutes= that isn't a positive whole number: the link is
            // ignored rather than pausing for some other length.
            var minutes: Int?
            if let item = items.first(where: { $0.name == "minutes" }) {
                guard let valid = WatchPause.minutes(fromQuery: item.value) else { return }
                minutes = valid
            }
            confirmPause(minutes: minutes, service: service)
        case "resume":
            service.resume()
        default:
            break
        }
    }

    /// Any web page or app can open an aktar:// link, so uploading the
    /// clipboard that way always asks first, saying what would go where.
    private static func confirmClipboardUpload(appState: AppState) {
        guard let destination = appState.destinationStore.defaultDestination,
              let input = ClipboardService.readFileInput() else { return }
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Upload the clipboard to \u{201C}\(destination.name)\u{201D}?")
        alert.informativeText = String(localized: "A link asked Aktar to upload what\u{2019}s on your clipboard: \u{201C}\(input.originalFilename)\u{201D}. Only upload it if you opened that link yourself.")
        alert.addButton(withTitle: String(localized: "Upload"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            TempFiles.removeIfOwned(input.fileURL)
            return
        }
        appState.uploadManager.upload([input], to: destination)
    }

    /// Pausing from a link asks first too; resuming doesn't.
    private static func confirmPause(minutes: Int?, service: WatchService) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Pause Watched Folders?")
        if let minutes {
            let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
            alert.informativeText = String(localized: "A link asked Aktar to stop uploading from watched folders for \(length).")
        } else {
            alert.informativeText = String(localized: "A link asked Aktar to stop uploading from watched folders until you resume.")
        }
        alert.addButton(withTitle: String(localized: "Pause"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.pause(minutes: minutes)
    }

    /// Raycast deeplinks are raycast://extensions/<author>/<extension>/<command>.
    /// The whole path is checked, not just its start, so something like
    /// "/merttopuz/aktar/../../other/extension/command" can't slip through.
    static func isAllowedExtensionPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty,
              parts[1].lowercased() == "merttopuz", parts[2].lowercased() == "aktar" else { return false }
        let command = parts[3]
        return !command.isEmpty && command.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func connect(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let rawCallback = items.first(where: { $0.name == "callback" })?.value,
              var callback = URLComponents(string: rawCallback),
              callback.scheme?.lowercased() == "raycast",
              callback.host?.lowercased() == "extensions",
              isAllowedExtensionPath(callback.path) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect Raycast to Aktar?")
        alert.informativeText = String(localized: """
            The Raycast extension \u{201C}\(callback.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\u{201D} \
            wants to upload files, browse your buckets, and manage your upload history through Aktar. \
            This turns on Aktar\u{2019}s local API, which you can turn off any time in Settings > Integrations.
            """)
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let service = LocalAPIService.shared
        service.isEnabled = true
        let context: [String: Any] = ["aktar": ["port": Int(service.port), "token": service.token]]
        guard let data = try? JSONSerialization.data(withJSONObject: context),
              let json = String(data: data, encoding: .utf8) else { return }
        var query = (callback.queryItems ?? []).filter { $0.name != "launchContext" }
        query.append(URLQueryItem(name: "launchContext", value: json))
        callback.queryItems = query
        if let target = callback.url {
            NSWorkspace.shared.open(target)
        }
    }
}
