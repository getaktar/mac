import AppKit

/// A borderless, non-activating panel used for the menu bar popover.
/// Unlike SwiftUI's `MenuBarExtra(.window)`, this gives us control over
/// `hidesOnDeactivate`, which is what lets the panel stay open while the
/// user drags a file in from Finder (Finder briefly becoming the active
/// app would otherwise auto-dismiss the popover before the drop lands).
final class MenuBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}
