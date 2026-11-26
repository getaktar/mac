import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Import from ShareX" (docs/sharex-import.md): what ShareX's settings
/// hold, for review. Secret keys ShareX encrypted for Windows are typed in
/// here; nothing runs that the user didn't set (ShareX has no hooks or "Use
/// for"). Saved destinations are tested right away, as the QR import does.
struct ShareXImportView: View {
    let result: ShareXConfigImport.Result
    var onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var rows: [Row] = []
    @State private var step = Step.review
    @State private var isWorking = false
    /// Shorteners waiting for their consent screen, and where they go.
    @State private var pendingShortener: PendingShortener?
    @State private var attached: [UUID: String] = [:]

    private enum Step { case review, imported }

    struct Row: Identifiable {
        var found: ShareXConfigImport.Destination
        var include: Bool
        var secret = ""
        var duplicate: Bool
        var error: String?
        var savedID: UUID?
        var test: ConnectionResult?
        var testError: String?
        var isTesting = false
        var id: UUID { found.id }
    }

    private struct PendingShortener: Identifiable {
        let shortener: ShareXConfigImport.Shortener
        let destination: DestinationConfig
        var id: UUID { shortener.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Import from ShareX")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()
            Form {
                switch step {
                case .review: reviewSections
                case .imported: importedSections
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                switch step {
                case .review:
                    Button("Cancel") { onDone() }
                    Button("Import") { Task { await importSelected() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWorking || !rows.contains { $0.include })
                case .imported:
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: makeRows)
        .sheet(item: $pendingShortener) { pending in
            ShareXConsentView(imported: pending.shortener.imported) {
                attach(pending)
                pendingShortener = nil
            } cancel: {
                pendingShortener = nil
            }
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewSections: some View {
        if rows.isEmpty {
            Section {
                Text("No Amazon S3 or Backblaze B2 uploader was found in these settings.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach($rows) { $row in
            Section {
                Toggle(isOn: $row.include) {
                    Text(verbatim: row.found.name).fontWeight(.semibold)
                }
                .disabled(row.duplicate)
                if row.duplicate {
                    Text("Already in Aktar").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Provider", value: row.found.preset.displayName)
                LabeledContent("Bucket", value: row.found.bucket)
                if row.found.kind == .b2, row.found.endpoint.isEmpty {
                    TextField("Endpoint", text: $row.found.endpoint, prompt: Text(verbatim: "https://s3.us-west-004.backblazeb2.com"))
                    Text("Left empty, Aktar asks Backblaze for it with the key below.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Endpoint", value: row.found.endpoint)
                }
                TextField("Public Base URL", text: $row.found.publicBaseURL, prompt: Text(row.found.kind == .b2 ? "Found with the key" : "img.example.com"))
                LabeledContent("Object Path", value: row.found.objectPathTemplate)
                if row.found.secretKey == nil {
                    SecureField(row.found.kind == .b2 ? "Application Key" : "Secret Access Key", text: $row.secret)
                    if row.found.secretIsEncrypted {
                        Text("ShareX encrypted this key for Windows. Paste it from your provider, or import on the Windows PC and use Share to Another Device.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(row.found.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = row.error {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !result.shorteners.isEmpty {
            Section {
                ForEach(result.shorteners) { shortener in
                    LabeledContent(shortener.name, value: shortener.imported.host)
                }
            } header: {
                Text("URL Shorteners")
            } footer: {
                Text("After importing, add each one to a destination. You\u{2019}ll see where it sends your links first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !result.skipped.isEmpty {
            Section("Not Imported") {
                ForEach(result.skipped) { item in
                    LabeledContent(item.name) {
                        Text(item.reason).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    // MARK: - Imported

    @ViewBuilder
    private var importedSections: some View {
        ForEach(rows.filter { $0.savedID != nil }) { row in
            Section {
                Label(String(localized: "\u{201C}\(row.found.name)\u{201D} was added."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if row.isTesting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Testing\u{2026}").foregroundStyle(.secondary)
                    }
                } else if let error = row.testError {
                    Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                } else if let test = row.test {
                    Label(
                        test.writable ? String(localized: "Uploads work") : String(localized: "This key can\u{2019}t upload files"),
                        systemImage: test.writable ? "checkmark.circle" : "xmark.circle.fill"
                    )
                    .foregroundStyle(test.writable ? Color.secondary : Color.red)
                }
            }
        }
        if !result.shorteners.isEmpty {
            Section("URL Shorteners") {
                ForEach(result.shorteners) { shortener in
                    HStack {
                        Text(verbatim: shortener.name)
                        Spacer()
                        if let name = attached[shortener.id] {
                            Text(verbatim: name).foregroundStyle(.secondary)
                        } else {
                            Menu("Add to\u{2026}") {
                                ForEach(appState.destinationStore.destinations) { destination in
                                    Button(destination.name) { pendingShortener = PendingShortener(shortener: shortener, destination: destination) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func makeRows() {
        guard rows.isEmpty else { return }
        rows = result.destinations.map { found in
            let duplicate = appState.destinationStore.destinations.contains { existing in
                guard existing.bucket == found.bucket,
                      found.endpoint.isEmpty || DestinationTransfer.uploadsToSamePlace(found.config(), as: existing) else { return false }
                return (try? KeychainService.load(for: existing.id).accessKeyId) == found.accessKeyID
            }
            return Row(found: found, include: !duplicate, duplicate: duplicate)
        }
    }

    private func importSelected() async {
        isWorking = true
        defer { isWorking = false }
        // Everything is checked first, so nothing is saved halfway.
        for index in rows.indices where rows[index].include {
            rows[index].error = nil
            let secret = rows[index].found.secretKey ?? rows[index].secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else {
                rows[index].error = String(localized: "Enter the secret key.")
                continue
            }
            rows[index].found.secretKey = secret
            if rows[index].found.kind == .b2, rows[index].found.endpoint.isEmpty {
                do {
                    rows[index].found = try await ShareXConfigImport.authorizeB2(rows[index].found)
                } catch {
                    rows[index].error = String(localized: "Backblaze didn\u{2019}t accept this key, so the endpoint couldn\u{2019}t be found. Check the key, or enter the endpoint.")
                    continue
                }
            }
            if rows[index].found.endpoint.isEmpty {
                rows[index].error = String(localized: "Enter the endpoint.")
            } else if !PublicURLResolver.isValidBaseURL(rows[index].found.publicBaseURL) {
                rows[index].error = String(localized: "Enter a web address, such as img.example.com or https://img.example.com.")
            }
        }
        guard !rows.contains(where: { $0.include && $0.error != nil }) else { return }

        let store = appState.destinationStore
        for index in rows.indices where rows[index].include {
            let config = rows[index].found.config()
            let credentials = StorageCredentials(accessKeyId: rows[index].found.accessKeyID, secretAccessKey: rows[index].found.secretKey ?? "", sessionToken: nil)
            try? KeychainService.save(credentials, for: config.id)
            ExpiryRuleStore.shared.set(config.id, active: false)
            // The first one becomes the default only when there was none.
            store.add(config)
            rows[index].savedID = config.id
            rows[index].isTesting = true
        }
        step = .imported
        for index in rows.indices where rows[index].savedID != nil {
            guard let id = rows[index].savedID, let saved = store.destinations.first(where: { $0.id == id }),
                  let credentials = try? KeychainService.load(for: id) else { continue }
            do {
                rows[index].test = try await StorageBackends.make(config: saved, credentials: credentials).testConnection()
            } catch {
                rows[index].testError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            rows[index].isTesting = false
        }
    }

    /// The shortener the user agreed to, as that destination's Short Links.
    private func attach(_ pending: PendingShortener) {
        var state = ShortLinkFormState(nil)
        state.apply(pending.shortener.imported)
        guard let settings = state.settings(), var credentials = try? KeychainService.load(for: pending.destination.id) else { return }
        var destination = pending.destination
        destination.shortLinks = settings
        credentials.shortLinkToken = state.token.isEmpty ? nil : state.token
        try? KeychainService.save(credentials, for: destination.id)
        appState.destinationStore.update(destination)
        attached[pending.shortener.id] = destination.name
    }

    /// The file picker: UploadersConfig.json or a .sxb backup.
    static func chooseFile() -> Result<ShareXConfigImport.Result, Error>? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "sxb")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose ShareX\u{2019}s UploadersConfig.json (in Documents\\ShareX on the Windows PC) or a ShareX backup (.sxb).")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Result { try ShareXConfigImport.read(fileAt: url) }
    }
}
