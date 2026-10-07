import AppKit
import SwiftUI

/// "Import from Another Device": a transfer link, scanned with the camera
/// or pasted, and the transfer code shown on the other device. Where the
/// destination it carries sends files and links is shown for review first
/// (its webhooks, scripts, "Use for" rules and template only come along if
/// they're kept there), then it's saved, Test Connection runs by itself and
/// its result is shown, with Edit for anything to change.
struct ImportDestinationView: View {
    /// A link from aktar://import, already filled in.
    var initialLink: String?
    /// Done, or the destination saved again from Edit.
    var onImported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var link = ""
    @State private var linkError: String?
    @State private var code = ""
    @State private var codeError: String?
    @State private var isOpening = false
    @State private var scanner = TransferScanner()
    /// Bumped to put the keyboard focus in the code field.
    @State private var codeFocusRequest = 0
    @State private var step = Step.link
    @State private var testResult: ConnectionResult?
    /// Why the test couldn't reach the bucket at all.
    @State private var testError: String?
    @State private var isTesting = false
    @State private var keepHooks = false
    @State private var keepUseFor = false
    @State private var keepTemplate = false

    init(initialLink: String? = nil, onImported: @escaping () -> Void) {
        self.initialLink = initialLink
        self.onImported = onImported
    }

    private enum Step {
        case link
        /// Opened: what it brings, before it's saved.
        case review(DestinationTransfer.Payload, existing: DestinationConfig?)
        /// Saved: the test and its result.
        case saved(DestinationConfig, updated: Bool)
        /// Edit, the usual form for the saved destination.
        case editing(DestinationConfig)
    }

