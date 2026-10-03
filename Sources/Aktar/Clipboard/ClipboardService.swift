import AppKit

enum ClipboardService {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
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

    /// Inspects the clipboard for something uploadable: a copied file of any
    /// kind (Finder copy) takes priority, falling back to raw image bytes
    /// (a real screenshot/copy that isn't backed by a file on disk).
    static func readFileInput() -> UploadInput? {
        let pasteboard = NSPasteboard.general

        // Files only: a copied web link isn't something to upload, and the
        // image copied along with it (if any) is tried next.
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
        return nil
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
