import AppKit
import SwiftUI

/// The Library's "Requests": file requests made on this Mac, open ones
/// first, with what they brought in.
struct RequestsListView: View {
    @Binding var selection: String?
    @Environment(AppState.self) private var appState
    @State private var isCreating = false

    var body: some View {
        let requests = appState.fileRequests.store.requests
        Group {
            if requests.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No requests yet").font(.headline)
                    Text("Make a link others can send files to, straight into your bucket.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Request Files\u{2026}") { isCreating = true }
                        .disabled(!appState.destinationStore.destinations.contains { $0.capabilities.fileRequests })
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(requests.filter(\.isOpen) + requests.filter { !$0.isOpen }) { request in
                        RequestRow(request: request)
                            .tag(request.id)
                    }
                }
            }
        }
        .navigationTitle("Requests")
        .toolbar {
            ToolbarItem {
                Button("Request Files\u{2026}", systemImage: "plus") { isCreating = true }
                    .disabled(!appState.destinationStore.destinations.contains { $0.capabilities.fileRequests })
            }
        }
        .sheet(isPresented: $isCreating) {
            RequestFilesView { isCreating = false }
        }
    }
}

private struct RequestRow: View {
    let request: FileRequest
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: request.title.isEmpty ? String(localized: "Request") : request.title)
                .lineLimit(1)
            Text(RequestStatus.line(request, destinationName: destinationName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var destinationName: String {
        appState.destinationStore.destinations.first { $0.id == request.destinationId }?.name ?? ""
    }
}

enum RequestStatus {
    static func label(_ request: FileRequest, now: Date = .now) -> String {
        if request.closedAt != nil { return String(localized: "Closed") }
        if request.isExpired(now: now) { return String(localized: "Expired") }
        return String(localized: "Open until \(request.expiresAt.formatted(date: .abbreviated, time: .shortened))")
    }

    static func received(_ request: FileRequest) -> String {
        request.received == 1 ? String(localized: "1 file received") : String(localized: "\(request.received) files received")
    }

    static func line(_ request: FileRequest, destinationName: String) -> String {
        [destinationName, label(request), received(request)].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

/// One request: its link (Copy, QR), what came in, Check Now and Close Now.
struct RequestDetailView: View {
    let requestID: String
    @Environment(AppState.self) private var appState
    @State private var error: String?
    @State private var isClosing = false
    @State private var lastCheck: Int?
    @State private var isConfirmingClose = false

    private var service: FileRequestService { appState.fileRequests }
    private var request: FileRequest? { service.store.request(id: requestID) }

    var body: some View {
        if let request {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: request.title.isEmpty ? String(localized: "Request") : request.title)
                            .font(.title3.bold())
                        Text(RequestStatus.label(request))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !request.note.isEmpty {
                        Text(verbatim: request.note)
                            .textSelection(.enabled)
                    }
                    linkSection(request)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Details").font(.subheadline.bold()).foregroundStyle(.secondary)
                        DetailRow(label: "Destination", value: appState.destinationStore.destinations.first { $0.id == request.destinationId }?.name ?? "")
                        DetailRow(label: "Received", value: RequestStatus.received(request))
                        DetailRow(label: "Up to", value: request.slotCount == 1 ? String(localized: "1 file") : String(localized: "\(request.slotCount) files"))
                        DetailRow(label: "Size limit per file", value: FileRequests.sizeLabel(request.maxBytes))
                        DetailRow(label: "Created", value: request.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let closedAt = request.closedAt {
                            DetailRow(label: "Closed", value: closedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if request.isOpen {
                        HStack {
                            Button(service.checking.contains(request.id) ? LocalizedStringKey("Checking\u{2026}") : LocalizedStringKey("Check Now")) {
                                Task { lastCheck = await service.check(request) }
                            }
                            .disabled(service.checking.contains(request.id))
                            Button("Close Now\u{2026}", role: .destructive) { isConfirmingClose = true }
                                .disabled(isClosing)
                        }
                        if let lastCheck {
                            Text(lastCheck == 0 ? String(localized: "Nothing new.") : lastCheck == 1 ? String(localized: "Received 1 file") : String(localized: "Received \(lastCheck) files"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Remove from List") { service.remove(request) }
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .confirmationDialog("Close this request?", isPresented: $isConfirmingClose) {
                Button("Close Now", role: .destructive) { close(request) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The link stops working right away, and files that haven\u{2019}t been collected yet are deleted.")
            }
        } else {
            Text("No Request Selected")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func linkSection(_ request: FileRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link").font(.subheadline.bold()).foregroundStyle(.secondary)
            HStack {
                Text(verbatim: request.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    ClipboardService.copy(request.link)
                } label: {
                    Image(systemName: "doc.on.doc")
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
            .disabled(!request.isOpen)
        }
    }

    private func close(_ request: FileRequest) {
        isClosing = true
        error = nil
        Task {
            defer { isClosing = false }
            do {
                try await service.close(request)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
