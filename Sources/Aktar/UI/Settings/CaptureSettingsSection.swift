import AppKit
import SwiftUI

/// Settings > General > Capture: which screenshot tool Capture runs, and
/// how to set it up (docs/capture-tools.md).
struct CaptureSettingsSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage(CaptureTool.settingKey) private var toolID = CaptureTool.system.rawValue
    /// Refreshed when Aktar comes back to the front (after installing one).
    @State private var tools = CaptureTool.ordered
    @State private var installed: Set<CaptureTool> = Set(CaptureTool.allCases.filter(\.isInstalled))
    @State private var folderPath: String?

    private var tool: CaptureTool { CaptureTool(rawValue: toolID) ?? .system }

    var body: some View {
        SettingsSection(title: "Capture tool") {
            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capture with")
                        Text("The tool that takes the screenshot. With an editor such as CleanShot X, Shottr, macshot or Flameshot, you can annotate it before it\u{2019}s uploaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Capture with", selection: $toolID) {
                        ForEach(tools) { option in
                            if installed.contains(option) {
                                Text(verbatim: option.name).tag(option.rawValue)
                            } else {
                                Text("\(option.name) (not installed)").tag(option.rawValue)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(12)

                if tool != .system {
                    if !installed.contains(tool) {
                        SettingsCardDivider()
                        HStack {
                            Text("\(tool.name) isn\u{2019}t installed on this Mac.")
                                .font(.callout)
                            Spacer()
                            if let website = tool.website {
                                Button("Get \(tool.name)") { NSWorkspace.shared.open(website) }
                            }
                        }
                        .padding(12)
                    }

                    SettingsCardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tool.setupSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "\(index + 1).")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(verbatim: step)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)

                    if tool.usesSaveFolder {
                        SettingsCardDivider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save folder")
                                Text("Optional. An image \(tool.name) saves here while Aktar waits is uploaded too; copying works without it. Aktar waits up to 10 minutes.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let folderPath {
                                    Text(verbatim: folderPath)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            if folderPath != nil {
                                Button("Remove") {
                                    tool.saveFolderBookmark = nil
                                    folderPath = nil
                                }
                            }
                            Button("Choose\u{2026}") { chooseFolder() }
                        }
                        .padding(12)
                    }

                    SettingsCardDivider()
                    HStack {
                        Text("Try it: the image is uploaded and its link copied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Capture Now") { appState.capture(paste: false) }
                            .disabled(!installed.contains(tool))
                    }
                    .padding(12)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: toolID) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        tools = CaptureTool.ordered
        installed = Set(CaptureTool.allCases.filter(\.isInstalled))
        folderPath = tool.saveFolderPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder \(tool.name) saves screenshots to.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool.saveFolderBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        folderPath = tool.saveFolderPath
    }
}
