import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - List (content column)

private struct SearchTrigger: Equatable {
    let text: String
    let scope: BucketBrowserModel.SearchScope
    let generation: Int
}

struct BucketListView: View {
    @Bindable var model: BucketBrowserModel
    @Environment(AppState.self) private var appState

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var objectBeingMoved: BucketObject?
    @State private var moveTarget = ""
    @State private var keysPendingDeletion: [String] = []
    @State private var pendingMove: PendingMove?

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    BreadcrumbBar(model: model)
                    if model.isSearchActive && !model.prefix.isEmpty {
                        searchScopeBar
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                statusBar
            }
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search bucket")
            .task(id: SearchTrigger(text: model.searchText, scope: model.searchScope, generation: model.searchGeneration)) {
                // Wait for a pause in typing before listing anything.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await model.runSearch()
            }
            .navigationTitle(model.destination.name)
            .toolbar { toolbarContent }
            // Keyed on the model, not onAppear: changing the destination's
            // settings swaps in a new model under the same view, which then
            // has to list the bucket too.
            .task(id: ObjectIdentifier(model)) { model.loadIfNeeded() }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName
                    Task { await model.createFolder(named: name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Rename or Move",
                isPresented: Binding(get: { objectBeingMoved != nil }, set: { if !$0 { objectBeingMoved = nil } })
            ) {
                TextField("Path", text: $moveTarget)
                Button("Save") {
                    guard let object = objectBeingMoved else { return }
                    requestMove(PendingMove(object: object, target: moveTarget), model: model, appState: appState) { pendingMove = $0 }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Change the name, or the folder part of the path to move it.")
            }
            .alert(
                deleteAlertTitle,
                isPresented: Binding(get: { !keysPendingDeletion.isEmpty }, set: { if !$0 { keysPendingDeletion = [] } })
            ) {
                Button("Cancel", role: .cancel) { keysPendingDeletion = [] }
                Button(
                    keysPendingDeletion.count > 1 ? LocalizedStringKey("Delete Remote Files") : LocalizedStringKey("Delete Remote File"),
                    role: .destructive
                ) {
                    let keys = keysPendingDeletion
                    keysPendingDeletion = []
                    Task { await model.delete(keys, repository: appState.repository, shortLinks: appState.uploadManager.shortLinks) }
                }
            } message: {
                Text(keysPendingDeletion.count > 1
                    ? String(localized: "The remote files will be removed and their links may stop working. This can\u{2019}t be undone.")
                    : String(localized: "The remote file will be removed and its link may stop working. This can\u{2019}t be undone."))
            }
            .shortLinkMoveWarning($pendingMove) { move in
                Task { await model.move(move.object, to: move.target, repository: appState.repository, shortLinks: appState.uploadManager.shortLinks) }
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.loadError, model.folders.isEmpty, model.objects.isEmpty {
            BucketMessageView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn\u{2019}t list this bucket",
                message: error,
                actionTitle: "Try Again",
                action: model.reload
            )
        } else if model.isSearchActive {
            searchContent
        } else if model.hasLoaded && model.folders.isEmpty && model.objects.isEmpty {
            BucketMessageView(
                systemImage: "folder",
                title: "This folder is empty",
                message: String(localized: "Drop files here to upload them to this folder."),
                actionTitle: nil,
                action: {}
            )
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.visibleFolders, id: \.self) { folder in
                Button { model.open(folder) } label: {
                    FolderRow(
                        name: BucketBrowserModel.displayName(ofFolder: folder),
                        location: model.isSearchActive ? locationText(forFolder: folder) : nil
                    )
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .contextMenu {
                    Button("Open") { model.open(folder) }
                    Button("Copy Path") { ClipboardService.copy(folder) }
                }
            }

            ForEach(model.visibleObjects) { object in
                ObjectRow(
                    model: model,
                    object: object,
                    location: model.isSearchActive ? locationText(forKey: object.key) : nil,
                    isBusy: model.busyKeys.contains(object.key)
                )
            }

            if model.isSearchActive && model.isSearching {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .selectionDisabled()
                .listRowSeparator(.hidden)
            }

            if !model.isSearchActive && model.nextContinuationToken != nil {
                HStack {
                    Spacer()
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Load More", action: model.loadMore)
                    }
                    Spacer()
                }
                .selectionDisabled()
                .listRowSeparator(.hidden)
            }

        }
        // Keeps rows from getting stuck at the default single-line height
        // after the list reloads (see LibraryView's history list).
        .environment(\.defaultMinListRowHeight, 40)
        .contextMenu(forSelectionType: String.self) { keys in
            objectMenu(for: Array(keys))
        } primaryAction: { keys in
            guard keys.count == 1, let key = keys.first else { return }
            model.openPublicURL(for: key)
        }
    }

