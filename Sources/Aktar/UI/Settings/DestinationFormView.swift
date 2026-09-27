import SwiftUI

struct DestinationFormView: View {
    var existing: DestinationConfig?
    var onSave: (DestinationConfig, StorageCredentials) -> Void

    @Environment(\.dismiss) private var dismiss

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
                        testResultMessage = nil
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

                if let testResultMessage {
                    Section {
                        Text(testResultMessage)
                            .font(.caption)
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)

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

    private var canTest: Bool {
        !endpoint.isEmpty && !bucket.isEmpty && !accessKeyId.isEmpty && !secretAccessKey.isEmpty
    }

    private var canSave: Bool {
        !name.isEmpty && !bucket.isEmpty && !endpoint.isEmpty && !publicBaseURL.isEmpty
            && (existing != nil || (!accessKeyId.isEmpty && !secretAccessKey.isEmpty))
    }

    private func currentConfig() -> DestinationConfig {
        DestinationConfig(
            id: existing?.id ?? UUID(),
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
        onSave(currentConfig(), credentials)
    }
}
