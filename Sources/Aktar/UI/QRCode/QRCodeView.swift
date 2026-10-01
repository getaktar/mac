import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// QR codes for upload links, drawn with Core Image: black modules on
/// white with the standard four-module quiet zone, so they scan in dark
/// mode too.
enum QRCodeRenderer {
    private static let quietZone = 4

    /// One pixel per module at `scale` 1; shown with interpolation off it
    /// stays sharp at any size. Error correction level M.
    static func image(for string: String, scale: Int = 1) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let modules = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let side = (modules.width + quietZone * 2) * scale
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        let inset = quietZone * scale
        context.draw(modules, in: CGRect(x: inset, y: inset, width: modules.width * scale, height: modules.height * scale))
        return context.makeImage()
    }

    /// A PNG big enough to print or paste: 12 pixels per module.
    static func pngData(for string: String) -> Data? {
        guard let image = image(for: string, scale: 12) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

struct QRCodeView: View {
    let link: URL
    /// The upload's file name, for naming a saved image.
    let filename: String

    var body: some View {
        VStack(spacing: 14) {
            if let image = QRCodeRenderer.image(for: link.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text("QR Code"))
            }
            Text("Scan to open the link")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(link.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(link.absoluteString)
                .frame(maxWidth: 260)
            HStack {
                Button("Copy Image") { copyImage() }
                Button("Save Image\u{2026}") { saveImage() }
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func copyImage() {
        guard let png = QRCodeRenderer.pngData(for: link.absoluteString), let image = NSImage(data: png) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(png, forType: .png)
    }

    private func saveImage() {
        guard let png = QRCodeRenderer.pngData(for: link.absoluteString) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let base = (filename as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "QR" : base + " QR") + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
        }
    }
}

/// The "QR Code" window. One at a time; showing another link replaces it.
@MainActor
final class QRCodeWindowController: NSObject, NSWindowDelegate {
    static let shared = QRCodeWindowController()
    private var window: NSWindow?

    /// The link copying `record` would give: a fresh temporary link when
    /// its destination uses them, otherwise the public URL.
    func show(for record: UploadRecord, uploadManager: UploadManager) {
        let filename = record.localFilename
        Task {
            guard let link = await uploadManager.shareLink(for: record) else {
                NSSound.beep()
                return
            }
            show(link: link, filename: filename)
        }
    }

    /// A temporary link valid for `duration`.
    func show(for record: UploadRecord, validFor duration: TemporaryLinkDuration, uploadManager: UploadManager) {
        let filename = record.localFilename
        Task {
            do {
                let link = try await uploadManager.temporaryURL(for: record, validFor: duration)
                show(link: link, filename: filename)
            } catch {
                NSSound.beep()
            }
        }
    }

    func show(link: URL, filename: String) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        let hosting = NSHostingController(rootView: QRCodeView(link: link, filename: filename))
        let window = self.window ?? {
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            return window
        }()
        window.contentViewController = hosting
        window.title = String(localized: "QR Code")
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }
}
