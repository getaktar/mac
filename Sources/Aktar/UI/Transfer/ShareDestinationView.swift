import AppKit
import SwiftUI

/// "Share to Another Device": a destination and its keys as a QR code for
/// Aktar on another device, encrypted with a transfer code shown next to
/// it. The code is never in the QR code or the copied link, so a photo of
/// the screen or a forwarded link isn't enough on its own.
struct ShareDestinationView: View {
    let link: String
    let code: String

    @State private var didCopyLink = false

    var body: some View {
        VStack(spacing: 14) {
            if let image = QRCodeRenderer.image(for: link) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text("QR Code"))
            }

            Text("Scan this QR code with Aktar on your other device, then enter the transfer code there.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                Text("Transfer Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: DestinationTransfer.displayCode(code))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }

            Label("This QR code contains your access keys. Only scan it with your own devices.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                Button("Copy Transfer Link") { copyLink() }
                if didCopyLink {
                    Text("Link copied. Share the transfer code separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Text("For your security, this closes after 10 minutes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }

    /// Only the link: the code has to travel another way.
    private func copyLink() {
        let changeCount = ClipboardService.copySecret(link)
        ShareDestinationWindowController.shared.linkCopied(link, changeCount: changeCount)
        didCopyLink = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            didCopyLink = false
        }
    }
}

/// The "Share to Another Device" window. One at a time; every opening
/// makes a new code, and closing it (by hand or after 10 minutes) forgets it.
@MainActor
final class ShareDestinationWindowController: NSObject, NSWindowDelegate {
    static let shared = ShareDestinationWindowController()
    static let lifetime: Duration = .seconds(10 * 60)

    private var window: NSWindow?
    private var closeTask: Task<Void, Never>?
    private var sealTask: Task<Void, Never>?
    /// The link this window copied, cleared from the clipboard when the
    /// window closes unless something else was copied since.
    private var copiedLink: (link: String, changeCount: Int)?

    func linkCopied(_ link: String, changeCount: Int) {
        copiedLink = (link, changeCount)
    }

    /// Reads the keys first; if they're gone, says so instead.
    func show(_ destination: DestinationConfig, customTemplate: String) {
        let credentials: StorageCredentials
        do {
            credentials = try KeychainService.load(for: destination.id)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = destination.name
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        close()
        let payload = DestinationTransfer.Payload(destination: destination, credentials: credentials, customTemplate: customTemplate)
        let code = DestinationTransfer.generateCode()
        sealTask = Task {
            // The key derivation is slow on purpose; keep it off the main thread.
            let link = try? await Task.detached(priority: .userInitiated) {
                try DestinationTransfer.seal(payload, code: code)
            }.value
            guard !Task.isCancelled else { return }
            guard let link else {
                NSSound.beep()
                return
            }
            present(ShareDestinationView(link: link, code: code), title: destination.name)
        }
    }

    private func present(_ view: ShareDestinationView, title: String) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        let hosting = NSHostingController(rootView: view)
        let window = self.window ?? {
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // The QR code and code carry the access keys: keep them out of
            // screenshots, screen recordings and screen sharing.
            window.sharingType = .none
            window.delegate = self
            return window
        }()
        window.contentViewController = hosting
        window.title = title
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        sealTask?.cancel()
        sealTask = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        closeTask?.cancel()
        closeTask = nil
        if let copiedLink {
            ClipboardService.clearIfStillCopied(copiedLink.link, changeCount: copiedLink.changeCount)
            self.copiedLink = nil
        }
        // Drops the view, and with it the code and the link.
        window?.contentViewController = nil
    }
}
