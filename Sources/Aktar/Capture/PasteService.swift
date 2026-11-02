import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Upload and paste: after the link is copied, Aktar presses ⌘V for the
/// user in the app they were typing in (docs/capture-and-instant-links.md,
/// "Upload and paste"). Posting key presses needs the Accessibility
/// permission (Device Control and Data Access from macOS 27); without it
/// the link is only copied.
@MainActor
enum PasteService {
    /// Whether Aktar may press keys for the user.
    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    /// The list in System Settings > Privacy & Security that Aktar has to be
    /// turned on in: "Accessibility" until macOS 26, "Device Control and
    /// Data Access" from macOS 27 (the same page, renamed).
    static var permissionPaneName: String {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            ? String(localized: "Device Control and Data Access")
            : String(localized: "Accessibility")
    }

    /// Without the permission, Aktar explains first (macOS doesn't always
    /// show its own request) and offers to open Settings. The upload goes
    /// ahead either way, with the link copied.
    static func ensurePermission() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        showPermissionAlert()
        return false
    }

    static func showPermissionAlert() {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Aktar to paste for you")
        alert.informativeText = String(localized: "To paste the link where you\u{2019}re typing, Aktar presses \u{2318}V for you, which macOS asks you to allow. Turn on Aktar in System Settings > Privacy & Security > \(permissionPaneName). Until then the link is copied and you can paste it yourself.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            // Lists Aktar on that page (the first time, macOS may also ask
            // itself); the page opens when it doesn't.
            if !CGRequestPostEventAccess() { SystemSettingsLink.open(.accessibility) }
        }
    }

    /// Presses ⌘V in the frontmost app, once the keys of the shortcut that
    /// started it are let go (so the app doesn't see ⌃⇧⌘V). False when it
    /// couldn't be done.
    @discardableResult
    static func paste() async -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        await waitForModifierRelease()
        let keyCode = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// Waits up to a second and a half for ⌘, ⌥, ⌃ and ⇧ to be up.
    private static func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for _ in 0..<30 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The key that types `character` while ⌘ is held, in the keyboard
    /// layout used for shortcuts (so ⌘V is found on Dvorak, Turkish F or a
    /// "⌘ QWERTY" layout alike). Nil when the layout can't be read.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let target = String(character).lowercased()
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), commandState, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
                )
                if status == noErr, length > 0,
                   String(utf16CodeUnits: characters, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}

/// Where an upload's link is pasted: the app that was in front when the
/// shortcut was pressed, if it still is, and only for a little while (a
/// link that turns up much later isn't pasted into whatever is in front
/// by then; it stays copied).
struct PasteRequest {
    let processID: pid_t
    let deadline: Date

    /// For the frontmost app, `seconds` from now.
    @MainActor
    static func frontmost(for seconds: TimeInterval = 30) -> PasteRequest? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return PasteRequest(processID: app.processIdentifier, deadline: Date.now.addingTimeInterval(seconds))
    }

    @MainActor
    var isStillValid: Bool {
        Date.now < deadline && NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }
}
