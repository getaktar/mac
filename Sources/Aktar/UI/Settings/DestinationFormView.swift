import KeyboardShortcuts
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
    /// Nil follows Settings > Output.
    @State private var outputMode: OutputMode?
    @State private var expiryDays: Int
    @State private var temporaryLink: TemporaryLinkDuration?
    @State private var imageMetadata: ImageMetadataPolicy
    @State private var folderUpload: FolderUploadMode
    @State private var imageFormat: ImageProcessing.Format
    @State private var imageQuality: Int?
    @State private var imageMaxLongEdge: Int?
    @State private var thumbnailMode: ThumbnailMode
    @State private var useForKinds: Set<FileRouting.Kind>
    @State private var useForExtensions: String
    @State private var shortCache: Bool
    @State private var cloudflareZoneId: String
    /// A token typed here; empty keeps the saved one.
    @State private var cloudflareToken = ""
    private let hasSavedCloudflareToken: Bool
    @State private var purgeCheck: PurgeCheck?
    @State private var hooks: [WatchHook]

    private enum PurgeCheck: Equatable {
        case checking
        case passed
        case failed(String)
    }
    @State private var thumbnailPrefix: String
    /// Saving stopped to ask what happens to the thumbnails already in
    /// the bucket's old thumbnail folder.
    @State private var isConfirmingThumbnailCleanup = false
    @State private var testResult: ConnectionResult?
    /// Why the test couldn't reach the bucket at all.
    @State private var testError: String?
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
        _outputMode = State(initialValue: existing?.outputMode)
        _temporaryLink = State(initialValue: existing?.temporaryLink)
        _imageMetadata = State(initialValue: existing?.imageMetadata ?? .default)
        _folderUpload = State(initialValue: existing?.folderUpload ?? .default)
        _imageFormat = State(initialValue: existing?.imageProcessing?.format ?? .original)
        _imageQuality = State(initialValue: existing?.imageProcessing?.quality)
        _imageMaxLongEdge = State(initialValue: existing?.imageProcessing?.maxLongEdge)
        _thumbnailMode = State(initialValue: existing?.thumbnailMode ?? .default)
        _useForKinds = State(initialValue: Set(existing?.useFor?.kinds ?? []))
        _useForExtensions = State(initialValue: (existing?.useFor?.extensions ?? []).joined(separator: ", "))
        _shortCache = State(initialValue: existing?.shortCache ?? false)
        _cloudflareZoneId = State(initialValue: existing?.cloudflareZoneId ?? "")
        _hooks = State(initialValue: existing?.hooks ?? [])
        hasSavedCloudflareToken = existing.flatMap { try? KeychainService.load(for: $0.id).cloudflareToken }.map { !$0.isEmpty } ?? false
        _thumbnailPrefix = State(initialValue: ThumbnailKeys.normalizedPrefix(existing?.thumbnailPrefix) ?? ThumbnailKeys.defaultPrefix)
        _expiryDays = State(initialValue: existing?.expiryDays ?? UserDefaults.standard.integer(forKey: UploadExpiry.defaultsKey))
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
                    // Saved keys stay in the Keychain and aren't shown;
                    // leaving both fields empty keeps them.
                    TextField("Access Key ID", text: $accessKeyId, prompt: existing != nil ? Text("Unchanged") : nil)
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
                    VStack(alignment: .leading, spacing: 4) {
                        if isPublicBaseURLInvalid {
                            Text("Enter a web address, such as img.example.com or https://img.example.com.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Text("The domain files are served from, for example a custom domain or CDN in front of the bucket.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Object Path", text: $objectPathTemplate)
                } header: {
                    Text("Object Path")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Variables: {year} {month} {day} {date} {time} {filename} {uuid} {random} {ext} {md5} {sha256} {folder} {subpath}")
                        Text(verbatim: "{md5}: ") + Text("MD5 of the file's contents")
                        Text(verbatim: "{sha256}: ") + Text("SHA-256 of the file's contents")
                        Text(verbatim: "{folder} {subpath}: ") + Text("the watched folder\u{2019}s name and the subfolders a file is in, for uploads from Watched Folders")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                autoDeleteSection

                uploadDefaultsSection

                useForSection

                shortcutSection

                imageProcessingSection

                thumbnailsSection

                replacingSection

                afterUploadSection

                ConnectionTestSection(result: testResult, error: testError)
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

                Button("Cancel") {
                    // A shortcut recorded for a destination that's never saved.
                    if existing == nil { KeyboardShortcuts.reset(.uploadToDestination(destinationID)) }
                    dismiss()
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 520, height: 580)
    }

    /// What makes a destination an upload profile: pick it in the menu bar
    /// and its uploads are copied and expire the way it says.
    private var uploadDefaultsSection: some View {
        Section {
            Picker("Copy as", selection: $outputMode) {
                Text("Same as Settings").tag(OutputMode?.none)
                ForEach(OutputMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.displayName)).tag(OutputMode?.some(mode))
                }
            }
            Picker("Link", selection: $temporaryLink) {
                Text(TemporaryLinkDuration.label(nil)).tag(TemporaryLinkDuration?.none)
                ForEach(TemporaryLinkDuration.allCases) { duration in
                    Text(TemporaryLinkDuration.label(duration)).tag(TemporaryLinkDuration?.some(duration))
                }
            }
            Picker("Delete after", selection: $expiryDays) {
                ForEach([0] + UploadExpiry.options, id: \.self) { days in
                    Text(UploadExpiry.label(days: days)).tag(days)
                }
            }
            .disabled(!expiryRulesActive)
            Picker("Image metadata", selection: $imageMetadata) {
                ForEach(ImageMetadataPolicy.allCases) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            Picker("Folders", selection: $folderUpload) {
                ForEach(FolderUploadMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } header: {
            Text("Upload Defaults")
        } footer: {
            Text("Applied whenever this destination is picked. Add one destination per kind of file, such as Builds, Logs or Screenshots, each with its own path and defaults. A temporary link stops working after the time you pick and works for private buckets too. Image metadata applies to photos and videos: Remove location drops the GPS position, Remove all also drops the camera, date and other details. A folder is uploaded as one ZIP file, or file by file with its subfolders.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The file types an upload that doesn't name a destination sends here.
    private var useForSection: some View {
        Section {
            HStack(spacing: 14) {
                ForEach(FileRouting.Kind.allCases) { kind in
                    Toggle(kind.label, isOn: Binding(
                        get: { useForKinds.contains(kind) },
                        set: { isOn in
                            if isOn { useForKinds.insert(kind) } else { useForKinds.remove(kind) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            TextField("Extensions", text: $useForExtensions, prompt: Text(verbatim: "dmg, zip"))
            if let problem = useForProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Use For")
        } footer: {
            Text("When an upload doesn\u{2019}t name a destination (the clipboard shortcut, the menu bar, Finder, Shortcuts, the local API), files of these types come here instead of the default destination. An extension listed here wins over a type.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var useForProblem: String? {
        let invalid = FileRouting.parseExtensions(useForExtensions).invalid
        guard !invalid.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: invalid.map { "\u{201C}\($0)\u{201D}" })
        return String(localized: "Not an extension: \(list). Use letters and digits only, such as dmg or mp4.")
    }

    private var currentUseFor: FileRouting? {
        let routing = FileRouting(
            kinds: FileRouting.orderedKinds(Array(useForKinds)),
            extensions: FileRouting.parseExtensions(useForExtensions).extensions
        )
        return routing.isEmpty ? nil : routing
    }

    private var shortcutSection: some View {
        Section {
            KeyboardShortcuts.Recorder("Upload clipboard here", name: .uploadToDestination(destinationID))
        } header: {
            Text("Keyboard Shortcut")
        } footer: {
            Text("Uploads what\u{2019}s on the clipboard to this destination, whatever \u{201C}Use for\u{201D} says. Kept on this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What helps a file replaced at its key (Replace File, or a watched
    /// folder keeping the link) show up right away.
    private var replacingSection: some View {
        Section {
            Toggle("Short cache time", isOn: $shortCache)
            TextField("Cloudflare Zone ID", text: $cloudflareZoneId, prompt: Text("Optional"))
            HStack {
                SecureField(
                    "Cloudflare API Token",
                    text: $cloudflareToken,
                    prompt: hasSavedCloudflareToken ? Text("Unchanged") : Text("Optional")
                )
                Button("Check") { checkCloudflareToken() }
                    .disabled(purgeCheck == .checking || (cloudflareToken.isEmpty && !hasSavedCloudflareToken))
            }
            switch purgeCheck {
            case .checking:
                Text("Checking\u{2026}").font(.caption).foregroundStyle(.secondary)
            case .passed:
                Label("Cloudflare accepts this token", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Replacing Files")
        } footer: {
            Text("Replace File writes a new file at the same key, so its link keeps working. Short cache time sends every upload here with a one-minute cache time, so a replaced file shows up everywhere within about a minute. With a Cloudflare zone ID and an API token that can purge its cache (Zone > Cache Purge), Aktar clears the old version from Cloudflare right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func checkCloudflareToken() {
        let typed = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty ? existing.flatMap { try? KeychainService.load(for: $0.id).cloudflareToken } : typed
        guard let token, !token.isEmpty else { return }
        purgeCheck = .checking
        Task {
            do {
                try await CloudflarePurge.verify(token: token)
                purgeCheck = .passed
            } catch {
                purgeCheck = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private var afterUploadSection: some View {
        Section {
            HookListEditor(hooks: $hooks) { hook in
                try await DestinationHooks.test(hook, destination: currentConfig())
            }
        } header: {
            Text("After Upload")
        } footer: {
            Text("Runs after each upload to this destination and each replace, except a watched folder\u{2019}s files, which run their folder\u{2019}s own Automation. A webhook gets the upload as JSON. A script gets the same JSON on standard input, with the link, the key, the file and the destination as its arguments; put scripts in Aktar\u{2019}s scripts folder (~/Library/Application Scripts/com.getaktar.mac) to pick them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Conversion, recompression and resizing of photos, next to what
    /// happens to their metadata.
    private var imageProcessingSection: some View {
        Section {
            Picker("Format", selection: $imageFormat) {
                ForEach(ImageProcessing.Format.allCases) { format in
                    if format == .avif, !ImageProcessor.canEncodeAVIF {
                        Text(verbatim: "\(format.label) (\(String(localized: "Needs a newer macOS")))")
                            .tag(format)
                            .selectionDisabled()
                    } else {
                        Text(format.label).tag(format)
                    }
                }
            }
            Picker("Compression", selection: $imageQuality) {
                Text(ImageProcessing.qualityLabel(nil)).tag(Int?.none)
                ForEach(ImageProcessing.qualityOptions, id: \.self) { quality in
                    Text(ImageProcessing.qualityLabel(quality)).tag(Int?.some(quality))
                }
            }
            Picker("Resize", selection: $imageMaxLongEdge) {
                Text(ImageProcessing.sizeLabel(nil)).tag(Int?.none)
                ForEach(ImageProcessing.sizeOptions, id: \.self) { size in
                    Text(ImageProcessing.sizeLabel(size)).tag(Int?.some(size))
                }
            }
        } header: {
            Text("Image Processing")
        } footer: {
            Text("Applies to JPEG, PNG, HEIC, WebP, TIFF and BMP photos and screenshots. GIFs, SVGs and files inside ZIPs are left as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var thumbnailsSection: some View {
        Section {
            Picker("Thumbnails", selection: $thumbnailMode) {
                ForEach(ThumbnailMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if thumbnailMode == .bucket {
                TextField("Folder", text: $thumbnailPrefix, prompt: Text(verbatim: ThumbnailKeys.defaultPrefix))
                if let problem = thumbnailPrefixProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Thumbnails")
        } footer: {
            Group {
                switch thumbnailMode {
                case .off:
                    Text("No thumbnails are made or downloaded for this destination. History and the bucket view show file icons.")
                case .local:
                    Text("Thumbnails of photos, videos, PDFs and documents are made on this Mac and kept only here. Files already in the bucket get one when they\u{2019}re shown, if they\u{2019}re under 25 MB.")
                case .bucket:
                    Text("Thumbnails are also saved in your bucket, in this folder, so your other devices can show them. Each one is deleted, moved or expires along with its file. Use a folder only for thumbnails: it\u{2019}s hidden in the bucket view.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Delete the thumbnails already in the bucket?",
            isPresented: $isConfirmingThumbnailCleanup
        ) {
            Button("Delete Thumbnails", role: .destructive) { save(thumbnailCleanup: .delete) }
            Button("Keep Them") { save(thumbnailCleanup: .keep) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Thumbnails saved in \(oldThumbnailPrefix ?? "") stay in the bucket unless you delete them. Your files aren\u{2019}t affected.")
        }
    }

    private var thumbnailPrefixProblem: String? {
        thumbnailMode == .bucket ? ThumbnailKeys.problem(withPrefix: thumbnailPrefix) : nil
    }

    /// The bucket folder the saved destination keeps thumbnails in, when
    /// saving would stop using it (thumbnails moved off the bucket, to
    /// another folder, or to another bucket), and no other destination on
    /// that bucket still uses it.
    private var oldThumbnailPrefix: String? {
        guard let existing, let old = existing.bucketThumbnailPrefix else { return nil }
        let config = currentConfig()
        if config.bucketThumbnailPrefix == old, Connection(existing) == Connection(config) { return nil }
        let othersUseIt = appState.destinationStore.destinations.contains {
            $0.id != existing.id && DestinationTransfer.uploadsToSamePlace($0, as: existing) && $0.bucketThumbnailPrefix == old
        }
        return othersUseIt ? nil : old
    }

    private enum ThumbnailCleanup {
        case ask, delete, keep
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
    struct Connection: Equatable {
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
        testResult = nil
        testError = nil
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

    /// Typed but not an http(s) address with a host (and a valid port).
    private var isPublicBaseURLInvalid: Bool {
        !publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !PublicURLResolver.isValidBaseURL(publicBaseURL)
    }

    private var canSave: Bool {
        !name.isEmpty && !bucket.isEmpty && !endpoint.isEmpty && !publicBaseURL.isEmpty && !isPublicBaseURLInvalid
            && thumbnailPrefixProblem == nil && useForProblem == nil && !HookListEditor.hasUnusableWebhook(hooks)
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
            forcePathStyle: forcePathStyle,
            isDefault: existing?.isDefault ?? false,
            outputMode: outputMode,
            expiryDays: expiryDays,
            temporaryLink: temporaryLink,
            imageMetadata: imageMetadata,
            folderUpload: folderUpload,
            imageProcessing: currentImageProcessing,
            thumbnails: thumbnailMode,
            thumbnailPrefix: currentThumbnailPrefix,
            useFor: currentUseFor,
            shortCache: shortCache ? true : nil,
            cloudflareZoneId: cloudflareZoneId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : cloudflareZoneId.trimmingCharacters(in: .whitespacesAndNewlines),
            hooks: hooks.isEmpty ? nil : hooks
        )
    }

    /// Kept while thumbnails aren't in the bucket, so switching back finds
    /// the same folder; nil for the default one.
    private var currentThumbnailPrefix: String? {
        guard ThumbnailKeys.problem(withPrefix: thumbnailPrefix) == nil,
              let prefix = ThumbnailKeys.normalizedPrefix(thumbnailPrefix) else { return existing?.thumbnailPrefix }
        return prefix == ThumbnailKeys.defaultPrefix ? nil : prefix
    }

    /// The preset decides, except that a saved destination (an imported
    /// one can differ from its preset) keeps its own setting while its
    /// provider isn't changed here.
    private var forcePathStyle: Bool {
        if let existing, existing.preset == preset {
            return existing.forcePathStyle
        }
        return preset.defaultForcePathStyle
    }

    /// Nil when everything is off, so the destination stays as before.
    private var currentImageProcessing: ImageProcessing? {
        let processing = ImageProcessing(format: imageFormat, quality: imageQuality, maxLongEdge: imageMaxLongEdge)
        return processing.isOff ? nil : processing
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let config = currentConfig()
        let credentials = StorageCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: nil)
        let provider = S3Provider(config: config, credentials: credentials)
        do {
            testResult = try await provider.testConnection()
            testError = nil
        } catch {
            testResult = nil
            testError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(thumbnailCleanup: ThumbnailCleanup = .ask) {
        let oldPrefix = oldThumbnailPrefix
        if thumbnailCleanup == .ask, oldPrefix != nil {
            isConfirmingThumbnailCleanup = true
            return
        }
        // Read before saving replaces them: the old folder may be in
        // another bucket, with other keys.
        if thumbnailCleanup == .delete, let oldPrefix, let existing,
           let oldCredentials = try? KeychainService.load(for: existing.id) {
            BucketThumbnails.deleteFolderInBackground(prefix: oldPrefix, config: existing, credentials: oldCredentials)
        }
        var credentials = StorageCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, sessionToken: nil)
        if let existing, accessKeyId.isEmpty, secretAccessKey.isEmpty,
           let existingCredentials = try? KeychainService.load(for: existing.id) {
            credentials = existingCredentials
        }
        let config = currentConfig()
        // The Cloudflare token: a typed one, otherwise the saved one, and
        // none once the zone ID is cleared.
        let typedToken = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.cloudflareZoneId == nil {
            credentials.cloudflareToken = nil
        } else if !typedToken.isEmpty {
            credentials.cloudflareToken = typedToken
        } else if let existing {
            credentials.cloudflareToken = (try? KeychainService.load(for: existing.id))?.cloudflareToken
        }
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
