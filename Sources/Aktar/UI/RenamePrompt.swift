import AppKit

/// "Name This Upload": lets the user name a file before it's uploaded.
/// The name replaces {filename} in the destination's path and is what
/// history shows; the extension stays the file's own (or the converted
/// one, for a photo the destination converts).
@MainActor
enum RenamePrompt {
    /// One dialog per input, in order. Cancel skips that file.
    static func rename(_ inputs: [UploadInput]) -> [UploadInput] {
        guard !inputs.isEmpty else { return [] }
        // The menu bar panel would sit on top of the dialog.
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        return inputs.compactMap { input in
            guard let name = ask(filename: input.originalFilename) else { return nil }
            var renamed = input
            renamed.originalFilename = name
            return renamed
        }
    }

    /// The new full name, or nil when cancelled.
    static func ask(filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension

        let alert = NSAlert()
        alert.messageText = String(localized: "Name This Upload")
        alert.addButton(withTitle: String(localized: "Upload"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(string: base)
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [field])
        stack.orientation = .horizontal
        stack.spacing = 4
        if !ext.isEmpty {
            let suffix = NSTextField(labelWithString: "." + ext)
            suffix.textColor = .secondaryLabelColor
            suffix.setContentHuggingPriority(.required, for: .horizontal)
            suffix.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(suffix)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        alert.layout()
        field.selectText(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = sanitized(field.stringValue)
        guard !name.isEmpty else { return filename }
        return ext.isEmpty ? name : name + "." + ext
    }

    /// No folder separators, and no surrounding whitespace. Empty keeps
    /// the original name.
    static func sanitized(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
