import KeyboardShortcuts
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case destinations
    case watchedFolders
    case output
    case integrations
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            return "General"
        case .destinations:
            return "Destinations"
        case .watchedFolders:
            return "Watched Folders"
        case .output:
            return "Output"
        case .integrations:
            return "Integrations"
        case .about:
            return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            return "gearshape"
        case .destinations:
            return "cloud"
        case .watchedFolders:
            return "eye"
        case .output:
            return "square.on.square"
        case .integrations:
            return "puzzlepiece.extension"
        case .about:
            return "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(200)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: .infinity, height: .infinity)
        // aktar://watch and "Watch Folder with Aktar" open a given tab.
        .onAppear(perform: showRequestedTab)
        .onChange(of: appState.requestedSettingsTab) { showRequestedTab() }
    }

    private func showRequestedTab() {
        guard let raw = appState.requestedSettingsTab else { return }
        appState.requestedSettingsTab = nil
        if let tab = SettingsTab(rawValue: raw) { selectedTab = tab }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbolName)
                    .tag(tab)
            }
        }
        .navigationTitle("Settings")
        .ignoresSafeArea(.container, edges: .leading)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedTab ?? .general {
        case .general:
            GeneralSettingsView()

        case .destinations:
            DestinationsSettingsView()

        case .watchedFolders:
            WatchedFoldersSettingsView()

        case .output:
            OutputSettingsView()

        case .integrations:
            IntegrationsSettingsView()

        case .about:
            AboutSettingsView()
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var sidebarFooter: some View {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text(verbatim: "Aktar \(version)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage(UploadManager.showNotificationKey) private var showNotification = true
    @AppStorage("closePopoverAfterUpload") private var closePopover = true
    @AppStorage(UploadManager.reuseDuplicatesKey) private var reuseDuplicates = true
    @State private var language = AppLanguage.override

    var body: some View {
        SettingsPage(title: "General", subtitle: "Control how the app behaves.") {
            SettingsSection(title: "Language") {
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App language")
                            Text("Follows your Mac\u{2019}s language unless you pick one here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("App language", selection: $language) {
                            Text("System Default").tag(String?.none)
                            Divider()
                            ForEach(AppLanguage.supported, id: \.code) { language in
                                Text(verbatim: language.name).tag(Optional(language.code))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: language) { _, newValue in
                            AppLanguage.override = newValue
                        }
                    }
                    .padding(12)

                    if language != AppLanguage.atLaunch {
                        SettingsCardDivider()
                        HStack {
                            Text("Restart Aktar to apply the new language.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart Now") { AppLanguage.relaunch() }
                        }
                        .padding(12)
                    }
                }
            }

            SettingsSection(title: "Updates") {
                @Bindable var updater = appState.updater
                SettingsCard {
                    SettingsToggleRow(
                        title: "Automatically check for updates",
                        subtitle: "Look for a new version on GitHub once a day",
                        isOn: $updater.automaticallyChecksForUpdates
                    )
                    SettingsCardDivider()
                    SettingsToggleRow(
                        title: "Automatically install updates",
                        subtitle: "Download new versions in the background and install them when Aktar quits",
                        isOn: $updater.automaticallyDownloadsUpdates
                    )
                    .disabled(!updater.automaticallyChecksForUpdates)
                }
                Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }

            SettingsSection(title: "Startup") {
                SettingsCard {
                    SettingsToggleRow(
                        title: "Launch at login",
                        subtitle: "Open the app automatically when you sign in",
                        isOn: launchAtLoginBinding
                    )
                }
            }

            SettingsSection(title: "Keyboard shortcut") {
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paste & upload from anywhere")
                            Text("Works even when the panel is closed. Click to record, or press Delete to clear it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .uploadFromClipboard)
                    }
                    .padding(12)
                    SettingsCardDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rename and upload clipboard")
                            Text("Asks for the file\u{2019}s name first, then uploads it like the shortcut above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .renameAndUploadFromClipboard)
                    }
                    .padding(12)
                }
            }

            SettingsSection(title: "Uploads") {
                SettingsCard {
                    SettingsToggleRow(
                        title: "Show notification after upload",
                        subtitle: "Notify me when an upload completes",
                        isOn: $showNotification
                    )
                    SettingsCardDivider()
                    SettingsToggleRow(
                        title: "Close popover after upload",
                        subtitle: "Automatically close after a successful upload",
                        isOn: $closePopover
                    )
                    SettingsCardDivider()
                    SettingsToggleRow(
                        title: "Reuse links for duplicate files",
                        subtitle: "When a file you already uploaded to the same destination comes up again, Aktar copies its existing link instead of uploading it again.",
                        isOn: $reuseDuplicates
                    )
                }
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                LoginItemService.setEnabled(newValue)
            }
        )
    }
}

