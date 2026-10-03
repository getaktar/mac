import AppKit
import SwiftUI

/// "Import from Another Device": a transfer link, scanned with the camera
/// or pasted, and the transfer code shown on the other device, then the
/// destination form filled in with what it carried. Nothing is saved until
/// Import is pressed there.
struct ImportDestinationView: View {
    /// A link from aktar://import, already filled in.
    var initialLink: String?
    /// After the destination was saved.
    var onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var link = ""
    @State private var linkError: String?
    @State private var code = ""
    @State private var codeError: String?
    @State private var isOpening = false
    @State private var scanner = TransferScanner()
    /// Set once the code worked: the form takes over.
    @State private var imported: Imported?
    @FocusState private var codeFocused: Bool

    init(initialLink: String? = nil, onImported: @escaping () -> Void) {
        self.initialLink = initialLink
        self.onImported = onImported
    }

    private struct Imported {
        var payload: DestinationTransfer.Payload
        /// The destination it updates, for Update Existing.
        var existing: DestinationConfig?
    }

    var body: some View {
        if let imported {
            DestinationFormView(existing: imported.existing, imported: imported.payload) { config, credentials in
                save(config, credentials: credentials, payload: imported.payload, updating: imported.existing != nil)
            }
        } else {
            linkAndCode
        }
    }

    private var linkAndCode: some View {
        VStack(spacing: 0) {
            Text("Import from Another Device")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                Section {
                    scanSection
                }

                Section {
                    TextField("Paste Transfer Link", text: $link, prompt: Text("Paste the transfer link here"))
                        .onChange(of: link) { checkLink() }
                    if let linkError {
                        Label(linkError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if hasValidLink {
                    Section {
                        TextField("Transfer Code", text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX"))
                            .font(.system(.title3, design: .monospaced))
                            .focused($codeFocused)
                            .onSubmit { openLink() }
                            .onChange(of: code) { codeError = nil }
                        if let codeError {
                            Label(codeError, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Transfer Code")
                    } footer: {
                        Text("Enter the transfer code shown on the other device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if isOpening {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") { openLink() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasValidLink || code.isEmpty || isOpening)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .onAppear {
            scanner.onFound = { text in
                link = text
                checkLink()
            }
            if let initialLink {
                link = initialLink
                checkLink()
            }
        }
        .onDisappear { scanner.stop() }
    }

    @ViewBuilder
    private var scanSection: some View {
        switch scanner.state {
        case .scanning, .starting:
            VStack(spacing: 8) {
                CameraPreview(session: scanner.capture.session)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("Point the camera at the QR code on your other device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { scanner.stop() }
                        .controlSize(.small)
                }
            }
        case .noCamera:
            Label("No camera found. Paste the transfer link instead.", systemImage: "video.slash")
                .foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Camera access is off. Turn it on in Settings, or paste the transfer link instead.", systemImage: "video.slash")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { TransferScanner.openPrivacySettings() }
            }
        case .idle:
            Button {
                linkError = nil
                scanner.start()
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        }
    }

    private var hasValidLink: Bool {
        !link.isEmpty && linkError == nil
    }

    /// A link that can't work is turned away before a code is asked for.
    private func checkLink() {
        codeError = nil
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            linkError = nil
            return
        }
        do {
            try DestinationTransfer.envelope(from: link)
            linkError = nil
            scanner.stop()
            codeFocused = true
        } catch {
            linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openLink() {
        guard hasValidLink, !isOpening else { return }
        guard DestinationTransfer.normalizeCode(code) != nil else {
            codeError = DestinationTransferError.wrongCode.errorDescription
            codeFocused = true
            return
        }
        isOpening = true
        let link = link
        let code = code
        Task {
            defer { isOpening = false }
            do {
                // The key derivation is slow on purpose; keep it off the main thread.
                let payload = try await Task.detached(priority: .userInitiated) {
                    try DestinationTransfer.open(link, code: code)
                }.value
                resolveDuplicate(payload)
            } catch let error as DestinationTransferError where error == .wrongCode {
                codeError = error.errorDescription
                codeFocused = true
            } catch {
                linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The same destination (by ID) is already here: update it, or keep
    /// both under a new ID and a "Copy" name.
    private func resolveDuplicate(_ payload: DestinationTransfer.Payload) {
        guard let existing = appState.destinationStore.destinations.first(where: { $0.id == payload.destination.id }) else {
            imported = Imported(payload: payload, existing: nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "\u{201C}\(existing.name)\u{201D} is already on this device.")
        if !DestinationTransfer.uploadsToSamePlace(payload.destination, as: existing) {
            alert.informativeText = String(localized: "The imported settings upload to a different place than \u{201C}\(existing.name)\u{201D} does now. Only update it if you trust where this link came from.")
        }
        alert.addButton(withTitle: String(localized: "Update Existing"))
        alert.addButton(withTitle: String(localized: "Add as Copy"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var payload = payload
            payload.destination.isDefault = existing.isDefault
            imported = Imported(payload: payload, existing: existing)
        case .alertSecondButtonReturn:
            var payload = payload
            payload.destination.id = UUID()
            payload.destination.name = String(localized: "\(payload.destination.name) Copy")
            imported = Imported(payload: payload, existing: nil)
        default:
            break
        }
    }

    private func save(_ config: DestinationConfig, credentials: StorageCredentials, payload: DestinationTransfer.Payload, updating: Bool) {
        let store = appState.destinationStore
        try? KeychainService.save(credentials, for: config.id)
        // `add` makes it the default when it's the first one here.
        if updating {
            store.update(config)
        } else {
            store.add(config)
        }
        // The template is app-wide here, so it's only taken over while this
        // Mac still has the default one.
        let manager = appState.uploadManager
        if let template = payload.customTemplate, manager.customTemplate == UploadManager.defaultCustomTemplate {
            manager.customTemplate = template
        }
        onImported()
    }
}
