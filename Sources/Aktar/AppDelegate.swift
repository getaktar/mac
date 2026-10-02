import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarController: MenuBarPanelController?
    private var finderService: FinderService?

    /// aktar:// links that arrive before launch finishes are the ones that
    /// launched the app. They're held until the app is set up, and handled
    /// as launch links so actions that should only run in an already open
    /// app (uploading the clipboard) are skipped.
    private var hasFinishedLaunching = false
    private var launchURLs: [URL] = []
    private let launchDate = Date()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so an answer to a delete ask that launched
        // the app reaches it.
        UNUserNotificationCenter.current().delegate = appState.watchService.notificationActions
        appState.watchService.notificationActions.service = appState.watchService
        NotificationService.registerCategories()
        // Handle aktar:// links ourselves. Left to SwiftUI, a URL open would
        // bring up one of the app's windows instead of just running the action.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarPanelController(appState: appState)
        LocalAPIService.shared.configure(appState: appState)
        appState.watchService.start()

        // "Upload with Aktar" in Finder's right-click menu; see FinderService.
        let finderService = FinderService(appState: appState)
        self.finderService = finderService
        NSApp.servicesProvider = finderService
        NSUpdateDynamicServices()

        // Aktar is an accessory app (no Dock icon) so it stays out of the way
        // day-to-day, but that also hides it from Cmd+Tab even while a real
        // window (Library, Settings) is open. Promote to a regular app for
        // as long as one of those windows is open, then demote back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        hasFinishedLaunching = true
        // Next run loop turn, once the menu bar view (which opens windows
        // for aktar://settings and aktar://library) is up and listening.
        let pending = launchURLs
        launchURLs = []
        DispatchQueue.main.async { [appState] in
            for url in pending {
                URLSchemeHandler.handle(url, appState: appState, launchedApp: true)
            }
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        guard hasFinishedLaunching else {
            launchURLs.append(url)
            return
        }
        // Belt and braces in case the launch link is delivered just after
        // launch instead of during it.
        let justLaunched = Date().timeIntervalSince(launchDate) < 2
        URLSchemeHandler.handle(url, appState: appState, launchedApp: justLaunched)
    }

    private func isTrackedWindow(_ window: NSWindow) -> Bool {
        !(window is MenuBarPanel) && !(window is NSOpenPanel) && !(window is NSSavePanel)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isTrackedWindow(window) else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, isTrackedWindow(closingWindow) else { return }
        DispatchQueue.main.async {
            let hasOtherTrackedWindows = NSApp.windows.contains { candidate in
                candidate !== closingWindow && candidate.isVisible && self.isTrackedWindow(candidate)
            }
            if !hasOtherTrackedWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
