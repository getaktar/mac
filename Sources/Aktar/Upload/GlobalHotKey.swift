import Foundation
import KeyboardShortcuts

/// User-customizable, system-wide shortcut to paste & upload the clipboard
/// without opening the menu bar panel. Backed by Carbon's hotkey APIs (via
/// the KeyboardShortcuts package), which need no Accessibility or Input
/// Monitoring permission - only a real key press from the user triggers it.
extension KeyboardShortcuts.Name {
    static let uploadFromClipboard = Self(
        "uploadFromClipboard",
        initial: .init(.u, modifiers: [.command, .shift, .control])
    )

    /// The same, but asking for the file's name first. Unset by default.
    static let renameAndUploadFromClipboard = Self("renameAndUploadFromClipboard")

    /// Uploads the clipboard and pastes the link where the user is typing
    /// (needs Accessibility; see `PasteService`). Unset by default.
    static let uploadClipboardAndPaste = Self("uploadClipboardAndPaste")

    /// Capture an area or window and upload it; see `ScreenCapture`. Unset
    /// by default.
    static let captureAndUpload = Self("captureAndUpload")

    /// The same, then the link is pasted. Unset by default.
    static let captureUploadAndPaste = Self("captureUploadAndPaste")

    /// Takes back the latest upload while Undo is offered for it. Unset by
    /// default.
    static let undoLastUpload = Self("undoLastUpload")

    /// A destination's own shortcut: uploads the clipboard there, whatever
    /// "Use for" says. Unset by default; kept on this Mac only.
    static func uploadToDestination(_ id: UUID) -> Self {
        Self("uploadToDestination-\(id.uuidString)")
    }
}
