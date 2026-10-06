import SwiftUI
import AppKit
import ImageIO
import PDFKit
import SwiftData
import UniformTypeIdentifiers

/// What the Library window's source list is showing: Aktar's own upload
/// history, or a live view of one destination's bucket.
private enum LibrarySource: Hashable {
    case history
    case bucket(UUID)
}

/// Keeps one browser per destination alive while the window is open, so
/// switching between buckets returns to the folder you were in. A plain
/// class rather than state, since it's filled lazily while rendering.
@MainActor
private final class BucketBrowserCache {
    private var models: [UUID: BucketBrowserModel] = [:]

    func model(for destination: DestinationConfig, store: DestinationStore) -> BucketBrowserModel {
        // Which destination is the default doesn't affect the browser, so
        // changing it keeps you in the folder you were in.
        if let model = models[destination.id] {
            var current = model.destination
            current.isDefault = destination.isDefault
            if current == destination { return model }
        }
        let model = BucketBrowserModel(destination: destination) { [weak store] in
            ThumbnailKeys.bucketPrefixes(for: destination, among: store?.destinations ?? [])
        }
        models[destination.id] = model
        return model
    }
}

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \UploadRecord.createdAt, order: .reverse) private var records: [UploadRecord]
    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var destinationFilter: UUID?
    @State private var sourceFilter: SourceFilter?
    @State private var recordsPendingDeletion: [UploadRecord] = []
    @State private var deletionInFlight: Set<UUID> = []
    @State private var deletionErrors: [UUID: String] = [:]
    @State private var zoomedRecord: UploadRecord?
    @State private var isDropTargeted = false
    @State private var source: LibrarySource? = .history
    @State private var browserCache = BucketBrowserCache()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sourceList
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            Group {
                if let browser = currentBrowser {
                    BucketListView(model: browser)
                } else {
                    sidebar
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let browser = currentBrowser {
                BucketDetailView(model: browser)
            } else {
                detail
            }
        }
        .frame(minWidth: 860, minHeight: 500)
        .background(hiddenShortcuts)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                dropOverlay.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .sheet(item: $zoomedRecord) { record in
            ZoomedPreviewView(record: record) { zoomedRecord = nil }
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { !recordsPendingDeletion.isEmpty },
                set: { if !$0 { recordsPendingDeletion = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) { recordsPendingDeletion = [] }
            Button(
                recordsPendingDeletion.count > 1 ? LocalizedStringKey("Delete Remote Files") : LocalizedStringKey("Delete Remote File"),
                role: .destructive
            ) {
                let targets = recordsPendingDeletion
                recordsPendingDeletion = []
                Task { await deleteRemote(targets) }
            }
        } message: {
            Text(deleteAlertMessage)
        }
    }

    // MARK: - Source list

    private var sourceList: some View {
        List(selection: $source) {
            Section("Library") {
                Label("History", systemImage: "clock")
                    .tag(LibrarySource.history)
            }
            if !appState.destinationStore.destinations.isEmpty {
                Section("Buckets") {
                    ForEach(appState.destinationStore.destinations) { destination in
                        Label {
                            Text(verbatim: destination.name)
                        } icon: {
                            Image(systemName: destination.preset.symbolName)
                        }
                        .help(destination.bucket)
                        .tag(LibrarySource.bucket(destination.id))
                    }
                }
            }
        }
        .onChange(of: appState.destinationStore.destinations) { _, destinations in
            if case .bucket(let id) = source, !destinations.contains(where: { $0.id == id }) {
                source = .history
            }
        }
    }

    private var currentBrowser: BucketBrowserModel? {
        guard case .bucket(let id) = source,
              let destination = appState.destinationStore.destinations.first(where: { $0.id == id }) else { return nil }
        return browserCache.model(for: destination, store: appState.destinationStore)
    }

    // MARK: - History

    @ViewBuilder
    private var sidebar: some View {
        Group {
            if records.isEmpty && activeJobs.isEmpty {
                EmptyLibraryView { chooseAndUpload() }
            } else {
                sidebarList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button("Upload", systemImage: "plus") { chooseAndUpload() }
            }
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        let list = listBody
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search uploads")
            .onAppear { selectFirstIfNeeded() }
            .onChange(of: records.map(\.id)) { selectFirstIfNeeded() }

        if #available(macOS 15, *) {
            list.searchFocused($isSearchFocused)
        } else {
            list
        }
    }

    private var listBody: some View {
        List(selection: $selectedIDs) {
            ForEach(activeJobs) { job in
                ActiveUploadRow(job: job)
                    .selectionDisabled()
            }
            if availableDestinations.count > 1 || !availableWatchedFolders.isEmpty {
                filterRow
                    .selectionDisabled()
            }
            if filteredRecords.isEmpty {
                NoSearchResultsRow { searchText = "" }
                    .selectionDisabled()
            } else {
                ForEach(groupedSections) { section in
                    if section.title.isEmpty {
                        ForEach(section.records) { record in row(for: record) }
                    } else {
                        Section(section.title) {
                            ForEach(section.records) { record in row(for: record) }
                        }
                    }
                }
            }
        }
        // macOS List sometimes keeps a newly inserted row (like the first
        // upload of the day, which also adds the "Today" section) at the
        // default single-line height, clipping the thumbnail and subtitle.
        // Rows here are all 48pt, so make that the floor.
        .environment(\.defaultMinListRowHeight, 48)
    }

    private func row(for record: UploadRecord) -> some View {
        LibraryRowView(
            record: record,
            isDeleting: deletionInFlight.contains(record.id),
            subtitle: rowSubtitle(record)
        )
        .contextMenu { contextMenuContent(for: record) }
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            Spacer()
            if !availableWatchedFolders.isEmpty {
                Menu(sourceFilterLabel) {
                    Button("All Sources") { sourceFilter = nil }
                    Button("Watched Folders") { sourceFilter = .watched }
                    Divider()
                    ForEach(availableWatchedFolders, id: \.id) { folder in
                        Button(folder.name) { sourceFilter = .folder(folder.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()
            }
            if availableDestinations.count > 1 {
                Menu(destinationFilterLabel) {
                    Button("All Destinations") { destinationFilter = nil }
                    Divider()
                    ForEach(availableDestinations, id: \.id) { destination in
                        Button(destination.name) { destinationFilter = destination.id }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()
            }
        }
        .listRowSeparator(.hidden)
    }

    /// Uploads from watched folders, all or one.
    private enum SourceFilter: Equatable {
        case watched
        case folder(UUID)
    }

    private var sourceFilterLabel: String {
        switch sourceFilter {
        case nil:
            return String(localized: "Source: All")
        case .watched:
            return String(localized: "Source: Watched Folders")
        case .folder(let id):
            let name = availableWatchedFolders.first { $0.id == id }?.name ?? ""
            return String(localized: "Source: \(name)")
        }
    }

    private var availableWatchedFolders: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        var result: [(id: UUID, name: String)] = []
        for record in records {
            guard let id = record.watchedFolderID, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append((id, record.watchedFolderName ?? ""))
        }
        return result
    }

    private var destinationFilterLabel: String {
        guard let destinationFilter,
              let match = availableDestinations.first(where: { $0.id == destinationFilter }) else {
            return String(localized: "Destination: All")
        }
        return String(localized: "Destination: \(match.name)")
    }

    @ViewBuilder
    private func contextMenuContent(for record: UploadRecord) -> some View {
        let targets = selectionTargets(for: record)
        if targets.count > 1 {
            Button("Copy \(targets.count) URLs") {
                ClipboardService.copy(targets.map(\.publicURLString).joined(separator: "\n"))
            }
            Button("Copy \(targets.count) as Markdown") {
                ClipboardService.copy(targets.map { markdown(for: $0) }.joined(separator: "\n"))
            }
            Divider()
            Button("Delete \(targets.count) Remote Files\u{2026}", role: .destructive) {
                recordsPendingDeletion = targets
            }
        } else {
            RecordShortLinkMenuItems(record: record)
            Button("Copy Markdown") { ClipboardService.copy(appState.uploadManager.formattedLink(for: record, mode: .markdown)) }
            Button("Copy HTML") { ClipboardService.copy(appState.uploadManager.formattedLink(for: record, mode: .html)) }
            RecordTemporaryLinkMenu(record: record)
            Button("Show QR Code") {
                QRCodeWindowController.shared.show(for: record, uploadManager: appState.uploadManager)
            }
            Divider()
            Button("Open in Browser") {
                if let url = record.publicURL { NSWorkspace.shared.open(url) }
            }
            Button("Reveal Details") { selectedIDs = [record.id] }
            Divider()
            Button("Replace File\u{2026}") { ReplaceFile.replace(record, using: appState.uploadManager) }
            Divider()
            Button("Delete Remote File\u{2026}", role: .destructive) { recordsPendingDeletion = [record] }
            Button("Remove from History", role: .destructive) {
                appState.uploadManager.removeFromHistory(record)
                selectedIDs.remove(record.id)
            }
        }
    }

    /// A right-click on a row that's part of the current multi-selection
    /// acts on the whole selection; a right-click elsewhere acts on just
    /// that row.
    private func selectionTargets(for record: UploadRecord) -> [UploadRecord] {
        guard selectedIDs.contains(record.id), selectedIDs.count > 1 else { return [record] }
        return filteredRecords.filter { selectedIDs.contains($0.id) }
    }

    private func markdown(for record: UploadRecord) -> String {
        appState.uploadManager.formattedLink(for: record, mode: .markdown)
    }


    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let selectedRecords = records.filter { selectedIDs.contains($0.id) }
        if selectedRecords.count > 1 {
            MultiSelectionDetailView(records: selectedRecords) {
                recordsPendingDeletion = selectedRecords
            }
        } else if let record = selectedRecords.first {
            UploadDetailView(
                record: record,
                isDeleting: deletionInFlight.contains(record.id),
                deletionError: deletionErrors[record.id],
                requestZoom: { zoomedRecord = record },
                requestRemoteDeletion: { recordsPendingDeletion = [record] },
                retryDeletion: { Task { await deleteRemote([record]) } },
                removeFromHistory: {
                    appState.uploadManager.removeFromHistory(record)
                    selectedIDs.remove(record.id)
                }
            )
            .id(record.id)
        } else if records.isEmpty {
            EmptyLibraryView { chooseAndUpload() }
        } else {
            NoSelectionView()
        }
    }

    // MARK: - Data

    private struct RecordSection: Identifiable {
        let id: String
        let title: String
        let records: [UploadRecord]
    }

    private var groupedSections: [RecordSection] {
        let source = filteredRecords
        guard source.count > 1 else {
            return source.isEmpty ? [] : [RecordSection(id: "all", title: "", records: source)]
        }

        var order: [String] = []
        var titles: [String: String] = [:]
        var buckets: [String: [UploadRecord]] = [:]
        let calendar = Calendar.current

        for record in source {
            let key: String
            let title: String
            if calendar.isDateInToday(record.createdAt) {
                key = "today"; title = String(localized: "Today")
            } else if calendar.isDateInYesterday(record.createdAt) {
                key = "yesterday"; title = String(localized: "Yesterday")
            } else {
                let day = calendar.startOfDay(for: record.createdAt)
                key = ISO8601DateFormatter().string(from: day)
                let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: .now)
                title = sameYear
                    ? day.formatted(.dateTime.month(.wide).day())
                    : day.formatted(.dateTime.month(.wide).day().year())
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
                titles[key] = title
            }
            buckets[key]?.append(record)
        }

        return order.map { RecordSection(id: $0, title: titles[$0] ?? "", records: buckets[$0] ?? []) }
    }

    private var availableDestinations: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        var result: [(id: UUID, name: String)] = []
        for record in records where !seen.contains(record.destinationID) {
            seen.insert(record.destinationID)
            result.append((record.destinationID, record.destinationName))
        }
        return result
    }

    private var filteredRecords: [UploadRecord] {
        var result = records
        if let destinationFilter {
            result = result.filter { $0.destinationID == destinationFilter }
        }
        switch sourceFilter {
        case .watched: result = result.filter { $0.watchedFolderID != nil }
        case .folder(let id): result = result.filter { $0.watchedFolderID == id }
        case nil: break
        }
        guard !searchText.isEmpty else { return result }
        return result.filter {
            $0.localFilename.localizedCaseInsensitiveContains(searchText)
                || $0.publicURLString.localizedCaseInsensitiveContains(searchText)
                || $0.objectKey.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Cancelled jobs stay for a moment so the row can say so.
    private var activeJobs: [UploadJob] {
        appState.uploadManager.jobs.filter {
            switch $0.state {
            case .waiting, .uploading, .failed, .cancelled: return true
            case .succeeded: return false
            }
        }
    }

    private func rowSubtitle(_ record: UploadRecord) -> String {
        let time = record.createdAt.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(record.createdAt) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(record.createdAt) {
            day = String(localized: "Yesterday")
        } else {
            day = record.createdAt.formatted(.dateTime.month(.abbreviated).day())
        }
        if let source = record.sourceLabel {
            return "\(record.destinationName) \u{00B7} \(source) \u{00B7} \(day), \(time)"
        }
        return "\(record.destinationName) \u{00B7} \(day), \(time)"
    }

    private func selectFirstIfNeeded() {
        guard selectedIDs.isEmpty, let first = filteredRecords.first else { return }
        selectedIDs = [first.id]
    }

    // MARK: - Actions

    private var hiddenShortcuts: some View {
        Group {
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: [.command])
            Button("") {
                if let record = records.first(where: { selectedIDs == [$0.id] }) {
                    ClipboardService.copy(record.publicURLString)
                }
            }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(isSearchFocused || selectedIDs.count != 1)
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    private func chooseAndUpload() {
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

    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(12)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Release to upload").font(.title3.bold())
            }
        }
        .allowsHitTesting(false)
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
            guard !inputs.isEmpty else { return }
            if let browser = currentBrowser {
                browser.upload(inputs.map(\.fileURL), source: .dragDrop, using: appState.uploadManager)
            } else {
                appState.uploadManager.upload(inputs)
            }
        }
        return true
    }

    private var deleteAlertTitle: String {
        if recordsPendingDeletion.count > 1 {
            return String(localized: "Delete \(recordsPendingDeletion.count) files?")
        }
        if let record = recordsPendingDeletion.first {
            return String(localized: "Delete \u{201C}\(record.localFilename)\u{201D} from \(record.destinationName)?")
        }
        return ""
    }

    private var deleteAlertMessage: String {
        if recordsPendingDeletion.count > 1 {
            return String(localized: "The remote files will be removed and their links may stop working. This can\u{2019}t be undone.")
        }
        if let record = recordsPendingDeletion.first, appState.uploadManager.isSuperseded(record) {
            return String(localized: "A newer upload has the same name in the bucket, so only this history entry is removed. The file stays.")
        }
        return String(localized: "The remote file will be removed and its link may stop working. This can\u{2019}t be undone.")
    }

    private func deleteRemote(_ recordsToDelete: [UploadRecord]) async {
        let preDeletionList = filteredRecords
        let anchorIndex = recordsToDelete.count == 1
            ? preDeletionList.firstIndex(where: { $0.id == recordsToDelete[0].id })
            : nil

        for record in recordsToDelete {
            deletionInFlight.insert(record.id)
            deletionErrors[record.id] = nil
            do {
                try await appState.uploadManager.deleteRemote(record)
                selectedIDs.remove(record.id)
            } catch {
                deletionErrors[record.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            deletionInFlight.remove(record.id)
        }

        guard recordsToDelete.count == 1, deletionErrors[recordsToDelete[0].id] == nil, let anchorIndex else { return }
        let remaining = preDeletionList.filter { $0.id != recordsToDelete[0].id }
        guard !remaining.isEmpty else { return }
        let nextIndex = min(anchorIndex, remaining.count - 1)
        selectedIDs = [remaining[nextIndex].id]
    }
}

// MARK: - Sidebar rows

private struct LibraryRowView: View {
    let record: UploadRecord
    let isDeleting: Bool
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            LibraryThumbnail(record: record, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.localFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(record.localFilename)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let expiresAt = record.expiresAt {
                        Label(UploadExpiry.deletionLabel(for: expiresAt), systemImage: "timer")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption)
            }
            if isDeleting {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .opacity(isDeleting ? 0.6 : 1)
        .padding(.vertical, 2)
    }
}

private struct ActiveUploadRow: View {
    let job: UploadJob
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: FileKindIcon.symbolName(for: job.input.originalFilename))
                        .foregroundStyle(.secondary)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(job.input.originalFilename).lineLimit(1)
                if let folderName = job.input.watch?.folderName {
                    Text("Watched: \(folderName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                switch job.state {
                case .uploading(let progress):
                    ProgressView(value: progress)
                    if job.resuming {
                        Text("Resuming upload\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                case .waiting:
                    Text("Waiting\u{2026}").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    HStack(spacing: 6) {
                        Text(message).font(.caption2).foregroundStyle(.red).lineLimit(1)
                        Button("Retry") { appState.uploadManager.retry(job) }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .succeeded:
                    EmptyView()
                }
            }
            switch job.state {
            case .waiting, .uploading, .failed:
                Button {
                    appState.uploadManager.cancel(job)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
            case .succeeded, .cancelled:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NoSearchResultsRow: View {
    let clearSearch: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("No matching uploads").foregroundStyle(.secondary)
            Button("Clear Search", action: clearSearch)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }
}

/// Square, `aspectFit` thumbnail on a faint checkerboard so transparent PNGs
/// stay legible; falls back to a file-kind glyph (based on the extension)
/// for files with no thumbnail (yet). One this Mac doesn't have is looked
/// for once the row shows; see `RemoteThumbnailLoader`.
private struct LibraryThumbnail: View {
    @Environment(AppState.self) private var appState
    let record: UploadRecord
    let size: CGFloat

    var body: some View {
        ZStack {
            if let thumb = ThumbnailStore.shared.image(for: record.id) {
                CheckerboardBackground()
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.secondary.opacity(0.08)
                Image(systemName: FileKindIcon.symbolName(for: record.localFilename))
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .task(id: record.id) {
            guard let destination = appState.destinationStore.destinations.first(where: { $0.id == record.destinationID }) else { return }
            await RemoteThumbnailLoader.shared.loadThumbnail(for: record, destination: destination)
        }
    }
}

/// A drop-in replacement for `AsyncImage` with an explicit request timeout,
/// so a stalled connection resolves to `.failure` instead of spinning
/// forever, and `URLCache.shared` reuse so a preview already loaded
/// elsewhere in the app shows up instantly here too.
enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct RemoteImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase: RemoteImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        phase = .empty
        guard let url else { phase = .failure; return }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                phase = .failure
                return
            }
            // A photo too large to decode safely isn't previewed.
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
               let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
               ImagePixelLimit.isTooLarge(width: width, height: height) {
                phase = .failure
                return
            }
            guard let nsImage = NSImage(data: data) else {
                phase = .failure
                return
            }
            phase = .success(Image(nsImage: nsImage))
        } catch {
            phase = .failure
        }
    }
}

/// Downloads a remote file's raw bytes for preview (PDF, text, markdown).
/// The original upload isn't kept locally, so this fetches on demand each
/// time a non-image detail is viewed. Files over `maxBytes` aren't
/// previewed: `knownSize` (history's or the listing's size) turns them away
/// before anything is downloaded, and the download stops once it gets past
/// the limit anyway. Nothing is cached on disk, and a redirect to another
/// host isn't followed.
enum RemoteFilePhase {
    case loading
    case success(Data)
    case failure
    case tooLarge
}

struct RemoteFileLoader<Content: View>: View {
    static var maxBytes: Int64 { 25 * 1024 * 1024 }

    let url: URL?
    var knownSize: Int64? = nil
    @ViewBuilder let content: (RemoteFilePhase) -> Content

    @State private var phase: RemoteFilePhase = .loading

    var body: some View {
        Group {
            if case .tooLarge = phase {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Too large to preview (over 25 MB).").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(phase)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        phase = .loading
        if let knownSize, knownSize > Self.maxBytes {
            phase = .tooLarge
            return
        }
        guard let url else { phase = .failure; return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        do {
            let (bytes, response) = try await PreviewDownload.session.bytes(for: request, delegate: PreviewDownload.SameHostRedirects())
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                phase = .failure
                return
            }
            if response.expectedContentLength > Self.maxBytes {
                phase = .tooLarge
                return
            }
            var data = Data()
            data.reserveCapacity(Int(max(0, min(response.expectedContentLength, Self.maxBytes))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes {
                    phase = .tooLarge
                    return
                }
            }
            phase = .success(data)
        } catch {
            phase = .failure
        }
    }
}

/// The connection previews download through: nothing cached, in memory or
/// on disk.
enum PreviewDownload {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// Follows a redirect only to the same host.
    final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let from = task.originalRequest?.url?.host?.lowercased()
            let to = request.url?.host?.lowercased()
            completionHandler(from != nil && from == to ? request : nil)
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = PDFDocument(data: data)
    }
}

struct TextFilePreview: View {
    let data: Data
    let renderMarkdown: Bool

    var body: some View {
        ScrollView {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let text = String(data: data, encoding: .utf8) {
            if renderMarkdown {
                MarkdownBlocksView(blocks: MarkdownParser.parse(text))
            } else {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else {
            Text("Preview unavailable").foregroundStyle(.secondary)
        }
    }
}

/// A minimal Markdown renderer. Foundation's `AttributedString(markdown:)`
/// parses inline styling (bold, links, code spans) fine, but flattening a
/// whole document into one `Text` loses block structure entirely: headings
/// run straight into the next paragraph with no break. This splits the
/// source into blocks by blank lines first, then applies the inline parser
/// within each block, so headings, paragraphs, lists, and code fences each
/// get their own line/style.
private enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(String)
    case codeBlock(String)
    case rule

    var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level)-\(text)"
        case .paragraph(let text): return "p-\(text)"
        case .listItem(let text): return "l-\(text)"
        case .codeBlock(let text): return "c-\(text)"
        case .rule: return "r-\(UUID().uuidString)"
        }
    }
}

private enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphLines.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            if codeLines != nil {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.codeBlock(codeLines!.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines!.append(rawLine)
                }
                continue
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                codeLines = []
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = min(trimmed.prefix { $0 == "#" }.count, 6)
                let rest = trimmed.dropFirst(level)
                if rest.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.listItem(String(trimmed.dropFirst(2))))
                continue
            }

            paragraphLines.append(trimmed)
        }
        flushParagraph()
        if let codeLines { blocks.append(.codeBlock(codeLines.joined(separator: "\n"))) }
        return blocks
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inlineText(text)
        case .listItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: "\u{2022}")
                inlineText(text)
            }
        case .codeBlock(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    private func inlineText(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: raw, options: options) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = max(size.width / 8, 4)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: step, height: step)),
                            with: .color(.secondary.opacity(0.12))
                        )
                    }
                    x += step
                    col += 1
                }
                y += step
                row += 1
            }
        }
        .background(Color.secondary.opacity(0.06))
    }
}

