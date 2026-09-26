import AppKit

enum ClipboardService {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Inspects the clipboard for something uploadable: a copied file of any
    /// kind (Finder copy) takes priority, falling back to raw image bytes
    /// (a real screenshot/copy that isn't backed by a file on disk).
    static func readFileInput() -> UploadInput? {
        let pasteboard = NSPasteboard.general

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
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

        let filename = "clipboard-\(Int(Date().timeIntervalSince1970)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try pngData.write(to: url)
            return UploadInput(fileURL: url, originalFilename: filename, source: .clipboard)
        } catch {
            return nil
        }
    }
}
