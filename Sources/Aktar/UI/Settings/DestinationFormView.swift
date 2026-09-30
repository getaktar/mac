import SwiftUI

struct DestinationFormView: View {
    var existing: DestinationConfig?
    var onSave: (DestinationConfig, StorageCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var preset: ProviderPreset
    @State private var name: String
    @State private var accountID: String
    @State private var endpoint: String
    @State private var region: String
    @State private var accessKeyId: String = ""
    @State private var secretAccessKey: String = ""
    @State private var bucket: String
    @State private var publicBaseURL: String
    @State private var objectPathTemplate: String
    @State private var testResultMessage: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var expiryRulesActive: Bool
    /// Whether the saved destination had the rules when the form opened.
    private let initialExpiryRulesActive: Bool
    @State private var expiryRulesError: String?
    /// The bucket refused the rules, as opposed to the keys not loading.
    @State private var expiryRulesRefused = false
    @State private var isSettingUpExpiry = false
    /// Set once the rules were checked, set up or turned off here, so saving
    /// records that result instead of guessing from what was edited.
    @State private var checkedExpiryRules = false
    /// The bucket that result is about: the connection fields can still
    /// change afterwards, and a result about another bucket must not be
    /// saved for this one.
    @State private var checkedConnection: Connection?
    @State private var isConfirmingExpiryOff = false
    /// `tmp/{N}d/` folders that already hold files, while confirming set up.
    @State private var prefixesInUse: [String]?
    /// Stays the same for a new destination, so a result recorded before it
    /// was saved still belongs to it.
    @State private var destinationID: UUID

    init(existing: DestinationConfig?, onSave: @escaping (DestinationConfig, StorageCredentials) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _preset = State(initialValue: existing?.preset ?? .cloudflareR2)
        _name = State(initialValue: existing?.name ?? "")
        _accountID = State(initialValue: existing?.accountID ?? "")
        _endpoint = State(initialValue: existing?.endpoint ?? "")
        _region = State(initialValue: existing?.region ?? ProviderPreset.cloudflareR2.defaultRegion)
        _bucket = State(initialValue: existing?.bucket ?? "")
        _publicBaseURL = State(initialValue: existing?.publicBaseURL ?? "")
        _objectPathTemplate = State(initialValue: existing?.objectPathTemplate ?? "{year}/{month}/{uuid}.{ext}")
        _destinationID = State(initialValue: existing?.id ?? UUID())
        initialExpiryRulesActive = existing.map { ExpiryRuleStore.shared.isActive($0.id) } ?? false
        _expiryRulesActive = State(initialValue: initialExpiryRulesActive)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? LocalizedStringKey("Add Destination") : LocalizedStringKey("Edit Destination"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                Section {
                    Picker("Provider", selection: $preset) {
                        ForEach(ProviderPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .onChange(of: preset) { _, newValue in
                        region = newValue.defaultRegion
                        connectionEdited()
                    }

                    TextField("Profile Name", text: $name, prompt: Text("Production Files"))
                }

                Section {
                    if preset == .cloudflareR2 {
                        TextField("Account ID", text: $accountID)
                            .onChange(of: accountID) { _, newValue in
                                endpoint = DestinationConfig.deriveR2Endpoint(accountID: newValue)
                            }
                    } else {
                        TextField("Endpoint", text: $endpoint, prompt: Text("s3.example.com"))
                    }
                    TextField("Region", text: $region)
                } header: {
                    Text("Connection")
                } footer: {
                    if preset == .cloudflareR2 {
                        Text(endpoint.isEmpty ? String(localized: "Endpoint is derived from the Account ID.") : endpoint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Access Key ID", text: $accessKeyId)
                    SecureField(
                        "Secret Access Key",
                        text: $secretAccessKey,
                        prompt: existing != nil ? Text("Unchanged") : nil
                    )
                } header: {
                    Text("Credentials")
                }

                Section {
                    TextField("Bucket", text: $bucket, prompt: Text("screenshots"))
                    TextField("Public Base URL", text: $publicBaseURL, prompt: Text("img.example.com"))
                } header: {
                    Text("Bucket")
                } footer: {
                    Text("The domain files are served from, for example a custom domain or CDN in front of the bucket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Object Path", text: $objectPathTemplate)
                } header: {
                    Text("Object Path")
                } footer: {
                    Text("Variables: {year} {month} {day} {date} {time} {filename} {uuid} {random} {ext}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                autoDeleteSection

                if let testResultMessage {
                    Section {
                        Text(testResultMessage)
                            .font(.caption)
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: endpoint) { connectionEdited() }
            .onChange(of: region) { connectionEdited() }
            .onChange(of: bucket) { connectionEdited() }

            Divider()

            HStack {
                Button(isTesting ? LocalizedStringKey("Testing…") : LocalizedStringKey("Test Connection")) {
                    Task { await testConnection() }
                }
                .disabled(isTesting || !canTest)

                Spacer()

                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 520, height: 580)
    }

    private var autoDeleteSection: some View {
        Section {
            HStack {
                if expiryRulesActive {
                    Label("Active on this bucket", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if expiryRulesError != nil {
                    Label("Not set up", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Not checked yet").foregroundStyle(.secondary)
                }
                Spacer()
                if expiryRulesActive {
                    Button("Turn Off\u{2026}") { isConfirmingExpiryOff = true }
                        .disabled(isSettingUpExpiry)
                }
                Button(expiryRulesActive || expiryRulesError != nil ? LocalizedStringKey("Check Again") : LocalizedStringKey("Set Up")) {
                    Task { await setUpExpiryRules() }
                }
                .disabled(isSettingUpExpiry)
            }
            .alert(
                "Files already in these folders will be deleted",
                isPresented: Binding(get: { prefixesInUse != nil }, set: { if !$0 { prefixesInUse = nil } })
            ) {
                Button("Set Up Anyway", role: .destructive) { Task { await applyExpiryRules() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\((prefixesInUse ?? []).joined(separator: ", ")) already hold files. Once the rules are set up, the bucket deletes them too when they're older than the folder's number of days.")
            }
            .confirmationDialog("Turn off auto-delete for this destination?", isPresented: $isConfirmingExpiryOff) {
                Button("Turn Off") { turnOffExpiry(removingRules: false) }
                Button("Turn Off and Remove Rules", role: .destructive) { turnOffExpiry(removingRules: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\u{201C}Delete after\u{201D} won't be offered for this destination. Files already under tmp/ are still deleted on schedule while the bucket keeps Aktar's rules; removing the rules keeps those files for good.")
            }
            if let expiryRulesError {
                Text(expiryRulesError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expiryRulesRefused {
                Text(Self.refusedExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Auto-Delete")
        } footer: {
            Text("Files uploaded with \u{201C}Delete after\u{201D} go under tmp/ and are deleted by the bucket itself, even when Aktar isn't running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Aktar recognizes the rules by their IDs, so ones added by hand under
    /// other names would leave "Delete after" off.
    static var refusedExplanation: String {
        [
            String(localized: "\u{201C}Delete after\u{201D} stays off until the bucket has Aktar's lifecycle rules. This key can't add them: use a key with admin access to the bucket, or add these rules in your provider's dashboard and check again: tmp/1d/ after 1 day, tmp/7d/ after 7 days, tmp/14d/ after 14 days, tmp/30d/ after 30 days."),
            String(localized: "Name the rules aktar-expire-1d, aktar-expire-7d, aktar-expire-14d, and aktar-expire-30d, or Aktar won't recognize them."),
        ].joined(separator: " ")
    }

    /// The bucket a rules result was obtained for.
    private struct Connection: Equatable {
        let endpoint: String
        let bucket: String
        let region: String

        init(_ config: DestinationConfig) {
            endpoint = config.endpoint.trimmingCharacters(in: .whitespaces)
            bucket = config.bucket.trimmingCharacters(in: .whitespaces)
            region = config.region.trimmingCharacters(in: .whitespaces)
        }
    }

    /// A rules result for the bucket the form pointed at before isn't true
    /// of the one it points at now.
    private func connectionEdited() {
        testResultMessage = nil
        guard checkedExpiryRules || expiryRulesActive || expiryRulesError != nil else { return }
        checkedExpiryRules = false
        checkedConnection = nil
        expiryRulesActive = false
        expiryRulesError = nil
        expiryRulesRefused = false
    }

    /// Entered keys, or the saved ones when editing without retyping them.
    /// Read only when needed, not while drawing, so a Keychain problem shows
    /// up as an error instead of a silently disabled button.
    private func formCredentials() throws -> StorageCredentials {
        if !accessKeyId.isEmpty, !secretAccessKey.isEmpty {
            return StorageCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: nil)
        }
        guard let existing else { throw KeychainError.notFound }
        return try KeychainService.load(for: existing.id)
    }

    private func setUpExpiryRules() async {
        isSettingUpExpiry = true
        defer { isSettingUpExpiry = false }
        // Files already in those folders would start expiring with the
        // rules, so that's confirmed first. A failed check is left to
        // setting up, which reports the same problem with more to go on.
        if let credentials = try? formCredentials(),
           let inUse = try? await S3Provider(config: currentConfig(), credentials: credentials).expiryPrefixesInUse(),
           !inUse.isEmpty {
            prefixesInUse = inUse
            return
        }
        await applyExpiryRules()
    }

    private func applyExpiryRules() async {
        isSettingUpExpiry = true
        defer { isSettingUpExpiry = false }
        let config = currentConfig()
        do {
            let credentials = try formCredentials()
            do {
                try await S3Provider(config: config, credentials: credentials).ensureExpiryRules()
                expiryRulesActive = true
                expiryRulesError = nil
                expiryRulesRefused = false
            } catch {
                expiryRulesActive = false
                expiryRulesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                expiryRulesRefused = true
            }
        } catch {
            expiryRulesActive = false
            expiryRulesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            expiryRulesRefused = false
            return
        }
        checkedExpiryRules = true
        checkedConnection = Connection(config)
        ExpiryRuleStore.shared.set(config.id, active: expiryRulesActive)
    }

    private func turnOffExpiry(removingRules: Bool) {
        Task {
            isSettingUpExpiry = true
            defer { isSettingUpExpiry = false }
            let config = currentConfig()
            if removingRules {
                do {
                    try await S3Provider(config: config, credentials: try formCredentials()).removeExpiryRules()
                } catch {
                    expiryRulesError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    expiryRulesRefused = false
                    return
                }
            }
            expiryRulesActive = false
            expiryRulesError = nil
            expiryRulesRefused = false
            checkedExpiryRules = true
            checkedConnection = Connection(config)
            ExpiryRuleStore.shared.set(config.id, active: false)
            // Files already under tmp/ now stay for good, as the dialog
            // promises, so the sweep has to leave them alone too. Only for
            // the saved bucket: history holds nothing from another one.
            if removingRules, let existing, Connection(existing) == Connection(config) {
                appState.repository.clearExpiry(destinationID: config.id)
            }
        }
    }

    private var canTest: Bool {
        !endpoint.isEmpty && !bucket.isEmpty && !accessKeyId.isEmpty && !secretAccessKey.isEmpty
    }

    private var canSave: Bool {
        !name.isEmpty && !bucket.isEmpty && !endpoint.isEmpty && !publicBaseURL.isEmpty
            && (existing != nil || (!accessKeyId.isEmpty && !secretAccessKey.isEmpty))
    }

    private func currentConfig() -> DestinationConfig {
        DestinationConfig(
            id: destinationID,
            name: name,
            preset: preset,
            accountID: preset == .cloudflareR2 ? accountID : nil,
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            publicBaseURL: publicBaseURL,
            objectPathTemplate: objectPathTemplate,
            forcePathStyle: preset.defaultForcePathStyle,
            isDefault: existing?.isDefault ?? false
        )
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let config = currentConfig()
        let credentials = StorageCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: nil)
        let provider = S3Provider(config: config, credentials: credentials)
        do {
            let result = try await provider.testConnection()
            testSucceeded = result.writable
            var parts: [String] = []
            if result.writable {
                parts.append(String(localized: "✓ Connection successful."))
            }
            parts.append(
                result.writable
                    ? String(localized: "Bucket reachable. Write access: Yes.")
                    : String(localized: "Bucket reachable. Write access: No.")
            )
            if let publicURLReachable = result.publicURLReachable {
                parts.append(
                    publicURLReachable
                        ? String(localized: "Public URL: Reachable.")
                        : String(localized: "⚠ Public URL does not appear to be publicly accessible.")
                )
            }
            testResultMessage = parts.joined(separator: " ")
        } catch {
            testSucceeded = false
            testResultMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        var credentials = StorageCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: nil)
        if let existing, accessKeyId.isEmpty, secretAccessKey.isEmpty,
           let existingCredentials = try? KeychainService.load(for: existing.id) {
            credentials = existingCredentials
        }
        let config = currentConfig()
        if checkedExpiryRules, checkedConnection == Connection(config) {
            ExpiryRuleStore.shared.set(config.id, active: expiryRulesActive)
        } else if let existing, Connection(existing) == Connection(config), accessKeyId.isEmpty {
            // The saved bucket and key, back to what they were before any
            // check here that was about another bucket.
            ExpiryRuleStore.shared.set(config.id, active: initialExpiryRulesActive)
        } else {
            // A different bucket or key hasn't been checked for the rules.
            ExpiryRuleStore.shared.set(config.id, active: false)
        }
        onSave(config, credentials)
    }
}