// MARK: - Empty / placeholder states

private struct EmptyLibraryView: View {
    let upload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Your uploads will appear here")
                .font(.title3.bold())
            Button("Upload File\u{2026}", action: upload)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoSelectionView: View {
    var body: some View {
        Text("Select an upload to view its details")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Single selection detail

private struct UploadDetailView: View {
    let record: UploadRecord
    let isDeleting: Bool
    let deletionError: String?
    let requestZoom: () -> Void
    let requestRemoteDeletion: () -> Void
    let retryDeletion: () -> Void
    let removeFromHistory: () -> Void

    @State private var justCopiedURL = false
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                preview
                if let deletionError {
                    deletionErrorBanner(deletionError)
                }
                linkSection
                ShortLinkSection(record: record)
                detailsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .toolbar { toolbarContent }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.localFilename).font(.title3.bold())
            Text("\(record.destinationName) \u{00B7} Uploaded \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private enum PreviewKind {
        case image
        case pdf
        case text(markdown: Bool)
        /// A video or audio file AVFoundation can play.
        case media
        case unsupported
    }

    private var previewKind: PreviewKind {
        if record.mimeType.hasPrefix("image/") { return .image }
        if record.mimeType == "application/pdf" { return .pdf }
        let ext = (record.localFilename as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return .text(markdown: true) }
        let textExtensions: Set<String> = ["txt", "json", "yml", "yaml", "swift", "js", "ts", "py", "log", "csv", "xml", "html", "css"]
        if record.mimeType.hasPrefix("text/") || textExtensions.contains(ext) {
            return .text(markdown: false)
        }
        if MediaPreview.canPlay(filename: record.localFilename) { return .media }
        return .unsupported
    }

    @ViewBuilder
    private var preview: some View {
        switch previewKind {
        case .image:
            Button(action: requestZoom) {
                ZStack {
                    CheckerboardBackground()
                    RemoteImage(url: record.publicURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fit)
                        case .failure:
                            brokenPreview
                        case .empty:
                            if let thumb = ThumbnailStore.shared.image(for: record.id) {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .opacity(0.6)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .pdf:
            RemoteFileLoader(url: record.publicURL, knownSize: Int64(record.byteSize)) { phase in
                switch phase {
                case .success(let data):
                    PDFKitView(data: data)
                case .failure, .tooLarge:
                    brokenPreview
                case .loading:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .text(let markdown):
            RemoteFileLoader(url: record.publicURL, knownSize: Int64(record.byteSize)) { phase in
                switch phase {
                case .success(let data):
                    TextFilePreview(data: data, renderMarkdown: markdown)
                case .failure, .tooLarge:
                    brokenPreview
                case .loading:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .media:
            MediaPreview(filename: record.localFilename, poster: ThumbnailStore.shared.image(for: record.id)) {
                // Presigned, so a private bucket plays too.
                (try? await appState.uploadManager.temporaryURL(for: record, validFor: .hour)) ?? record.publicURL
            }
            .id(record.id)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .unsupported:
            fileKindPreview
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var fileKindPreview: some View {
        Button {
            if let url = record.publicURL { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 10) {
                // A video's frame, a document's first page and the like.
                if let thumb = ThumbnailStore.shared.image(for: record.id) {
                    // At most half its pixel size (Retina), so it's never
                    // blurry from being scaled up.
                    let pixels = thumb.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? thumb.size
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: pixels.width / 2, maxHeight: min(240, pixels.height / 2))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                } else {
                    Image(systemName: FileKindIcon.symbolName(for: record.localFilename))
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                }
                Text("Open in Browser").font(.caption).foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06))
        }
        .buttonStyle(.plain)
    }

    private var brokenPreview: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
            Button("Open in Browser") {
                if let url = record.publicURL { NSWorkspace.shared.open(url) }
            }
            .font(.caption)
        }
    }

    private func deletionErrorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button("Try Again", action: retryDeletion)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Link").font(.subheadline.bold()).foregroundStyle(.secondary)
            HStack {
                Text(record.publicURLString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(record.publicURLString)
                Spacer(minLength: 8)
                Button {
                    copyURL()
                } label: {
                    Image(systemName: justCopiedURL ? "checkmark" : "doc.on.doc")
                }
                .help("Copy URL")
                Button {
                    QRCodeWindowController.shared.show(for: record, uploadManager: appState.uploadManager)
                } label: {
                    Image(systemName: "qrcode")
                }
                .help("Show QR Code")
                Button {
                    if let url = record.publicURL { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open in Browser")
            }
            .buttonStyle(.plain)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Destination", value: record.destinationName)
                if let source = record.sourceLabel {
                    DetailRow(label: "Source", value: source)
                }
                DetailRow(
                    label: "File size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(record.byteSize), countStyle: .file)
                )
                DetailRow(
                    label: "Uploaded",
                    value: record.createdAt.formatted(date: .abbreviated, time: .shortened),
                    tooltip: record.createdAt.formatted(date: .complete, time: .standard)
                )
                if let replacedAt = record.replacedAt {
                    DetailRow(
                        label: "Replaced",
                        value: replacedAt.formatted(date: .abbreviated, time: .shortened),
                        tooltip: replacedAt.formatted(date: .complete, time: .standard)
                    )
                }
                if let expiresAt = record.expiresAt {
                    DetailRow(
                        label: "Deletes",
                        value: expiresAt.formatted(date: .abbreviated, time: .shortened),
                        tooltip: expiresAt.formatted(date: .complete, time: .standard)
                    )
                }
            }
        }
    }

    private func copyURL() {
        ClipboardService.copy(record.publicURLString)
        justCopiedURL = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopiedURL = false
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copyURL()
            } label: {
                Label(justCopiedURL ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy URL"), systemImage: justCopiedURL ? "checkmark" : "doc.on.doc")
            }
            Menu {
                // With the short link when the upload has one.
                Menu("Copy As") {
                    Button("Markdown") {
                        ClipboardService.copy(appState.uploadManager.formattedLink(for: record, mode: .markdown))
                    }
                    Button("HTML") {
                        ClipboardService.copy(appState.uploadManager.formattedLink(for: record, mode: .html))
                    }
                    Button("Custom") {
                        ClipboardService.copy(appState.uploadManager.formattedLink(for: record, mode: .custom))
                    }
                }
                RecordShortLinkMenuItems(record: record)
                Button("Copy Object Key") { ClipboardService.copy(record.objectKey) }
                RecordTemporaryLinkMenu(record: record)
                Button("Show QR Code") {
                    QRCodeWindowController.shared.show(for: record, uploadManager: appState.uploadManager)
                }
                Divider()
                Button("Open in Browser") {
                    if let url = record.publicURL { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Replace File\u{2026}") { ReplaceFile.replace(record, using: appState.uploadManager) }
                Divider()
                if isDeleting {
                    Label("Deleting\u{2026}", systemImage: "hourglass")
                } else {
                    Button("Delete Remote File\u{2026}", role: .destructive, action: requestRemoteDeletion)
                }
                Button("Remove from History", role: .destructive, action: removeFromHistory)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String
    var tooltip: String?

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)

        if let tooltip {
            content.help(tooltip)
        } else {
            content
        }
    }
}

// MARK: - Zoomed preview

private struct ZoomedPreviewView: View {
    let record: UploadRecord
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(record.localFilename).font(.headline)
                Spacer()
                Button("Done", action: dismiss)
            }
            .padding()
            RemoteImage(url: record.publicURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    VStack(spacing: 8) {
                        Text("Preview unavailable").foregroundStyle(.secondary)
                        if let url = record.publicURL {
                            Button("Open in Browser") { NSWorkspace.shared.open(url) }
                        }
                    }
                case .empty:
                    if let thumb = ThumbnailStore.shared.image(for: record.id) {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.6)
                    } else {
                        ProgressView()
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 760, minHeight: 360, idealHeight: 600)
    }
}

// MARK: - Multi selection detail

private struct MultiSelectionDetailView: View {
    let records: [UploadRecord]
    let requestRemoteDeletion: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 96), spacing: 12)]

    var body: some View {
        VStack(spacing: 12) {
            Text("\(records.count) items selected").font(.title3.bold())

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(records) { record in
                        VStack(spacing: 4) {
                            LibraryThumbnail(record: record, size: 96)
                            Text(record.localFilename)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 96)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Copy URLs") {
                    ClipboardService.copy(records.map(\.publicURLString).joined(separator: "\n"))
                }
                Button("Copy Markdown") {
                    let lines = records.map {
                        OutputFormatter.format(
                            publicURL: $0.publicURL ?? URL(string: $0.publicURLString)!,
                            mode: .markdown,
                            filename: $0.localFilename
                        )
                    }
                    ClipboardService.copy(lines.joined(separator: "\n"))
                }
                Button("Delete Remote Files\u{2026}", role: .destructive, action: requestRemoteDeletion)
            }
        }
        .padding()
    }
}
