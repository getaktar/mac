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
                let name = (provider.suggestedName ?? "shared-\(Int(Date().timeIntervalSince1970))")
                var url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                if url.pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                    url.appendPathExtension(ext)
                }
                continuation.resume(returning: (try? data.write(to: url)) != nil ? url : nil)
            }
        }
    }
}
