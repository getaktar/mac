import SwiftUI

/// Webhooks and scripts that run after an upload, each with an on/off
/// switch, Test and Remove, plus Add Webhook… and Add Script…. A watched
/// folder's Automation and a destination's After Upload both use it, inside
/// their own Section.
struct HookListEditor: View {
    @Binding var hooks: [WatchHook]
    /// Runs the hook with a sample upload; throws what went wrong.
    let test: (WatchHook) async throws -> Void

    @State private var isAddingWebhook = false
    @State private var webhookURL = ""
    /// Why the last address typed in Add Webhook wasn't added.
    @State private var webhookError: String?
    @State private var status: [UUID: TestStatus] = [:]

    private enum TestStatus: Equatable {
        case testing
        case passed
        case failed(String)
    }

    var body: some View {
        ForEach($hooks) { $hook in
            HStack {
                Toggle("", isOn: $hook.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Image(systemName: hook.kind == .webhook ? "network" : "terminal")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: hook.target)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hook.kind == .webhook, let problem = Self.webhookProblem(hook.target) {
                        Text(problem).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                    switch status[hook.id] {
                    case .testing:
                        Text("Testing\u{2026}").font(.caption).foregroundStyle(.secondary)
                    case .passed:
                        Text("Test passed").font(.caption).foregroundStyle(.green)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    case nil:
                        EmptyView()
                    }
                }
                Spacer()
                Button("Test") { run(hook) }
                    .disabled(status[hook.id] == .testing)
                Button {
                    hooks.removeAll { $0.id == hook.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        HStack {
            Button("Add Webhook\u{2026}") { isAddingWebhook = true }
            Menu("Add Script\u{2026}") {
                let scripts = WatchHookRunner.availableScripts()
                if scripts.isEmpty {
                    Text("No scripts yet")
                }
                ForEach(scripts, id: \.self) { name in
                    Button(name) { hooks.append(WatchHook(kind: .script, target: name)) }
                }
                Divider()
                Button("Open Scripts Folder") { WatchHookRunner.openScriptsFolder() }
            }
            .fixedSize()
        }
        .alert("Add Webhook", isPresented: $isAddingWebhook) {
            TextField("Webhook URL", text: $webhookURL, prompt: Text(verbatim: "https://example.com/hook"))
            Button("Add") {
                let target = webhookURL.trimmingCharacters(in: .whitespaces)
                webhookError = nil
                if !target.isEmpty {
                    if let problem = Self.webhookProblem(target) {
                        webhookError = problem
                    } else {
                        hooks.append(WatchHook(kind: .webhook, target: target))
                    }
                }
                webhookURL = ""
            }
            Button("Cancel", role: .cancel) { webhookURL = "" }
        } message: {
            Text("Aktar POSTs a JSON description of each upload to this address. Use https://, or http:// only for this Mac or your local network.")
        }
        if let webhookError {
            Text(webhookError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run(_ hook: WatchHook) {
        status[hook.id] = .testing
        Task {
            do {
                try await test(hook)
                status[hook.id] = .passed
            } catch {
                status[hook.id] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Why a webhook address can't be used, or nil when it can.
    static func webhookProblem(_ target: String) -> String? {
        switch WatchHookAddress.check(target) {
        case .allowed: return nil
        case .invalid: return WatchHookError.invalidURL.errorDescription
        case .insecure: return WatchHookError.insecureURL.errorDescription
        }
    }

    /// A webhook (kept from before addresses were checked, or imported)
    /// that would be refused: it has to be fixed or removed before saving.
    static func hasUnusableWebhook(_ hooks: [WatchHook]) -> Bool {
        hooks.contains { $0.kind == .webhook && webhookProblem($0.target) != nil }
    }
}