    var body: some View {
        switch step {
        case .link:
            linkAndCode
        case .review(let payload, let existing):
            review(payload, existing: existing)
        case .saved(let config, let updated):
            savedResult(config, updated: updated)
        case .editing(let config):
            DestinationFormView(existing: config) { config, credentials in
                appState.destinationStore.update(config)
                try? KeychainService.save(credentials, for: config.id)
                onImported()
            }
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
                        LabeledContent("Transfer Code") {
                            TransferCodeField(text: $code, focusRequest: codeFocusRequest)
                        }
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
            codeFocusRequest += 1
        } catch {
            linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func openLink() {
        guard hasValidLink, !isOpening else { return }
        guard DestinationTransfer.normalizeCode(code) != nil else {
            codeError = DestinationTransferError.wrongCode.errorDescription
            codeFocusRequest += 1
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
                codeFocusRequest += 1
            } catch {
                linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The same destination (by ID) is already here: update it, or keep
    /// both under a new ID and a "Copy" name.
    private func resolveDuplicate(_ payload: DestinationTransfer.Payload) {
        guard let existing = appState.destinationStore.destinations.first(where: { $0.id == payload.destination.id }) else {
            startReview(payload, updating: nil)
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
            startReview(payload, updating: existing)
        case .alertSecondButtonReturn:
            var payload = payload
            payload.destination.id = UUID()
            payload.destination.name = String(localized: "\(payload.destination.name) Copy")
            startReview(payload, updating: nil)
        default:
            break
        }
    }

    private func startReview(_ payload: DestinationTransfer.Payload, updating existing: DestinationConfig?) {
        keepHooks = false
        keepUseFor = false
        keepTemplate = false
        step = .review(payload, existing: existing)
    }

    /// The template is app-wide here, so it's only taken over while this
    /// Mac still has the default one.
    private func templateApplies(_ payload: DestinationTransfer.Payload) -> Bool {
        payload.customTemplate != nil && appState.uploadManager.customTemplate == UploadManager.defaultCustomTemplate
    }

    private func review(_ payload: DestinationTransfer.Payload, existing: DestinationConfig?) -> some View {
        let config = payload.destination
        let hookCount = config.hooks?.count ?? 0
        return VStack(spacing: 0) {
            Text("Review Before Importing")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                Section {
                    LabeledContent("Name", value: config.name)
                    LabeledContent("Storage", value: "\(payload.endpointHost) \u{00B7} \(config.bucket)")
                    LabeledContent("Links", value: payload.publicHost)
                    if let shortLinkHost = payload.shortLinkHost {
                        LabeledContent("Short Links", value: shortLinkHost)
                    }
                } header: {
                    Text("Where Files and Links Go")
                } footer: {
                    Text("Only import this if you trust where the link came from.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hookCount > 0 {
                    Section {
                        ForEach(Array(payload.webhookHosts.enumerated()), id: \.offset) { _, host in
                            Label(host, systemImage: "network")
                        }
                        ForEach(Array(payload.scriptNames.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "terminal")
                        }
                        Toggle("Keep webhooks and scripts (\(hookCount))", isOn: $keepHooks)
                    } header: {
                        Text("After Upload")
                    } footer: {
                        Text("Webhooks receive each upload\u{2019}s link and file name, and scripts run on this Mac. Left off, they\u{2019}re imported turned off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let routing = config.useFor, !routing.isEmpty {
                    Section {
                        Text(verbatim: ListFormatter.localizedString(byJoining: routing.kinds.map(\.label) + routing.extensions.map { "." + $0 }))
                        Toggle("Keep \u{201C}Use for\u{201D} rules", isOn: $keepUseFor)
                    } header: {
                        Text("Use For")
                    } footer: {
                        Text("These files would go to this destination instead of your default one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if templateApplies(payload), let template = payload.customTemplate {
                    Section {
                        Text(verbatim: template)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Toggle("Use this output template", isOn: $keepTemplate)
                    } header: {
                        Text("Output Template")
                    } footer: {
                        Text("What Aktar copies after an upload.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? String(localized: "Import") : String(localized: "Update Existing")) {
                    save(
                        payload.reviewed(keepHooks: keepHooks, keepUseFor: keepUseFor, keepTemplate: keepTemplate && templateApplies(payload)),
                        updating: existing
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
    }

    /// Saves the destination as reviewed, keys included, then tests it. A
    /// failed test leaves it saved; Edit is there to fix it.
    private func save(_ payload: DestinationTransfer.Payload, updating existing: DestinationConfig?) {
        let store = appState.destinationStore
        var config = payload.destination
        try? KeychainService.save(payload.credentials, for: config.id)
        if let existing {
            config.isDefault = existing.isDefault
            // Auto-delete stays as it was while it's the same bucket; another
            // bucket hasn't been checked for the rules.
            let sameBucket = DestinationFormView.Connection(existing) == DestinationFormView.Connection(config)
            ExpiryRuleStore.shared.set(config.id, active: sameBucket && ExpiryRuleStore.shared.isActive(existing.id))
            store.update(config)
        } else {
            // A new destination hasn't been checked for the rules either.
            ExpiryRuleStore.shared.set(config.id, active: false)
            // `add` makes it the default when it's the first one here.
            store.add(config)
        }
        // Only when it was kept in the review, which offers it only while
        // this Mac still has the default one.
        let manager = appState.uploadManager
        if let template = payload.customTemplate, manager.customTemplate == UploadManager.defaultCustomTemplate {
            manager.customTemplate = template
        }
        step = .saved(config, updated: existing != nil)
        // Before the result step first draws, so it starts on "Testing…".
        isTesting = true
        Task { await testConnection(config, credentials: payload.credentials) }
    }

    private func testConnection(_ config: DestinationConfig, credentials: StorageCredentials) async {
        isTesting = true
        defer { isTesting = false }
        do {
            testResult = try await S3Provider(config: config, credentials: credentials).testConnection()
            testError = nil
        } catch {
            testResult = nil
            testError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func savedResult(_ config: DestinationConfig, updated: Bool) -> some View {
        VStack(spacing: 0) {
            Text("Import from Another Device")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                Section {
                    Label(
                        updated
                            ? String(localized: "\u{201C}\(config.name)\u{201D} was updated.")
                            : String(localized: "\u{201C}\(config.name)\u{201D} was added."),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Text(verbatim: "\(config.preset.displayName) · \(config.bucket)")
                        .foregroundStyle(.secondary)
                }

                if isTesting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ConnectionTestSection(result: testResult, error: testError)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Edit") {
                    // The stored copy: the store may have changed the
                    // default flag on the way in.
                    step = .editing(appState.destinationStore.destinations.first { $0.id == config.id } ?? config)
                }
                Button("Done") { onImported() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
    }
}