    @ViewBuilder
    private func objectMenu(for keys: [String]) -> some View {
        if keys.count > 1 {
            Button("Copy \(keys.count) URLs") {
                model.copyPublicURLs(keys)
            }
            Divider()
            Button("Delete \(keys.count) Remote Files\u{2026}", role: .destructive) { keysPendingDeletion = keys }
        } else if let key = keys.first, let object = model.object(forKey: key) {
            BucketObjectMenuItems(model: model, object: object) {
                moveTarget = object.key
                objectBeingMoved = object
            } requestDeletion: {
                keysPendingDeletion = [object.key]
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if (model.isLoading && model.hasLoaded) || model.isSearching {
                ProgressView().controlSize(.mini)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        if model.isSearchActive {
            if model.isSearching {
                return String(localized: "Searching\u{2026} Scanned: \(model.searchScannedCount)")
            }
            let results = model.searchResults.count + model.searchFolderResults.count
            if model.searchResults.count >= BucketBrowserModel.maxSearchResults {
                return String(localized: "Showing the first \(results) results")
            }
            return String(localized: "Results: \(results) \u{00B7} Scanned: \(model.searchScannedCount)")
        }
        let folders = model.folders.count
        let files = model.objects.count
        let more = model.nextContinuationToken != nil ? "+" : ""
        return String(localized: "Folders: \(folders) \u{00B7} Files: \(files)\(more)")
    }

    private var deleteAlertTitle: String {
        if keysPendingDeletion.count > 1 {
            return String(localized: "Delete \(keysPendingDeletion.count) files?")
        }
        if let key = keysPendingDeletion.first {
            let name = String(key.split(separator: "/").last ?? "")
            return String(localized: "Delete \u{201C}\(name)\u{201D} from \(model.destination.name)?")
        }
        return ""
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Enclosing Folder", systemImage: "arrow.turn.left.up") {
                if let parent = model.parentPrefix { model.open(parent) }
            }
            .disabled(model.parentPrefix == nil)
            .help("Enclosing Folder")

            Button("Upload to This Folder", systemImage: "plus") { chooseAndUpload() }
                .help("Upload to This Folder")

            Button("New Folder", systemImage: "folder.badge.plus") {
                newFolderName = ""
                isCreatingFolder = true
            }
            .help("New Folder")

            Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                .help("Refresh")
                .disabled(model.isLoading)
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchContent: some View {
        if let error = model.searchError, model.searchResults.isEmpty {
            BucketMessageView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn\u{2019}t list this bucket",
                message: error,
                actionTitle: "Try Again",
                action: model.refresh
            )
        } else if model.visibleFolders.isEmpty && model.visibleObjects.isEmpty {
            if model.isSearching || !model.searchComplete {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Searching\u{2026} Scanned: \(model.searchScannedCount)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BucketMessageView(
                    systemImage: "magnifyingglass",
                    title: "No Results",
                    message: String(localized: "Nothing in \(scopeName) matches \u{201C}\(model.searchText)\u{201D}."),
                    actionTitle: nil,
                    action: {}
                )
            }
        } else {
            list
        }
    }

    private var searchScopeBar: some View {
        HStack(spacing: 8) {
            Text("Search:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Search:", selection: $model.searchScope) {
                Text("Entire Bucket").tag(BucketBrowserModel.SearchScope.bucket)
                Text(verbatim: "\u{201C}\(BucketBrowserModel.displayName(ofFolder: model.prefix))\u{201D}")
                    .tag(BucketBrowserModel.SearchScope.folder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var scopeName: String {
        model.searchScope == .folder && !model.prefix.isEmpty
            ? "\u{201C}\(BucketBrowserModel.displayName(ofFolder: model.prefix))\u{201D}"
            : model.destination.bucket
    }

    /// Where a search result lives, shown under its name: the bucket-relative
    /// folder path, or the bucket name for top-level items.
    private func locationText(forKey key: String) -> String {
        let parent = BucketBrowserModel.parent(ofKey: key)
        return parent.isEmpty ? model.destination.bucket : String(parent.dropLast())
    }

    private func locationText(forFolder folder: String) -> String {
        let parent = BucketBrowserModel.parent(ofFolder: folder)
        return parent.isEmpty ? model.destination.bucket : String(parent.dropLast())
    }

    private func chooseAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        model.upload(panel.urls, source: .filePicker, using: appState.uploadManager)
    }
}

/// Copy, open, rename and delete actions for one object, shared by the
/// list's context menu and the detail view's toolbar menu.
private struct BucketObjectMenuItems: View {
    @Environment(AppState.self) private var appState
    let model: BucketBrowserModel
    let object: BucketObject
    let requestMove: () -> Void
    let requestDeletion: () -> Void

    var body: some View {
        Button("Copy URL") { model.copyPublicURLs([object.key]) }
        Button("Copy Markdown") { copy(.markdown) }
        Button("Copy HTML") { copy(.html) }
        TemporaryLinkMenu(model: model, key: object.key)
        Button("Copy Object Key") { ClipboardService.copy(object.key) }
        Divider()
        Button("Open in Browser") { model.openPublicURL(for: object.key) }
        Divider()
        Button("Rename or Move\u{2026}", action: requestMove)
        Button("Replace File\u{2026}") {
            ReplaceFile.replaceObject(key: object.key, in: model.destination, using: appState.uploadManager)
        }
        Button("Delete Remote File\u{2026}", role: .destructive, action: requestDeletion)
    }

    private func copy(_ mode: OutputMode) {
        model.copyPublicURLs([object.key]) { url, _ in OutputFormatter.format(publicURL: url, mode: mode, filename: object.name) }
    }
}

private struct TemporaryLinkMenu: View {
    let model: BucketBrowserModel
    let key: String

    var body: some View {
        Menu("Copy Temporary Link") {
            ForEach(TemporaryLinkDuration.allCases) { duration in
                Button(duration.title) {
                    Task {
                        do {
                            let url = try await model.temporaryURL(for: key, validFor: duration.rawValue)
                            ClipboardService.copy(url.absoluteString)
                        } catch {
                            model.actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private struct BreadcrumbBar: View {
    let model: BucketBrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let crumbs = model.breadcrumbs
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.open(crumb.prefix)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: model.destination.preset.symbolName)
                                    .font(.caption)
                            }
                            Text(verbatim: crumb.name)
                        }
                        .font(.callout)
                        .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(index == crumbs.count - 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct FolderRow: View {
    let name: String
    var location: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                if let location {
                    Label {
                        Text(verbatim: location)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ObjectRow: View {
    let model: BucketBrowserModel
    let object: BucketObject
    var location: String?
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            BucketObjectThumbnail(model: model, object: object, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: object.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(object.key)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let location {
                    Label {
                        Text(verbatim: location)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                }
            }
            if isBusy {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .opacity(isBusy ? 0.6 : 1)
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
        guard let date = object.lastModified else { return size }
        return "\(size) \u{00B7} \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// A bucket file's thumbnail (see `RemoteThumbnailLoader`), or its file
/// icon while there's none, and for good when the destination's thumbnails
/// are off.
private struct BucketObjectThumbnail: View {
    let model: BucketBrowserModel
    let object: BucketObject
    let size: CGFloat
    var iconSize: CGFloat?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                CheckerboardBackground()
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: FileKindIcon.symbolName(for: object.name))
                    .font(iconSize.map { .system(size: $0) } ?? .title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: image == nil ? 0 : min(size * 0.18, 8)))
        .task(id: object) {
            let loader = RemoteThumbnailLoader.shared
            image = loader.cachedImage(for: object, destination: model.destination)
            if image == nil {
                image = await loader.image(for: object, destination: model.destination, prefixes: model.thumbnailPrefixes())
            }
        }
    }
}

private struct BucketMessageView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: String
    let actionTitle: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail column

struct BucketDetailView: View {
    let model: BucketBrowserModel

    var body: some View {
        let selected = model.selectedObjects
        if selected.count > 1 {
            BucketMultiSelectionView(model: model, objects: selected)
        } else if let object = selected.first {
            BucketObjectDetailView(model: model, object: object)
                .id(object.key)
        } else {
            Text("Select a file to see its details")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BucketObjectDetailView: View {
    let model: BucketBrowserModel
    let object: BucketObject

    @Environment(AppState.self) private var appState
    @State private var previewURL: URL?
    @State private var justCopiedURL = false
    @State private var isConfirmingDeletion = false
    @State private var isMoving = false
    @State private var moveTarget = ""
    @State private var pendingMove: PendingMove?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: object.name).font(.title3.bold()).textSelection(.enabled)
                    Text(verbatim: "\(model.destination.bucket)/\(BucketBrowserModel.parent(ofKey: object.key))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                preview
                linkSection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details").font(.subheadline.bold()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(label: "File size", value: ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file))
                        if let date = object.lastModified {
                            DetailRow(
                                label: "Modified",
                                value: date.formatted(date: .abbreviated, time: .shortened),
                                tooltip: date.formatted(date: .complete, time: .standard)
                            )
                        }
                        DetailRow(label: "Object key", value: object.key)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: object.key) { previewURL = await model.previewURL(for: object.key) }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    copyURL()
                } label: {
                    Label(justCopiedURL ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy URL"), systemImage: justCopiedURL ? "checkmark" : "doc.on.doc")
                }
                Menu {
                    BucketObjectMenuItems(model: model, object: object) {
                        moveTarget = object.key
                        isMoving = true
                    } requestDeletion: {
                        isConfirmingDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(
            String(localized: "Delete \u{201C}\(object.name)\u{201D} from \(model.destination.name)?"),
            isPresented: $isConfirmingDeletion
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Remote File", role: .destructive) {
                Task { await model.delete([object.key], repository: appState.repository, shortLinks: appState.uploadManager.shortLinks) }
            }
        } message: {
            Text("The remote file will be removed and its link may stop working. This can\u{2019}t be undone.")
        }
        .alert("Rename or Move", isPresented: $isMoving) {
            TextField("Path", text: $moveTarget)
            Button("Save") {
                requestMove(PendingMove(object: object, target: moveTarget), model: model, appState: appState) { pendingMove = $0 }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Change the name, or the folder part of the path to move it.")
        }
        .shortLinkMoveWarning($pendingMove) { move in
            Task { await model.move(move.object, to: move.target, repository: appState.repository, shortLinks: appState.uploadManager.shortLinks) }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch FilePreviewKind(filename: object.name) {
        case .image:
            ZStack {
                CheckerboardBackground()
                if let previewURL {
                    RemoteImage(url: previewURL) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                        case .failure: unavailablePreview
                        case .empty: ProgressView()
                        }
                    }
                    .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .pdf:
            loadedFile(height: 420) { data in PDFKitView(data: data) }

        case .text(let markdown):
            loadedFile(height: 320) { data in TextFilePreview(data: data, renderMarkdown: markdown) }
                .background(Color.secondary.opacity(0.06))

        case .media:
            MediaPreview(
                filename: object.name,
                poster: RemoteThumbnailLoader.shared.cachedImage(for: object, destination: model.destination)
            ) {
                await model.previewURL(for: object.key)
            }
            .id(object.key)
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .unsupported:
            VStack(spacing: 10) {
                // A video's frame, a document's first page and the like.
                BucketObjectThumbnail(model: model, object: object, size: 150, iconSize: 44)
                Button("Open in Browser") { model.openPublicURL(for: object.key) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func loadedFile<Content: View>(height: CGFloat, @ViewBuilder content: @escaping (Data) -> Content) -> some View {
        Group {
            if let previewURL {
                RemoteFileLoader(url: previewURL, knownSize: object.size) { phase in
                    switch phase {
                    case .success(let data): content(data)
                    case .failure, .tooLarge: unavailablePreview
                    case .loading: ProgressView()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var unavailablePreview: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var linkSection: some View {
        let url = model.publicURL(for: object.key)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Link").font(.subheadline.bold()).foregroundStyle(.secondary)
            HStack {
                Text(verbatim: url?.absoluteString ?? "-")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url?.absoluteString ?? "")
                Spacer(minLength: 8)
                Button(action: copyURL) {
                    Image(systemName: justCopiedURL ? "checkmark" : "doc.on.doc")
                }
                .help("Copy URL")
                Button {
                    model.openPublicURL(for: object.key)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Open in Browser")
            }
            .buttonStyle(.plain)
        }
    }

    private func copyURL() {
        model.copyPublicURLs([object.key])
        justCopiedURL = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopiedURL = false
        }
    }
}

private struct BucketMultiSelectionView: View {
    let model: BucketBrowserModel
    let objects: [BucketObject]

    @Environment(AppState.self) private var appState
    @State private var isConfirmingDeletion = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("\(objects.count) items selected").font(.title3.bold())
            HStack {
                Button("Copy URLs") {
                    model.copyPublicURLs(objects.map(\.key))
                }
                Button("Copy Markdown") {
                    let names = Dictionary(objects.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
                    model.copyPublicURLs(objects.map(\.key)) { url, key in
                        OutputFormatter.format(publicURL: url, mode: .markdown, filename: names[key] ?? key)
                    }
                }
                Button("Delete Remote Files\u{2026}", role: .destructive) { isConfirmingDeletion = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(String(localized: "Delete \(objects.count) files?"), isPresented: $isConfirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Remote Files", role: .destructive) {
                let keys = objects.map(\.key)
                Task { await model.delete(keys, repository: appState.repository, shortLinks: appState.uploadManager.shortLinks) }
            }
        } message: {
            Text("The remote files will be removed and their links may stop working. This can\u{2019}t be undone.")
        }
    }
}

// MARK: - Moving files with short links

/// A rename or move waiting for the user to confirm it, because a short
/// link to the file can't follow it (rule 7 in docs/short-links.md).
private struct PendingMove {
    let object: BucketObject
    let target: String
}

/// Moves right away, or asks first through `ask` when the file's short
/// links can't be pointed at its new place.
@MainActor
private func requestMove(_ move: PendingMove, model: BucketBrowserModel, appState: AppState, ask: (PendingMove) -> Void) {
    let shortLinks = appState.uploadManager.shortLinks
    if model.shortLinkMovePlan(for: move.object, repository: appState.repository, shortLinks: shortLinks) == .warn {
        ask(move)
    } else {
        Task { await model.move(move.object, to: move.target, repository: appState.repository, shortLinks: shortLinks) }
    }
}

private extension View {
    func shortLinkMoveWarning(_ pending: Binding<PendingMove?>, perform: @escaping (PendingMove) -> Void) -> some View {
        alert(
            "Move this file?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { move in
            Button("Move Anyway", role: .destructive) { perform(move) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This short-link provider cannot update existing destinations. Moving this file may invalidate its short link.")
        }
    }
}

/// Which inline preview a file gets, decided from its extension.
enum FilePreviewKind {
    case image
    case pdf
    case text(markdown: Bool)
    /// A video or audio file AVFoundation can play.
    case media
    case unsupported

    init(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        let textExtensions: Set<String> = ["txt", "json", "yml", "yaml", "swift", "js", "ts", "py", "log", "csv", "xml", "html", "css"]
        if ext == "md" || ext == "markdown" {
            self = .text(markdown: true)
        } else if textExtensions.contains(ext) {
            self = .text(markdown: false)
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            self = .image
        } else if ext == "pdf" {
            self = .pdf
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .text) {
            self = .text(markdown: false)
        } else if MediaPreview.canPlay(filename: filename) {
            self = .media
        } else {
            self = .unsupported
        }
    }
}
