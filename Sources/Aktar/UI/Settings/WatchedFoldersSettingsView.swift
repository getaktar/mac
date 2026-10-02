import AppKit
import SwiftUI

/// Settings > Watched Folders: pausing, the folders, and adding one.
struct WatchedFoldersSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var editing: WatchedFolder?
    @State private var resetTarget: WatchedFolder?
    @State private var removeTarget: WatchedFolder?
    @State private var isAdding = false
    @State private var loginItemEnabled = LoginItemService.isEnabled

    private var service: WatchService { appState.watchService }

    var body: some View {
        SettingsPage(title: "Watched Folders", subtitle: "Upload new files from folders automatically.") {
            if service.folders.isEmpty {
                emptyState
            } else {
                watchingSection
                foldersSection
            }
            if !loginItemEnabled {
                loginHint
            }
        }
        .sheet(item: $editing) { folder in
            WatchedFolderFormView(folder: folder) { updated in
                service.update(updated)
                editing = nil
            }
        }
        .confirmationDialog(
            "Forget which files were handled?",
            isPresented: Binding(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }),
            presenting: resetTarget
        ) { folder in
            Button("Reset", role: .destructive) { service.reset(folder.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Every file in the folder counts as new again, and is uploaded once more (more than 50 at once ask first).")
        }
        .confirmationDialog(
            "Stop watching this folder?",
            isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
            presenting: removeTarget
        ) { folder in
            Button("Remove", role: .destructive) { service.remove(folder.id) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("\u{201C}\(folder.name)\u{201D} and its files stay where they are, and uploads stay in the bucket.")
        }
        .onAppear {
            loginItemEnabled = LoginItemService.isEnabled
            handlePendingRequests()
        }
        .onChange(of: service.pendingAddURL) { handlePendingRequests() }
        .onChange(of: service.pendingEditID) { handlePendingRequests() }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Upload files the moment they land in a folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Upload Screenshots Automatically") { addScreenshots() }
                    .buttonStyle(.borderedProminent)
                Button("Add Folder\u{2026}") { addFolder() }
            }
            .disabled(isAdding)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var watchingSection: some View {
        SettingsSection(title: "Watching") {
            SettingsCard {
                HStack {
                    Label(service.statusLine, systemImage: service.isPaused ? "pause.circle" : "eye")
                    Spacer()
                    WatchPauseMenu(service: service)
                        .fixedSize()
                }
                .padding(12)
                SettingsCardDivider()
                SettingsToggleRow(
                    title: "Pause on battery power",
                    subtitle: "Files wait in their folders until your Mac is plugged in.",
                    isOn: Binding(get: { service.store.settings.pauseOnBattery }, set: { service.setPauseOnBattery($0) })
                )
                SettingsCardDivider()
                SettingsToggleRow(
                    title: "Pause on Low Data Mode or metered networks",
                    subtitle: "Such as a phone\u{2019}s hotspot.",
                    isOn: Binding(get: { service.store.settings.pauseOnMetered }, set: { service.setPauseOnMetered($0) })
                )
            }
        }
    }

    private var foldersSection: some View {
        SettingsSection(title: "Folders") {
            SettingsCard {
                ForEach(Array(service.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 { SettingsCardDivider() }
                    WatchedFolderRow(
                        folder: folder,
                        onEdit: { editing = folder },
                        onGrantAccess: { grantAccess(folder) },
                        onReset: { resetTarget = folder },
                        onRemove: { removeTarget = folder }
                    )
                }
            }
            Button {
                addFolder()
            } label: {
                Label("Add Folder\u{2026}", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(isAdding)
        }
    }

    private var loginHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "power")
                .foregroundStyle(.secondary)
            Text("Turn on Open at Login so watching continues after a restart")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Turn On") {
                launchAtLogin = true
                LoginItemService.setEnabled(true)
                loginItemEnabled = LoginItemService.isEnabled
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Adding

    /// A folder from the Finder service or aktar://, or a folder whose form
    /// should open.
    private func handlePendingRequests() {
        if let url = service.pendingAddURL {
            service.pendingAddURL = nil
            // After this update, so the picker doesn't open mid-layout.
            DispatchQueue.main.async { addFolder(preselected: url) }
        }
        if let id = service.pendingEditID {
            service.pendingEditID = nil
            editing = service.store.folder(id: id)
        }
    }

    private func addScreenshots() {
        let location = ScreenshotLocation.folder()
        guard let url = WatchFolderPicker.pick(
            preselected: location,
            message: String(localized: "Confirm the folder macOS saves screenshots to, so Aktar can watch it.")
        ) else { return }
        Task { await add(url, screenshots: true) }
    }

    private func addFolder(preselected: URL? = nil) {
        guard let url = WatchFolderPicker.pick(
            preselected: preselected,
            message: String(localized: "Choose a folder. New files in it are uploaded automatically.")
        ) else { return }
        Task { await add(url, screenshots: false) }
    }

    private func grantAccess(_ folder: WatchedFolder) {
        guard let url = WatchFolderPicker.pick(
            preselected: folder.url,
            message: String(localized: "Choose \u{201C}\(folder.name)\u{201D} again to give Aktar access to it.")
        ) else { return }
        if let reason = service.forbiddenReason(for: url, excluding: folder.id) {
            WatchFolderPicker.showProblem(reason.message)
            return
        }
        service.replaceBookmark(folder.id, url: url)
    }

    /// Checks the folder, asks about the files already in it, adds it and
    /// opens its form.
    private func add(_ url: URL, screenshots: Bool) async {
        if let reason = service.forbiddenReason(for: url) {
            WatchFolderPicker.showProblem(reason.message)
            return
        }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = screenshots
            ? WatchedFolder.screenshots(path: url.path, bookmark: bookmark)
            : WatchedFolder(name: url.lastPathComponent, path: url.path, bookmark: bookmark)
        isAdding = true
        defer { isAdding = false }
        let existing = await Task.detached(priority: .userInitiated) {
            WatchService.existingFiles(in: folder, root: url)
        }.value
        // Screenshots that are already there were shared some other way.
        var uploadExisting = false
        if !screenshots, !existing.isEmpty {
            uploadExisting = WatchFolderPicker.askToUploadExisting(count: existing.count)
        }
        service.add(folder, existing: existing, uploadExisting: uploadExisting)
        editing = service.store.folder(id: folder.id)
    }
}

/// The folder picker and the alerts around adding a folder.
@MainActor
enum WatchFolderPicker {
    static func pick(preselected: URL?, message: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Watch")
        panel.message = message
        if let preselected {
            // Opening inside the folder means Watch picks it as it is.
            panel.directoryURL = preselected
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func showProblem(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "This folder can't be watched")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// True for Upload Them. Skip is the default: a folder full of old
    /// files is rarely meant to be shared all at once.
    static func askToUploadExisting(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(localized: "This folder already has 1 file. Upload it now?")
            : String(localized: "This folder already has \(count) files. Upload them now?")
        alert.informativeText = String(localized: "Either way, files added from now on are uploaded.")
        alert.addButton(withTitle: String(localized: "Skip Existing Files"))
        alert.addButton(withTitle: count == 1 ? String(localized: "Upload It") : String(localized: "Upload Them"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Pause For 1 Hour / Until Tomorrow / Until I Resume, or Resume.
struct WatchPauseMenu: View {
    let service: WatchService

    var body: some View {
        if service.manualPause != nil {
            Button("Resume") { service.resume() }
        } else {
            Menu("Pause") {
                Button("For 1 Hour") { service.pause(minutes: 60) }
                Button("Until Tomorrow") { service.pauseUntilTomorrow() }
                Button("Until I Resume") { service.pause(minutes: nil) }
            }
        }
    }
}

/// "312 new files in Screenshots" with Upload and Skip.
struct WatchConfirmationBanner: View {
    @Environment(AppState.self) private var appState
    let folder: WatchedFolder
    let count: Int
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("\(count) new files in \(folder.name)")
                .font(compact ? .caption : .callout)
                .lineLimit(2)
            Spacer()
            Button("Skip") { appState.watchService.skipPending(folder.id) }
            Button("Upload") { appState.watchService.confirmPending(folder.id) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(compact ? .small : .regular)
        .padding(compact ? 8 : 12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10))
    }
}

/// "312 files were removed from Screenshots. Delete them from the bucket
/// too?" with Delete from Bucket and Keep Uploaded Files.
struct WatchDeleteConfirmationBanner: View {
    @Environment(AppState.self) private var appState
    let folder: WatchedFolder
    /// The files' names.
    let names: [String]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "trash.circle.fill")
                    .foregroundStyle(.red)
                Group {
                    if names.count == 1 {
                        Text("\(names[0]) was removed from \(folder.name). Delete it from the bucket too?")
                    } else {
                        Text("\(names.count) files were removed from \(folder.name). Delete them from the bucket too?")
                    }
                }
                    .font(compact ? .caption : .callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Keep Uploaded Files") { appState.watchService.keepPendingDeletes(folder.id) }
                Button("Delete from Bucket", role: .destructive) { appState.watchService.confirmPendingDeletes(folder.id) }
            }
        }
        .controlSize(compact ? .small : .regular)
        .padding(compact ? 8 : 12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10))
    }
}

private struct WatchedFolderRow: View {
    @Environment(AppState.self) private var appState
    let folder: WatchedFolder
    let onEdit: () -> Void
    let onGrantAccess: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void

    private var service: WatchService { appState.watchService }
    private var engine: FolderWatchEngine? { service.engine(id: folder.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: folder.preset == .screenshots ? "camera.viewfinder" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(folder.name)
                    WatchStatusChip(folder: folder)
                }
                Text(verbatim: UserPaths.abbreviated(folder.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = service.lastErrors[folder.id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let count = engine?.awaitingConfirmation, count > 0 {
                    WatchConfirmationBanner(folder: folder, count: count, compact: true)
                        .padding(.top, 4)
                }
                if let names = engine?.awaitingDeleteNames, !names.isEmpty {
                    WatchDeleteConfirmationBanner(folder: folder, names: names, compact: true)
                        .padding(.top, 4)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(get: { folder.enabled }, set: { service.setEnabled($0, folderID: folder.id) }))
                .labelsHidden()
                .toggleStyle(.switch)

            Menu {
                Button("Edit", action: onEdit)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                }
                if service.status(for: folder) == .accessNeeded {
                    Button("Grant Access\u{2026}", action: onGrantAccess)
                }
                Divider()
                Button("Upload Pending Now") { engine?.uploadPendingNow() }
                    .disabled(engine?.isRunning != true)
                Button("Retry Failed") { engine?.retryFailed() }
                    .disabled(engine?.isRunning != true || (engine?.failedCount ?? 0) == 0)
                Button("Reset\u{2026}", action: onReset)
                Divider()
                Button("Remove\u{2026}", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .padding(.top, 2)
        }
        .padding(12)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        }
    }

    /// "Cloudflare · Last upload 5 minutes ago".
    private var details: String {
        let destination = service.destination(for: folder)?.name ?? String(localized: "No destination")
        guard let last = engine?.lastUploadAt else { return destination }
        let ago = last.formatted(.relative(presentation: .named))
        return "\(destination) \u{00B7} " + String(localized: "Last upload \(ago)")
    }
}

/// Watching / Paused / Waiting for 3 files / Uploading 2 / 4 failed /
/// Access needed / Folder not found.
struct WatchStatusChip: View {
    @Environment(AppState.self) private var appState
    let folder: WatchedFolder

    var body: some View {
        HStack(spacing: 4) {
            chip(label.text, color: label.color)
            if let failed = failedCount, label.color != .red {
                chip(String(localized: "\(failed) failed"), color: .red)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .fixedSize()
    }

    private var failedCount: Int? {
        guard let failed = appState.watchService.engine(id: folder.id)?.failedCount, failed > 0 else { return nil }
        return failed
    }

    private var label: (text: String, color: Color) {
        let service = appState.watchService
        let engine = service.engine(id: folder.id)
        switch service.status(for: folder) {
        case .accessNeeded: return (String(localized: "Access needed"), .orange)
        case .notFound: return (String(localized: "Folder not found"), .orange)
        case .error: return (String(localized: "Error"), .red)
        case .disabled: return (String(localized: "Off"), .secondary)
        case .paused: return (String(localized: "Paused"), .secondary)
        case .watching:
            if let uploading = engine?.uploadingCount, uploading > 0 {
                return (String(localized: "Uploading \(uploading)"), .accentColor)
            }
            if let waiting = engine?.waitingCount, waiting > 0 {
                return waiting == 1
                    ? (String(localized: "Waiting for 1 file"), .accentColor)
                    : (String(localized: "Waiting for \(waiting) files"), .accentColor)
            }
            if failedCount != nil {
                return (String(localized: "\(failedCount ?? 0) failed"), .red)
            }
            return (String(localized: "Watching"), .green)
        }
    }
}
