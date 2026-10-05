import AppKit
import SwiftUI

/// "Set Up Cloudflare R2": opens Cloudflare's token page with the
/// permissions filled in, takes the token, and does the rest (bucket,
/// public link, keys), then saves the destination and tests it like an
/// imported one. See `CloudflareSetup`.
struct CloudflareSetupView: View {
    /// Done, or the destination saved again from Edit.
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private enum Step {
        case token
        case options
        case working
        case saved(DestinationConfig)
        case editing(DestinationConfig)
    }

    private enum BucketChoice: Hashable {
        case new
        case existing(String)
    }

    private enum PublicLink: Hashable {
        case devURL
        case domain
    }

    /// What the setup does once it runs, in order.
    private enum Stage: CaseIterable {
        case bucket, publicLink, save

        var title: LocalizedStringKey {
            switch self {
            case .bucket: return "Create the bucket"
            case .publicLink: return "Turn on public links"
            case .save: return "Save and test the destination"
            }
        }
    }

    private enum StageState: Equatable {
        case waiting, running, done, failed
    }

    @State private var step = Step.token
    @State private var token = ""
    @State private var tokenID = ""
    @State private var tokenError: String?
    @State private var isChecking = false

    @State private var accounts: [CloudflareSetup.Account] = []
    @State private var accountID = ""
    @State private var buckets: [String] = []
    @State private var zones: [CloudflareSetup.Zone] = []
    @State private var isLoadingAccount = false
    @State private var accountError: String?

    @State private var bucketChoice = BucketChoice.new
    @State private var newBucket = "aktar"
    @State private var publicLink = PublicLink.devURL
    @State private var zoneID = ""
    @State private var subdomain = "files"
    @State private var name = "Cloudflare R2"

    @State private var progress: [Stage: StageState] = [:]
    @State private var setupError: String?
    @State private var testResult: ConnectionResult?
    @State private var testError: String?
    @State private var isTesting = false

    var body: some View {
        switch step {
        case .token:
            page(continueTitle: "Continue", canContinue: !trimmedToken.isEmpty && !isChecking, busy: isChecking, action: checkToken) {
                tokenForm
            }
        case .options:
            page(continueTitle: "Set Up", canContinue: canSetUp, busy: isLoadingAccount, back: { step = .token }, action: runSetup) {
                optionsForm
            }
        case .working:
            page(continueTitle: "Set Up", canContinue: false, busy: setupError == nil, back: setupError == nil ? nil : { step = .options }, action: {}) {
                workingForm
            }
        case .saved(let config):
            savedResult(config)
        case .editing(let config):
            DestinationFormView(existing: config) { config, credentials in
                appState.destinationStore.update(config)
                try? KeychainService.save(credentials, for: config.id)
                onFinished()
            }
        }
    }

    // MARK: - Token

