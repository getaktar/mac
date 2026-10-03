import AppKit
import UniformTypeIdentifiers

/// "Aktar" in the Share menu of Finder, Photos, Safari and other apps.
///
/// The extension doesn't upload anything itself: it hands the shared files
/// to the app's "Upload with Aktar" service (see FinderService), which
/// launches Aktar if needed and gives it read access to exactly these
/// files. Items that aren't files, such as an image copied out of a web
/// page, are written to a temporary file first.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Self.removeOldCopies()
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.getaktar.mac.share.\(UUID().uuidString)"))
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
                _ = NSPerformService("Upload with Aktar", pasteboard)
                pasteboard.releaseGlobally()
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
            return url
        }
        // Not backed by a file: write it out, keeping the type's extension.
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                guard let data else { return continuation.resume(returning: nil) }
                // A folder of its own per item, so two shares never write
                // to the same file.
                let id = UUID().uuidString.lowercased()
                let directory = copiesFolder.appendingPathComponent(id, isDirectory: true)
                var name = (provider.suggestedName ?? "shared-\(id.prefix(8))")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                if name.isEmpty || name == "." || name == ".." { name = "shared-\(id.prefix(8))" }
                var url = directory.appendingPathComponent(name)
                if url.pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    url.appendPathExtension(ext)
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: url)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Copies of shared items that weren't files, in the extension's own
    /// temporary folder. Aktar only gets to read them, so the extension
    /// deletes them itself the next time it runs, once they're a day old
    /// (by then the upload that needed one is long over).
    private static var copiesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AktarShare", isDirectory: true)
    }

    private static func removeOldCopies() {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        let folders = (try? manager.contentsOfDirectory(at: copiesFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? manager.removeItem(at: folder) }
        }
    }
}
