import AppKit
import SwiftUI

/// The transfer code field: formats as it's typed, deleted or pasted into
/// "XXXX-XXXX-XXXX" (see `DestinationTransfer.editCodeInput`), keeping the
/// caret where it was. A SwiftUI TextField can only be reformatted after
/// the fact, which moves the caret to the end; an AppKit formatter gets to
/// rewrite each edit, caret included, before it's shown.
struct TransferCodeField: NSViewRepresentable {
    @Binding var text: String
    /// Bumped to move the keyboard focus into the field.
    var focusRequest: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.formatter = CodeFormatter()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .regular)
        field.placeholderString = "XXXX-XXXX-XXXX"
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Transfer Code"))
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        let shown = field.currentEditor()?.string ?? field.stringValue
        if shown != text {
            field.stringValue = text
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSText else { return }
            if text.wrappedValue != editor.string {
                text.wrappedValue = editor.string
            }
        }
    }

    /// Rewrites every edit into the formatted code and puts the caret back
    /// after the same character.
    private final class CodeFormatter: Formatter {
        override func string(for obj: Any?) -> String? {
            (obj as? String).map(DestinationTransfer.formatCodeInput)
        }

        override func getObjectValue(
            _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
            for string: String,
            errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
        ) -> Bool {
            obj?.pointee = DestinationTransfer.formatCodeInput(string) as NSString
            return true
        }

        override func isPartialStringValid(
            _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
            proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
            originalString origString: String,
            originalSelectedRange origSelRange: NSRange,
            errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
        ) -> Bool {
            let proposed = partialStringPtr.pointee as String
            let caret = proposedSelRangePtr?.pointee.location ?? (proposed as NSString).length
            // Deleting a selection takes what was selected and nothing more.
            let originalCaret = origSelRange.length == 0 ? origSelRange.location : -1
            let edit = DestinationTransfer.editCodeInput(
                proposed: proposed,
                caret: caret,
                original: origString,
                originalCaret: originalCaret
            )
            if edit.text == proposed, edit.caret == caret {
                return true
            }
            partialStringPtr.pointee = edit.text as NSString
            proposedSelRangePtr?.pointee = NSRange(location: edit.caret, length: 0)
            return false
        }
    }
}
