import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarController: MenuBarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarPanelController(appState: appState)

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
