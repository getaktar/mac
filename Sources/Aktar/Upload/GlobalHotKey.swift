import Foundation
import KeyboardShortcuts

/// User-customizable, system-wide shortcut to paste & upload the clipboard
/// without opening the menu bar panel. Backed by Carbon's hotkey APIs (via
/// the KeyboardShortcuts package), which need no Accessibility or Input
/// Monitoring permission - only a real key press from the user triggers it.
extension KeyboardShortcuts.Name {
    nonisolated(unsafe) static let uploadFromClipboard = Self(
        "uploadFromClipboard",
        default: .init(.u, modifiers: [.command, .shift, .control])
    )

    /// The same, but asking for the file's name first. Unset by default.
    nonisolated(unsafe) static let renameAndUploadFromClipboard = Self("renameAndUploadFromClipboard")

    /// A destination's own shortcut: uploads the clipboard there, whatever
    /// "Use for" says. Unset by default; kept on this Mac only.
    static func uploadToDestination(_ id: UUID) -> Self {
        Self("uploadToDestination-\(id.uuidString)")
    }
}
