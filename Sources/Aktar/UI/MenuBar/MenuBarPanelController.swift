import AppKit
import SwiftData
import SwiftUI

extension Notification.Name {
    static let aktarClosePanel = Notification.Name("aktarClosePanel")
}

/// Owns the status bar icon and the popover panel. Replaces SwiftUI's
/// `MenuBarExtra`, which cannot be configured to survive a drag-and-drop
/// session started in another app (see `MenuBarPanel`).
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = MenuBarPanel()
        super.init()

        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            icon?.accessibilityDescription = "Aktar"
            button.image = icon
            button.target = self
            button.action = #selector(togglePanel)
        }

        let hostingView = NSHostingView(
            rootView: MenuBarView()
                .environment(appState)
                .modelContext(appState.repository.modelContext)
        )
        panel.contentView = hostingView
        panel.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClosePanelNotification),
            name: .aktarClosePanel,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleClosePanelNotification() {
        closePanel()
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let contentSize = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 400)
        panel.setContentSize(contentSize)

        let panelX = buttonFrameInScreen.midX - contentSize.width / 2
        let panelY = buttonFrameInScreen.minY - contentSize.height - 4
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startMonitoringOutsideClicks()
    }

    func closePanel() {
        panel.orderOut(nil)
        stopMonitoringOutsideClicks()
    }

    private func startMonitoringOutsideClicks() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handlePossibleOutsideClick()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handlePossibleOutsideClick()
            return event
        }
    }

    private func stopMonitoringOutsideClicks() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    private func handlePossibleOutsideClick() {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) { return }
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(location) { return }
        }

        // This click was outside the panel. If it's the start of a drag (for
        // example dragging a file in from Finder) the mouse button will still
        // be down a moment later; don't dismiss the panel out from under a
        // drag that might be headed for our drop zone. Only close once we
        // can tell this was a plain click, not a drag.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if NSEvent.pressedMouseButtons != 0 { return }
            self.closePanel()
        }
    }
}