private struct DestinationsSettingsView: View {
    /// What the destination form is open for. The sheet is driven by this
    /// value itself (`sheet(item:)`), so the form always gets the
    /// destination that was clicked; with a separate flag it could open
    /// with a stale, empty one.
    private enum FormTarget: Identifiable {
        case add
        case edit(DestinationConfig)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let destination): return destination.id.uuidString
            }
        }

        var destination: DestinationConfig? {
            if case .edit(let destination) = self { return destination }
            return nil
        }
    }

    @Environment(AppState.self) private var appState
    @State private var formTarget: FormTarget?

    var body: some View {
        SettingsPage(title: "Destinations", subtitle: "Manage where your files are uploaded.") {
            if appState.destinationStore.destinations.isEmpty {
                emptyState
            } else {
                SettingsSection(title: "Upload destinations") {
                    SettingsCard {
                        ForEach(Array(appState.destinationStore.destinations.enumerated()), id: \.element.id) { index, destination in
                            if index > 0 { SettingsCardDivider() }
                            DestinationRow(
                                destination: destination,
                                onEdit: { formTarget = .edit(destination) },
                                onSetDefault: { appState.destinationStore.setDefault(destination) },
                                onDuplicate: {
                                    guard let copy = appState.destinationStore.duplicate(destination) else { return }
                                    formTarget = .edit(copy)
                                },
                                onRemove: { appState.destinationStore.remove(destination) }
                            )
                        }
                    }
                }

                Button {
                    formTarget = .add
                } label: {
                    Label("Add Destination", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(item: $formTarget) { target in
            DestinationFormView(existing: target.destination) { config, credentials in
                if target.destination != nil {
                    appState.destinationStore.update(config)
                } else {
                    appState.destinationStore.add(config)
                }
                try? KeychainService.save(credentials, for: config.id)
                formTarget = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No destinations yet").font(.headline)
            Text("Connect an S3-compatible storage provider\nto start uploading files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                formTarget = .add
            } label: {
                Text("Add Destination")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct DestinationRow: View {
    let destination: DestinationConfig
    let onEdit: () -> Void
    let onSetDefault: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: destination.preset.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                Text(verbatim: "\(destination.preset.displayName) · \(destination.bucket)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if destination.isDefault {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button("Edit", action: onEdit)
                if !destination.isDefault {
                    Button("Set as Default", action: onSetDefault)
                }
                Button("Duplicate", action: onDuplicate)
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(12)
    }
}

private struct OutputSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var manager = appState.uploadManager

        SettingsPage(title: "Output", subtitle: "Choose what is copied after an upload.") {
            SettingsSection(title: "Copied format") {
                Text("Choose what gets copied to your clipboard after a successful upload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsCard {
                    OutputOptionRow(
                        title: "URL",
                        example: "https://cdn.example.com/image.png",
                        isSelected: manager.outputMode == .url
                    ) { manager.outputMode = .url }

                    SettingsCardDivider()

                    OutputOptionRow(
                        title: "Markdown",
                        example: "![](https://cdn.example.com/image.png)",
                        isSelected: manager.outputMode == .markdown
                    ) { manager.outputMode = .markdown }

                    SettingsCardDivider()

                    OutputOptionRow(
                        title: "HTML",
                        example: "<img src=\"https://cdn.example.com/...\">",
                        isSelected: manager.outputMode == .html
                    ) { manager.outputMode = .html }

                    SettingsCardDivider()

                    OutputOptionRow(
                        title: "Custom",
                        example: String(localized: "Define your own template."),
                        isSelected: manager.outputMode == .custom
                    ) { manager.outputMode = .custom }

                    if manager.outputMode == .custom {
                        SettingsCardDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Template").font(.caption).foregroundStyle(.secondary)
                            TextField("Template", text: $manager.customTemplate)
                                .textFieldStyle(.roundedBorder)
                            Text("Available variables: {url} {filename} {name} {ext}")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

private struct OutputOptionRow: View {
    let title: LocalizedStringKey
    let example: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(example)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
    }
}
