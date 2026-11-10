import AppKit
import SwiftUI

/// "Request Files": a link where anyone who has it can send files into a
/// destination's bucket until it expires (docs/share-pages.md, part 4).
struct RequestFilesView: View {
    var onDone: () -> Void

    @Environment(AppState.self) private var appState
    @State private var destinationID: UUID?
    @State private var title = ""
    @State private var note = ""
    @State private var duration = FileRequests.defaultDuration
    @State private var slots = FileRequests.defaultSlots
    @State private var maxBytes = FileRequests.defaultMaxBytes
    @State private var isCreating = false
    @State private var error: String?
    /// The CORS rule to add by hand, when the bucket refused it.
    @State private var corsRule: (origin: String, json: String)?
    @State private var created: FileRequest?

    var body: some View {
        VStack(spacing: 0) {
            Text("Request Files")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            Divider()
            if let created {
                RequestCreatedView(request: created)
            } else {
                form
            }
            Divider()
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                if created != nil {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { onDone() }
                    Button("Create Link") { create(corsDoneByHand: false) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isCreating || destination == nil)
                }
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .onAppear {
            if destinationID == nil { destinationID = appState.destinationStore.defaultDestination?.id }
        }
    }

    private var destination: DestinationConfig? {
        appState.destinationStore.destinations.first { $0.id == destinationID }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Destination", selection: $destinationID) {
                    ForEach(appState.destinationStore.destinations) { destination in
                        Text(verbatim: destination.name).tag(UUID?.some(destination.id))
                    }
                }
                if let destination, !ShortKeys.usesConditionalWrites(destination.preset) {
                    Label("On this provider a request link is meant for one sender.", systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Title", text: $title, prompt: Text("Optional"))
                    .onChange(of: title) { _, value in
                        if value.count > FileRequests.maxTitleLength { title = String(value.prefix(FileRequests.maxTitleLength)) }
                    }
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: note) { _, value in
                        if value.count > FileRequests.maxNoteLength { note = String(value.prefix(FileRequests.maxNoteLength)) }
                    }
            }
            Section {
                Picker("Valid for", selection: $duration) {
                    ForEach(FileRequests.durations, id: \.self) { seconds in
                        Text(FileRequests.durationLabel(seconds)).tag(seconds)
                    }
                }
                Picker("Up to", selection: $slots) {
                    ForEach(FileRequests.slotOptions, id: \.self) { count in
                        Text(count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")).tag(count)
                    }
                }
                Picker("Size limit per file", selection: $maxBytes) {
                    ForEach(FileRequests.sizeOptions, id: \.self) { bytes in
                        Text(FileRequests.sizeLabel(bytes)).tag(bytes)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anyone with the link can send files until it expires.")
                    Text("The size limit is checked by the page, not by the bucket: a determined sender could still send up to 5 GB per file. The number of files and the short lifetime keep that bounded.")
                    Text("Files sent while Aktar isn\u{2019}t running wait in the bucket until it runs again.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let corsRule {
                        Text(verbatim: corsRule.json)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button("Copy Rule") { ClipboardService.copy(corsRule.json) }
                            Button("I Added the Rule") { create(corsDoneByHand: true) }
                                .help("Create the link anyway, for a rule added in the provider\u{2019}s dashboard.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func create(corsDoneByHand: Bool) {
        guard let destination else { return }
        isCreating = true
        error = nil
        corsRule = nil
        let draft = FileRequestService.Draft(destination: destination, title: title, note: note, duration: duration, slots: slots, maxBytes: maxBytes)
        Task {
            defer { isCreating = false }
            do {
                let request = try await appState.fileRequests.create(draft, corsDoneByHand: corsDoneByHand)
                ClipboardService.copy(request.link)
                created = request
            } catch let failure as FileRequestService.CreateError {
                error = failure.errorDescription
                if case .cors(let origin, _) = failure { corsRule = (origin, CORSXML.ruleJSON(origin: origin)) }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The new request's link, copied, with Copy and QR.
private struct RequestCreatedView: View {
    let request: FileRequest
    @State private var justCopied = false

    var body: some View {
        Form {
            Section {
                Label("Link copied", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Text(verbatim: request.link)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        ClipboardService.copy(request.link)
                        justCopied = true
                    } label: {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    }
                    .help("Copy Link")
                    Button {
                        if let url = URL(string: request.link) {
                            QRCodeWindowController.shared.show(link: url, filename: request.title.isEmpty ? "Request" : request.title)
                        }
                    } label: {
                        Image(systemName: "qrcode")
                    }
                    .help("Show QR Code")
                }
                .buttonStyle(.plain)
                Text("Open until \(request.expiresAt.formatted(date: .abbreviated, time: .shortened)). Files that arrive show up in the Library, under Requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// The "Request Files" window, from the menu bar panel. One at a time.
@MainActor
final class RequestFilesWindowController: NSObject, NSWindowDelegate {
    static let shared = RequestFilesWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        NotificationCenter.default.post(name: .aktarClosePanel, object: nil)
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = RequestFilesView { [weak self] in self?.window?.close() }.environment(appState)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = String(localized: "Request Files")
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}
