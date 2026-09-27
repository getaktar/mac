import AppKit
import SwiftUI

struct IntegrationsSettingsView: View {
    @State private var service = LocalAPIService.shared
    @State private var portText = ""
    @State private var isTokenVisible = false
    @State private var didCopyToken = false

    /// getaktar.com/raycast (in the app's language) rather than the Store
    /// listing directly: the site page works before the extension is in
    /// the Store and switches to an install button once it is, without an
    /// app update.
    private static var raycastPageURL: URL {
        URL(string: "raycast/", relativeTo: AppInfo.website)?.absoluteURL ?? AppInfo.website
    }

    var body: some View {
        SettingsPage(title: "Integrations", subtitle: "Use Aktar from other apps on this Mac.") {
            SettingsSection(title: "Raycast") {
                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aktar for Raycast")
                            Text("Upload files and the clipboard, search your history, and browse your buckets without opening Aktar. Run \u{201C}Connect to Aktar\u{201D} in Raycast to pair it in one click.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Get Extension") { NSWorkspace.shared.open(Self.raycastPageURL) }
                    }
                    .padding(12)
                }
            }

            SettingsSection(title: "Local API") {
                SettingsCard {
                    SettingsToggleRow(
                        title: "Allow local connections",
                        subtitle: "Listen on 127.0.0.1 so the Raycast extension can reach Aktar. Requests need the token below.",
                        isOn: $service.isEnabled
                    )
                    SettingsCardDivider()
                    HStack {
                        Text("Status")
                        Spacer()
                        statusLabel
                    }
                    .padding(12)
                    SettingsCardDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Port")
                            Text("Change it only if another app already uses this one.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onSubmit(applyPort)
                    }
                    .padding(12)
                    SettingsCardDivider()
                    tokenRow
                }
            }
        }
        .onAppear { portText = String(service.port) }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch service.status {
        case .off:
            Label("Off", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting\u{2026}", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running:
            Label {
                Text(verbatim: "127.0.0.1:\(service.port)")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(message)
        }
    }

    private var tokenRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token")
                Text("Paste it into the extension\u{2019}s preferences if you don\u{2019}t use \u{201C}Connect to Aktar\u{201D}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                if isTokenVisible {
                    Text(verbatim: service.token.isEmpty ? "-" : service.token)
                        .textSelection(.enabled)
                } else {
                    Text(verbatim: String(repeating: "\u{2022}", count: 12))
                }
            }
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180, alignment: .trailing)
            Button {
                isTokenVisible.toggle()
            } label: {
                Image(systemName: isTokenVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isTokenVisible ? "Hide token" : "Show token")
            Button(didCopyToken ? "Copied" : "Copy") {
                ClipboardService.copy(service.token)
                didCopyToken = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    didCopyToken = false
                }
            }
            .disabled(service.token.isEmpty)
            Button("Regenerate") { service.regenerateToken() }
                .help("Create a new token. Anything already connected will have to connect again.")
        }
        .padding(12)
    }

    private func applyPort() {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value >= 1024 else {
            portText = String(service.port)
            return
        }
        service.port = value
    }
}
