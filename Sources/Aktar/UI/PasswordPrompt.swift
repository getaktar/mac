import AppKit

/// "Password for This Upload": asked before a file goes to a destination
/// that encrypts with a password (docs/share-pages.md, part 5). The
/// password is never kept; only the key made from it is.
@MainActor
enum PasswordPrompt {
    /// The password, or nil when cancelled or left empty: the file isn't
    /// uploaded then.
    static func ask(filename: String) -> String? {
        // The menu bar panel would sit on top of the dialog.
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = String(localized: "Password for This Upload")
        alert.informativeText = String(localized: "\u{201C}\(filename)\u{201D} is encrypted with this password. Share it separately; the link alone doesn\u{2019}t open the file.")
        alert.addButton(withTitle: String(localized: "Upload"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSSecureTextField(string: "")
        field.placeholderString = String(localized: "Password")
        let confirm = NSSecureTextField(string: "")
        confirm.placeholderString = String(localized: "Repeat Password")
        let mismatch = NSTextField(labelWithString: "")
        mismatch.textColor = .systemRed
        mismatch.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for view in [field, confirm, mismatch] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let stack = NSStackView(views: [field, confirm, mismatch])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 76)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        confirm.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        alert.layout()

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let password = field.stringValue
            guard !password.isEmpty else { return nil }
            if password == confirm.stringValue { return password }
            mismatch.stringValue = String(localized: "The passwords don\u{2019}t match.")
            confirm.stringValue = ""
            alert.window.initialFirstResponder = confirm
        }
    }
}