    private var trimmedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var tokenForm: some View {
        Section {
            Text("Aktar creates the bucket, turns on public links and saves the destination for you. It only needs an API token from your Cloudflare account.")
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    NSWorkspace.shared.open(CloudflareSetup.tokenURL)
                } label: {
                    Label("Open Cloudflare", systemImage: "arrow.up.right.square")
                }
                Text("The permissions are already filled in (R2 Storage: Edit, Zone: Read). Scroll down, select Continue to summary, then Create Token, and copy the token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("1. Create a token")
        }

        Section {
            SecureField("API Token", text: $token, prompt: Text("Paste the token here"))
                .onChange(of: token) { tokenError = nil }
                .onSubmit(checkToken)
            if let tokenError {
                Label(tokenError, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("2. Paste it")
        } footer: {
            Text("The token isn\u{2019}t stored. Aktar keeps only the storage keys made from it, in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func checkToken() {
        guard !trimmedToken.isEmpty, !isChecking else { return }
        isChecking = true
        tokenError = nil
        let token = trimmedToken
        Task {
            defer { isChecking = false }
            do {
                tokenID = try await CloudflareSetup.verify(token: token)
                let found = try await CloudflareSetup.accounts(token: token)
                guard let first = found.first else {
                    tokenError = String(localized: "This token can\u{2019}t see any Cloudflare account. Create it with the button above, for all accounts.")
                    return
                }
                accounts = found
                step = .options
                await selectAccount(found.contains { $0.id == accountID } ? accountID : first.id)
            } catch {
                tokenError = message(for: error)
            }
        }
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsForm: some View {
        if accounts.count > 1 {
            Section {
                Picker("Account", selection: Binding(get: { accountID }, set: { id in Task { await selectAccount(id) } })) {
                    ForEach(accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
            }
        }

        if let accountError {
            Section {
                Label(accountError, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }

        Section {
            Picker("Bucket", selection: $bucketChoice) {
                Text("New Bucket").tag(BucketChoice.new)
                if !buckets.isEmpty {
                    Divider()
                    ForEach(buckets, id: \.self) { bucket in
                        Text(verbatim: bucket).tag(BucketChoice.existing(bucket))
                    }
                }
            }
            if bucketChoice == .new {
                TextField("Name", text: $newBucket, prompt: Text(verbatim: "aktar"))
                if let bucketProblem {
                    Label(bucketProblem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Bucket")
        }

        Section {
            Picker("Public Links", selection: $publicLink) {
                Text("r2.dev Address").tag(PublicLink.devURL)
                Text("My Domain").tag(PublicLink.domain)
            }
            .pickerStyle(.radioGroup)
            if publicLink == .domain {
                if zones.isEmpty {
                    Text("No domain on this Cloudflare account. Add one to Cloudflare first, or use the r2.dev address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Domain", selection: $zoneID) {
                        ForEach(zones) { zone in
                            Text(verbatim: zone.name).tag(zone.id)
                        }
                    }
                    TextField("Subdomain", text: $subdomain, prompt: Text(verbatim: "files"))
                    if let domain = customDomain {
                        Text("Links will look like https://\(domain)/2026/10/photo.jpg")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Public Links")
        } footer: {
            Text(publicLink == .devURL
                ? LocalizedStringKey("Works right away. Cloudflare rate-limits r2.dev addresses, so a domain of your own is better for links you share widely.")
                : LocalizedStringKey("Cloudflare adds the DNS record and certificate. It can take a few minutes before links work."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            TextField("Destination Name", text: $name)
        }
    }

    private func selectAccount(_ id: String) async {
        accountID = id
        isLoadingAccount = true
        accountError = nil
        defer { isLoadingAccount = false }
        let token = trimmedToken
        do {
            async let foundBuckets = CloudflareSetup.buckets(account: id, token: token)
            async let foundZones = CloudflareSetup.zones(account: id, token: token)
            buckets = try await foundBuckets
            zones = (try? await foundZones) ?? []
            zoneID = zones.first?.id ?? ""
            if case .existing(let bucket) = bucketChoice, !buckets.contains(bucket) {
                bucketChoice = .new
            }
            newBucket = suggestedBucketName()
        } catch {
            buckets = []
            zones = []
            accountError = message(for: error)
        }
    }

    /// "aktar", or "aktar-2" and on when that's taken.
    private func suggestedBucketName() -> String {
        if !buckets.contains("aktar") { return "aktar" }
        var number = 2
        while buckets.contains("aktar-\(number)") { number += 1 }
        return "aktar-\(number)"
    }

    private var bucketName: String {
        switch bucketChoice {
        case .new: return newBucket.trimmingCharacters(in: .whitespaces)
        case .existing(let bucket): return bucket
        }
    }

    private var bucketProblem: String? {
        let name = bucketName
        guard !name.isEmpty else { return nil }
        if buckets.contains(name) {
            return String(localized: "A bucket with this name already exists. Pick it from the list above to use it.")
        }
        if !CloudflareSetup.isValidBucketName(name) {
            return String(localized: "Use 3 to 63 lowercase letters, numbers and hyphens, starting and ending with a letter or number.")
        }
        return nil
    }

    private var selectedZone: CloudflareSetup.Zone? {
        zones.first { $0.id == zoneID }
    }

    /// The full host name for the public links, when it's valid.
    private var customDomain: String? {
        guard let zone = selectedZone else { return nil }
        let label = subdomain.trimmingCharacters(in: .whitespaces).lowercased()
        let domain = label.isEmpty ? zone.name : "\(label).\(zone.name)"
        return CloudflareSetup.isValidDomain(domain, in: zone) ? domain : nil
    }

    private var canSetUp: Bool {
        guard !accountID.isEmpty, !isLoadingAccount, accountError == nil else { return false }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !bucketName.isEmpty, bucketProblem == nil else { return false }
        return publicLink == .devURL || customDomain != nil
    }

    // MARK: - Setup

    private var workingForm: some View {
        Section {
            ForEach(Stage.allCases, id: \.self) { task in
                HStack(spacing: 8) {
                    switch progress[task] ?? .waiting {
                    case .waiting:
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    case .running:
                        ProgressView().controlSize(.small)
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    Text(task.title)
                }
            }
            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runSetup() {
        guard canSetUp else { return }
        step = .working
        setupError = nil
        progress = [:]
        let token = trimmedToken
        let account = accountID
        let bucket = bucketName
        let isNew = bucketChoice == .new
        let link = publicLink
        let zone = selectedZone
        let domain = customDomain
        Task {
            var current = Stage.bucket
            do {
                progress[.bucket] = .running
                if isNew {
                    try await CloudflareSetup.createBucket(bucket, account: account, token: token)
                    buckets.append(bucket)
                    bucketChoice = .existing(bucket)
                }
                progress[.bucket] = .done

                current = .publicLink
                progress[.publicLink] = .running
                let baseURL: String
                if link == .domain, let zone, let domain {
                    let connected = try await CloudflareSetup.customDomains(bucket: bucket, account: account, token: token)
                    if !connected.contains(domain) {
                        try await CloudflareSetup.attachDomain(domain, zone: zone, bucket: bucket, account: account, token: token)
                    }
                    baseURL = "https://\(domain)"
                } else {
                    baseURL = try await CloudflareSetup.enablePublicDevURL(bucket: bucket, account: account, token: token)
                }
                progress[.publicLink] = .done

                current = .save
                progress[.save] = .running
                save(account: account, bucket: bucket, baseURL: baseURL, credentials: CloudflareSetup.credentials(tokenID: tokenID, token: token))
            } catch {
                progress[current] = .failed
                setupError = message(for: error)
            }
        }
    }

    private func save(account: String, bucket: String, baseURL: String, credentials: StorageCredentials) {
        let config = DestinationConfig(
            name: name.trimmingCharacters(in: .whitespaces),
            preset: .cloudflareR2,
            accountID: account,
            endpoint: DestinationConfig.deriveR2Endpoint(accountID: account),
            region: ProviderPreset.cloudflareR2.defaultRegion,
            bucket: bucket,
            publicBaseURL: baseURL,
            objectPathTemplate: "{year}/{month}/{uuid}.{ext}",
            forcePathStyle: ProviderPreset.cloudflareR2.defaultForcePathStyle,
            isDefault: false
        )
        try? KeychainService.save(credentials, for: config.id)
        // A new destination hasn't been checked for the auto-delete rules.
        ExpiryRuleStore.shared.set(config.id, active: false)
        // `add` makes it the default when it's the first one here.
        appState.destinationStore.add(config)
        // The token was just made and its permissions may take a moment to
        // reach R2, so the first test waits briefly.
        isTesting = true
        step = .saved(config)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await testConnection(config, credentials: credentials)
        }
    }

    private func testConnection(_ config: DestinationConfig, credentials: StorageCredentials) async {
        isTesting = true
        defer { isTesting = false }
        do {
            testResult = try await S3Provider(config: config, credentials: credentials).testConnection()
            testError = nil
        } catch {
            testResult = nil
            testError = message(for: error)
        }
    }

    private func savedResult(_ config: DestinationConfig) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    Label(String(localized: "\u{201C}\(config.name)\u{201D} was added."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(verbatim: "\(config.preset.displayName) · \(config.bucket) · \(config.publicBaseURL)")
                        .foregroundStyle(.secondary)
                }
                if isTesting {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Testing\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ConnectionTestSection(result: testResult, error: testError)
                    if !config.publicBaseURL.hasSuffix(".r2.dev") {
                        Section {
                            Text("If the public link check failed, the domain is probably still being set up. Try Test Connection again in a few minutes from Edit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Edit") {
                    step = .editing(appState.destinationStore.destinations.first { $0.id == config.id } ?? config)
                }
                Button("Done") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 600)
    }

    // MARK: - Layout

    private var header: some View {
        Text("Set Up Cloudflare R2")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
    }

    private func page<Content: View>(
        continueTitle: LocalizedStringKey,
        canContinue: Bool,
        busy: Bool,
        back: (() -> Void)? = nil,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form { content() }
                .formStyle(.grouped)
            Divider()
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let back {
                    Button("Back", action: back)
                }
                Button("Cancel") { dismiss() }
                Button(continueTitle, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding()
        }
        .frame(width: 480, height: 600)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
