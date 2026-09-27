import AppKit

extension Notification.Name {
    /// Asks the menu bar view to open a SwiftUI window; `object` is the
    /// window ID ("library", "settings"). Only views can call `openWindow`.
    static let aktarOpenWindow = Notification.Name("aktarOpenWindow")
}

/// Handles `aktar://` links:
///
///     aktar://upload-clipboard   upload whatever is on the clipboard (only
///                                while Aktar is already running)
///     aktar://library            open the Library window
///     aktar://settings           open Settings
///     aktar://connect?callback=raycast://extensions/<author>/<extension>/<command>
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
            appState.uploadFromClipboard()
        case "library":
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "library")
        case "settings":
            NotificationCenter.default.post(name: .aktarOpenWindow, object: "settings")
        case "connect":
            connect(url)
        default:
            break
        }
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
