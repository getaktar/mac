import AppKit

enum ClipboardService {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Goes up with every change to the clipboard, by any app.
    static var changeCount: Int { NSPasteboard.general.changeCount }

    static var string: String? { NSPasteboard.general.string(forType: .string) }

    static func clear() {
        NSPasteboard.general.clearContents()
    }

    /// Copies a secret (the local API token, a transfer link) marked as
    /// concealed and transient (nspasteboard.org), so clipboard managers
    /// that follow the convention neither show nor keep it. Returns the
    /// pasteboard's change count, for `clearIfStillCopied`.
    @discardableResult
    static func copySecret(_ string: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        return pasteboard.changeCount
    }

    /// Empties the clipboard when it still holds what `copySecret` put
    /// there (nothing was copied since).
    static func clearIfStillCopied(_ string: String, changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount, pasteboard.string(forType: .string) == string else { return }
        pasteboard.clearContents()
    }

    /// Inspects the clipboard for something uploadable, in this order:
    /// - a copied file of any kind (Finder copy),
    /// - raw image bytes (a screenshot or an image copied from an app),
    /// - a link (the whole text is one http(s) address): the file it points
    ///   to is downloaded when the upload starts,
    /// - text, saved as a .txt, .md or .json file.
    static func readInput() -> UploadInput? {
        let pasteboard = NSPasteboard.general

        // Files only here: a copied web link is handled below, after the
        // image that may have been copied along with it.
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let fileURL = fileURLs.first {
            return UploadInput(fileURL: fileURL, originalFilename: fileURL.lastPathComponent, source: .clipboard)
        }

        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return writeTemporaryImage(image)
            }
        }

        let text = pasteboard.string(forType: .string) ?? ""
        if let link = ClipboardText.link(in: text) ?? copiedWebLink(pasteboard, text: text) {
            return remoteInput(for: link)
        }
        if ClipboardText.hasContent(text) {
            return writeTemporaryText(text)
        }
        return nil
    }

    /// A link copied with "Copy Link" whose text is its title (one line)
    /// or nothing, rather than the address itself.
    private static func copiedWebLink(_ pasteboard: NSPasteboard, text: String) -> URL? {
        guard !text.contains(where: \.isNewline),
              let raw = pasteboard.string(forType: .URL) else { return nil }
        return ClipboardText.link(in: raw)
    }

    /// An upload whose file is downloaded from `link` first. Its file goes
    /// in a folder of its own among the clipboard's, so it's deleted with
    /// the upload like a copied image.
    static func remoteInput(for link: URL) -> UploadInput? {
        let source = RemoteSource(url: link)
        guard let folder = try? TempFiles.newFolder(in: TempFiles.clipboard),
              let placeholder = TempFiles.fileURL(named: source.suggestedName, in: folder) else { return nil }
        var input = UploadInput(fileURL: placeholder, originalFilename: source.suggestedName, source: .clipboard)
        input.remote = source
        return input
    }

    private static func writeTemporaryText(_ text: String) -> UploadInput? {
        let id = UUID().uuidString.lowercased()
        let filename = "clipboard-\(id.prefix(8)).\(ClipboardText.kind(of: text).fileExtension)"
        do {
            let url = try TempFiles.newFolder(in: TempFiles.clipboard).appendingPathComponent(filename)
            try Data(text.utf8).write(to: url)
            return UploadInput(fileURL: url, originalFilename: filename, source: .clipboard)
        } catch {
            return nil
        }
    }

    private static func writeTemporaryImage(_ image: NSImage) -> UploadInput? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        // A folder of its own, so two images copied within the same second
        // never share a file; it's deleted once the upload is done with it
        // (see `TempFiles`).
        let id = UUID().uuidString.lowercased()
        let filename = "clipboard-\(id.prefix(8)).png"
        do {
            let url = try TempFiles.newFolder(in: TempFiles.clipboard).appendingPathComponent(filename)
            try pngData.write(to: url)
            return UploadInput(fileURL: url, originalFilename: filename, source: .clipboard)
        } catch {
            return nil
        }
    }
}
