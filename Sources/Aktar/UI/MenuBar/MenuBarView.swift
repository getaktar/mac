import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \UploadRecord.createdAt, order: .reverse) private var records: [UploadRecord]
    @State private var isTargeted = false
    @State private var isSettingUpExpiry = false

    var body: some View {
        Group {
            if appState.destinationStore.destinations.isEmpty {
                emptyStateView
            } else {
                uploadStateView
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .background(hiddenShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: .aktarOpenWindow)) { notification in
            if let id = notification.object as? String { openAppWindow(id) }
        }
    }

    /// Global-feeling shortcuts (⌘V paste-and-upload, ⌘, for Settings, ⌘Q to
    /// quit) that work whenever the popover has focus, since an accessory
    /// app like Aktar has no visible application menu to host them in.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { uploadClipboard() }
                .keyboardShortcut("v", modifiers: [.command])
            Button("") { openAppWindow("settings") }
                .keyboardShortcut(",", modifiers: [.command])
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command])
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    // MARK: - Empty state

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Aktar").font(.headline)
            Text("Connect your own S3-compatible storage to start uploading.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Connect Storage") { openAppWindow("onboarding") }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Normal state

    private var uploadStateView: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .bottom, spacing: 8) {
                destinationPicker
                expiryPicker
                linkPicker
            }
            dropzone
            recentSection
        }
    }

    private var header: some View {
        HStack {
            Text("Upload").font(.headline)
            Spacer()
            Button {
                openAppWindow("settings")
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Destination

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Destination").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(appState.destinationStore.destinations) { destination in
                    Button {
                        appState.destinationStore.setDefault(destination)
                    } label: {
                        if destination.id == appState.destinationStore.defaultDestination?.id {
                            Label(destinationLabel(destination), systemImage: "checkmark")
                        } else {
                            Text(destinationLabel(destination))
                        }
                    }
                }
            } label: {
                Text(currentDestinationLabel)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
        }
    }

    // MARK: - Link

    /// Public URL or a temporary link, for the selected destination.
    private var linkPicker: some View {
        let manager = appState.uploadManager
        let destination = appState.destinationStore.defaultDestination
        let selection = Binding(
            get: { destination?.temporaryLink },
            set: { duration in destination.map { manager.setTemporaryLink(duration, for: $0) } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text("Link").font(.caption).foregroundStyle(.secondary)
            Menu {
                Picker("Link", selection: selection) {
                    Text(TemporaryLinkDuration.label(nil)).tag(TemporaryLinkDuration?.none)
                    ForEach(TemporaryLinkDuration.allCases) { duration in
                        Text(TemporaryLinkDuration.label(duration)).tag(TemporaryLinkDuration?.some(duration))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(TemporaryLinkDuration.label(destination?.temporaryLink))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(destination == nil)
            .help("Copy the public URL after an upload, or a temporary link that stops working after this long. Temporary links also work for private buckets.")
        }
    }

    // MARK: - Expiry

    /// Durations are only offered once the destination's bucket has the
    /// lifecycle rules; until then the menu offers to set them up.
    private var expiryPicker: some View {
        let manager = appState.uploadManager
        let destination = appState.destinationStore.defaultDestination
        let isReady = destination.map { ExpiryRuleStore.shared.isActive($0.id) } ?? false
        let selection = Binding(
            get: { destination.map(manager.expiryDays(for:)) ?? 0 },
            set: { days in destination.map { manager.setExpiryDays(days, for: $0) } }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text("Delete after").font(.caption).foregroundStyle(.secondary)
            Menu {
                Picker("Delete after", selection: selection) {
                    ForEach([0] + UploadExpiry.options, id: \.self) { days in
                        Text(UploadExpiry.label(days: days)).tag(days)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!isReady)
                if !isReady, let destination {
                    Divider()
                    Button(isSettingUpExpiry ? String(localized: "Setting Up\u{2026}") : String(localized: "Set Up Auto-Delete\u{2026}")) {
                        Task { await setUpExpiry(for: destination) }
                    }
                    .disabled(isSettingUpExpiry)
                }
            } label: {
                Text(UploadExpiry.label(days: manager.effectiveExpiryDays(for: destination)))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func setUpExpiry(for destination: DestinationConfig) async {
        isSettingUpExpiry = true
        defer { isSettingUpExpiry = false }
        // Files already in those folders would start expiring with the
        // rules, so that's confirmed first. A failed check is left to
        // setting up, which reports the same problem.
        if let inUse = try? await appState.uploadManager.expiryPrefixesInUse(for: destination),
           !inUse.isEmpty, !confirmSetUp(deleting: inUse) {
            return
        }
        do {
            try await appState.uploadManager.setUpExpiryRules(for: destination)
        } catch {
            showExpirySetupFailure(error)
        }
    }

    private func confirmSetUp(deleting prefixes: [String]) -> Bool {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Files already in these folders will be deleted")
        alert.informativeText = String(localized: "\(prefixes.joined(separator: ", ")) already hold files. Once the rules are set up, the bucket deletes them too when they're older than the folder's number of days.")
        let setUp = alert.addButton(withTitle: String(localized: "Set Up Anyway"))
        setUp.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A real alert rather than text squeezed into the panel: the reason is
    /// long, and it's something to act on in the provider's dashboard.
    private func showExpirySetupFailure(_ error: Error) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.informativeText = DestinationFormView.refusedExplanation
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private var currentDestinationLabel: String {
        guard let destination = appState.destinationStore.defaultDestination else { return String(localized: "No destination") }
        return destinationLabel(destination)
    }

    private func destinationLabel(_ destination: DestinationConfig) -> String {
        "\(destination.name) · \(destination.preset.displayName)"
    }

    // MARK: - Dropzone

    private var dropzone: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.up.circle")
                .font(.system(size: 28))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            if isTargeted {
                Text("Release to upload").font(.subheadline.bold())
            } else {
                Text("Drop files here").font(.subheadline.bold())

                HStack(spacing: 8) {
                    Button("Paste") { uploadClipboard() }
                    Button("Browse") { chooseFile() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Kept visible whenever it's on, so a sticky "Delete after"
            // choice can't quietly apply to a file meant to stay.
            let expiryDays = appState.uploadManager.effectiveExpiryDays(for: appState.destinationStore.defaultDestination)
            if expiryDays > 0 {
                Label(
                    String(localized: "Deletes after \(UploadExpiry.label(days: expiryDays))"),
                    systemImage: "timer"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isTargeted ? 2 : 1)
        )
    }

    // MARK: - Recent uploads

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent uploads").font(.subheadline.bold())
                Spacer()
                Button("See all") { openAppWindow("library") }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            if activeJobs.isEmpty && recentRecords.isEmpty {
                emptyRecentState
            } else {
                ForEach(activeJobs) { job in
                    JobRowView(job: job)
                }
                ForEach(recentRecords) { record in
                    RecentRowView(record: record, openLibrary: { openAppWindow("library") })
                }
            }
        }
    }

    private var emptyRecentState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No uploads yet").font(.caption).foregroundStyle(.secondary)
            Text("Your recent uploads will appear here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var activeJobs: [UploadJob] {
        appState.uploadManager.jobs.filter {
            switch $0.state {
            case .waiting, .uploading, .failed: return true
            case .succeeded, .cancelled: return false
            }
        }
    }

    private var recentRecords: [UploadRecord] {
        Array(records.prefix(3))
    }

    /// Aktar runs as an accessory app (no Dock icon), so a window opened
    /// while the app isn't the active app can appear without focus, or not
    /// come to the front at all. Activating first ensures it's visible.
    private func openAppWindow(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let inputs = panel.urls.map {
                UploadInput(fileURL: $0, originalFilename: $0.lastPathComponent, source: .filePicker)
            }
            appState.uploadManager.upload(inputs)
        }
    }

    private func uploadClipboard() {
        appState.uploadFromClipboard()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var inputs: [UploadInput] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    inputs.append(UploadInput(fileURL: url, originalFilename: url.lastPathComponent, source: .dragDrop))
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !inputs.isEmpty {
                appState.uploadManager.upload(inputs)
            }
        }
        return true
    }
}

private struct JobRowView: View {
    let job: UploadJob
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: FileKindIcon.symbolName(for: job.input.originalFilename))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(job.input.originalFilename).font(.caption).lineLimit(1)
                switch job.state {
                case .uploading(let progress):
                    ProgressView(value: progress)
                case .failed:
                    HStack(spacing: 6) {
                        Text("Upload failed").font(.caption2).foregroundStyle(.red)
                        Button("Retry") { appState.uploadManager.retry(job) }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                default:
                    EmptyView()
                }
            }
        }
    }
}

private struct RecentRowView: View {
    let record: UploadRecord
    let openLibrary: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            thumbnail

            Button {
                ClipboardService.copy(record.publicURLString)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.localFilename).font(.caption).lineLimit(1)
                    HStack(spacing: 4) {
                        if let expiresAt = record.expiresAt {
                            Label(UploadExpiry.deletionLabel(for: expiresAt), systemImage: "timer")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.orange)
                                .fixedSize()
                        }
                        Text(displayURL).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption2)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Copy") { ClipboardService.copy(record.publicURLString) }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)

            Menu {
                Button("Copy URL") { ClipboardService.copy(record.publicURLString) }
                Button("Copy Markdown") { copy(mode: .markdown) }
                Button("Copy HTML") { copy(mode: .html) }
                RecordTemporaryLinkMenu(record: record)
                Divider()
                Button("Open in Browser") {
                    if let url = record.publicURL { NSWorkspace.shared.open(url) }
                }
                Button("Show in Library") { openLibrary() }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { try? await appState.uploadManager.deleteRemote(record) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
        }
    }

    private var displayURL: String {
        record.publicURLString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func copy(mode: OutputMode) {
        let url = record.publicURL ?? URL(string: record.publicURLString)!
        ClipboardService.copy(OutputFormatter.format(publicURL: url, mode: mode, filename: record.localFilename))
    }

    private var thumbnail: some View {
        Group {
            if let thumb = ThumbnailCache.image(for: record.id) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
                    .overlay(
                        Image(systemName: FileKindIcon.symbolName(for: record.localFilename))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
