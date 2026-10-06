import AppKit
import SwiftData
import SwiftUI

/// The short links of an upload in its details: the active one with its
/// clicks (fetched when the details open, and cached), Create Short Link
/// when there's none, and older ones with their status.
struct ShortLinkSection: View {
    let record: UploadRecord

    @Environment(AppState.self) private var appState
    @Query private var links: [ShortLink]
    @State private var isWorking = false
    @State private var error: String?
    @State private var justCopied = false

    init(record: UploadRecord) {
        self.record = record
        let id = record.id
        _links = Query(filter: #Predicate<ShortLink> { $0.uploadID == id }, sort: \.createdAt, order: .reverse)
    }

    private var service: ShortLinkService { appState.uploadManager.shortLinks }
    private var active: ShortLink? { ShortLinkRules.active(links) }
    private var older: [ShortLink] { links.filter { $0.id != active?.id && $0.status != .deleted } }

    var body: some View {
        if active != nil || !older.isEmpty || service.canCreate(for: record) || error != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Short Link").font(.subheadline.bold()).foregroundStyle(.secondary)
                if let active {
                    activeRow(active)
                    if let stats = statsLine(active) {
                        Text(stats).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if service.canCreate(for: record) {
                    Button(isWorking ? LocalizedStringKey("Creating\u{2026}") : LocalizedStringKey("Create Short Link")) { create() }
                        .disabled(isWorking)
                        .controlSize(.small)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !older.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Earlier Short Links").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(older) { link in olderRow(link) }
                    }
                    .padding(.top, 4)
                }
            }
            .task(id: active?.id) {
                if let active { await service.refreshStats(active) }
            }
        }
    }

    private func activeRow(_ link: ShortLink) -> some View {
        HStack {
            Text(link.shortUrl)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(link.shortUrl)
            Spacer(minLength: 8)
            Button {
                ClipboardService.copy(link.shortUrl)
                justCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy Short Link")
            Button {
                deleteLink(link)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Short Link")
            .disabled(isWorking)
        }
        .buttonStyle(.plain)
    }

    private func olderRow(_ link: ShortLink) -> some View {
        HStack(spacing: 6) {
            Text(link.shortUrl)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(link.shortUrl)
            ShortLinkStatusBadge(status: link.displayStatus)
            Spacer(minLength: 8)
            Button {
                ClipboardService.copy(link.shortUrl)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy Short Link")
            if link.status != .deleted {
                Button {
                    deleteLink(link)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete Short Link")
                .disabled(isWorking)
            }
        }
        .font(.callout)
    }

    /// "Clicks: 12 · Last clicked 2 hours ago".
    private func statsLine(_ link: ShortLink) -> String? {
        guard service.hasStats(link) else { return nil }
        var parts: [String] = []
        if let clicks = link.clicks { parts.append(String(localized: "Clicks: \(clicks)")) }
        if let last = link.lastClickAt {
            parts.append(String(localized: "Last clicked \(last.formatted(.relative(presentation: .named)))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private func create() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await appState.uploadManager.createShortLink(for: record)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func deleteLink(_ link: ShortLink) {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await service.delete(link)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Orphaned, unknown and expired short links say so.
struct ShortLinkStatusBadge: View {
    let status: ShortLinkStatus

    var body: some View {
        switch status {
        case .active:
            EmptyView()
        case .expired:
            badge("Expired", color: .secondary, help: "The upload or its temporary link expired.")
        case .deleted:
            badge("Deleted", color: .secondary, help: "Deleted at the link shortener.")
        case .orphaned:
            badge("May still exist", color: .orange, help: "Short link may still exist")
        case .unknown:
            badge("Not updated", color: .orange, help: "Its target couldn\u{2019}t be updated, so it may still point to the old location.")
        }
    }

    private func badge(_ title: LocalizedStringKey, color: Color, help: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5)))
            .help(help)
    }
}

/// Copy Short Link, Copy Original Link, Create Short Link and Delete Short
/// Link for an upload's context menus. Read when the menu opens.
struct RecordShortLinkMenuItems: View {
    let record: UploadRecord
    @Environment(AppState.self) private var appState

    var body: some View {
        let service = appState.uploadManager.shortLinks
        if let active = service.active(for: record.id) {
            Button("Copy Short Link") { ClipboardService.copy(active.shortUrl) }
            Button("Copy Original Link") { ClipboardService.copy(record.publicURLString) }
        } else {
            Button("Copy URL") { ClipboardService.copy(record.publicURLString) }
        }
        if service.canCreate(for: record) {
            Button("Create Short Link") {
                Task { await appState.uploadManager.retryShortLink(uploadID: record.id) }
            }
        }
        if let active = service.active(for: record.id) {
            Button("Delete Short Link") {
                Task {
                    do {
                        try await service.delete(active)
                    } catch {
                        NSSound.beep()
                    }
                }
            }
        }
    }
}
