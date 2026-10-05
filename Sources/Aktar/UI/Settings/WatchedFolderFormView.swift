import AppKit
import SwiftUI

/// The rules of one watched folder.
struct WatchedFolderFormView: View {
    var onSave: (WatchedFolder) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var folder: WatchedFolder
    @State private var customPath: Bool
    @State private var pathTemplate: String
    @State private var includeText: String
    @State private var excludeText: String
    /// Megabytes; nil is no limit.
    @State private var minMB: Int?
    @State private var maxMB: Int?

    private static let bytesPerMB: Int64 = 1_000_000

    init(folder: WatchedFolder, onSave: @escaping (WatchedFolder) -> Void) {
        self.onSave = onSave
        _folder = State(initialValue: folder)
        _customPath = State(initialValue: folder.pathTemplate != nil)
        _pathTemplate = State(initialValue: folder.pathTemplate ?? "{folder}/{subpath}/{year}/{month}/{filename}.{ext}")
        _includeText = State(initialValue: folder.filter.include.joined(separator: ", "))
        _excludeText = State(initialValue: folder.filter.exclude.joined(separator: ", "))
        _minMB = State(initialValue: folder.filter.minBytes.map { Int($0 / Self.bytesPerMB) })
        _maxMB = State(initialValue: folder.filter.maxBytes.map { Int($0 / Self.bytesPerMB) })
    }

    private var service: WatchService { appState.watchService }

    var body: some View {
        VStack(spacing: 0) {
            Text(folder.name.isEmpty ? String(localized: "Watched Folder") : folder.name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            Form {
                folderSection
                uploadSection
                filesSection
                changesSection
                afterUploadSection
                deletedSection
                automationSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(currentFolder()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.name.trimmingCharacters(in: .whitespaces).isEmpty || HookListEditor.hasUnusableWebhook(folder.hooks))
            }
            .padding()
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Sections

    private var folderSection: some View {
        Section {
            TextField("Name", text: $folder.name)
            HStack {
                Text(verbatim: UserPaths.abbreviated(folder.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(folder.path)
                Spacer()
                Button("Change\u{2026}") { changeFolder() }
            }
        } header: {
            Text("Folder")
        } footer: {
            if folder.preset == .screenshots || folder.filter.kind == .screenshots {
                Text("macOS saves a screenshot once its floating thumbnail disappears, about 5 seconds later. For instant uploads, turn off Show Floating Thumbnail in the Screenshot app\u{2019}s Options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var uploadSection: some View {
        let destination = service.destination(for: folder)
        return Section {
            Picker("Destination", selection: $folder.destinationID) {
                Text(defaultDestinationLabel).tag(UUID?.none)
                ForEach(appState.destinationStore.destinations) { destination in
                    Text(destination.name).tag(UUID?.some(destination.id))
                }
            }
            Picker("Path", selection: $customPath) {
                Text("Use destination\u{2019}s path").tag(false)
                Text("Custom").tag(true)
            }
            if customPath {
                TextField("Object Path", text: $pathTemplate)
            }
            Picker("Link", selection: $folder.temporaryLink) {
                Text("Destination default").tag(WatchLinkOverride?.none)
                Text(TemporaryLinkDuration.label(nil)).tag(WatchLinkOverride?.some(.publicLink))
                ForEach(TemporaryLinkDuration.allCases) { duration in
                    Text(TemporaryLinkDuration.label(duration)).tag(WatchLinkOverride?.some(.temporary(seconds: duration.rawValue)))
                }
            }
            Picker("Delete after", selection: $folder.expiryDays) {
                Text("Destination default").tag(Int?.none)
                ForEach([0] + UploadExpiry.options, id: \.self) { days in
                    Text(UploadExpiry.label(days: days)).tag(Int?.some(days))
                }
            }
            .disabled(destination.map { !ExpiryRuleStore.shared.isActive($0.id) } ?? true)
        } header: {
            Text("Upload")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if customPath {
                    Text("Variables: {year} {month} {day} {date} {time} {filename} {uuid} {random} {ext} {md5} {sha256} {folder} {subpath}")
                    Text(verbatim: "{folder}: ") + Text("the watched folder\u{2019}s name")
                    Text(verbatim: "{subpath}: ") + Text("the subfolders the file is in, when the folder structure is kept")
                }
                if let destination, !ExpiryRuleStore.shared.isActive(destination.id) {
                    Text("\u{201C}Delete after\u{201D} needs auto-delete set up for the destination first.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var defaultDestinationLabel: String {
        guard let name = appState.destinationStore.defaultDestination?.name else { return String(localized: "Default destination") }
        return String(localized: "Default destination (\(name))")
    }

    private var filesSection: some View {
        Section {
            Picker("Subfolders", selection: $folder.subfolders) {
                Text("Ignore subfolders").tag(SubfolderMode.ignore)
                Text("Include, keep folder structure").tag(SubfolderMode.keepStructure)
                Text("Include, upload flat").tag(SubfolderMode.flatten)
            }
            Picker("Files", selection: $folder.filter.kind) {
                Text("All files").tag(WatchFilter.Kind.all)
                Text("Images").tag(WatchFilter.Kind.images)
                Text("Videos").tag(WatchFilter.Kind.videos)
                Text("Screenshots only").tag(WatchFilter.Kind.screenshots)
                Text("Custom").tag(WatchFilter.Kind.custom)
            }
            if folder.filter.kind == .custom {
                TextField("Include patterns", text: $includeText, prompt: Text(verbatim: "*.png, *.pdf"))
            }
            TextField("Exclude patterns", text: $excludeText, prompt: Text(verbatim: "*.psd, drafts/*"))
            HStack {
                TextField("Minimum size", value: $minMB, format: .number, prompt: Text("None"))
                Text(verbatim: "MB").foregroundStyle(.secondary)
            }
            HStack {
                TextField("Maximum size", value: $maxMB, format: .number, prompt: Text("None"))
                Text(verbatim: "MB").foregroundStyle(.secondary)
            }
            Toggle("Upload online-only files (downloads them first)", isOn: $folder.includeCloudOnly)
        } header: {
            Text("Files")
        } footer: {
            Text("Patterns are separated by commas and match the file\u{2019}s name, or its path in the folder when they contain \u{201C}/\u{201D}. Partial downloads, temporary and hidden files, and the Uploaded subfolder are always left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var changesSection: some View {
        Section {
            Picker("When a file changes", selection: $folder.modified) {
                Text("Ignore changes").tag(ModifiedPolicy.ignore)
                Text("Upload again with a new link").tag(ModifiedPolicy.uploadAgain)
                Text("Replace the uploaded file (keeps the link)").tag(ModifiedPolicy.overwrite)
            }
        } header: {
            Text("When a file changes")
        }
    }

    private var afterUploadSection: some View {
        Section {
            Picker("Original file", selection: $folder.afterUpload) {
                Text("Keep it").tag(AfterUploadAction.keep)
                Text("Move to Trash").tag(AfterUploadAction.trash)
                Text("Move to \u{201C}Uploaded\u{201D} subfolder").tag(AfterUploadAction.moveToUploaded)
                Text("Add \u{201C}Aktar\u{201D} Finder tag").tag(AfterUploadAction.tag)
            }
            Picker("Clipboard", selection: $folder.clipboard) {
                Text("Copy the link").tag(ClipboardPolicy.copyLink)
                Text("Don\u{2019}t touch the clipboard").tag(ClipboardPolicy.off)
            }
            Picker("Notifications", selection: $folder.notifications) {
                Text("One per file").tag(NotificationPolicy.each)
                Text("One per batch").tag(NotificationPolicy.grouped)
                Text("Only failures").tag(NotificationPolicy.failuresOnly)
            }
        } header: {
            Text("After upload")
        } footer: {
            Text("A file is only moved once the bucket confirms the whole upload, and never deleted outright.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Only offered while uploaded files stay in the folder: moved ones
    /// leave it by design, and that's not a deletion.
    private var deletedSection: some View {
        let available = folder.afterUpload == .keep || folder.afterUpload == .tag
        return Section {
            Picker("When a file is deleted", selection: $folder.onDelete) {
                Text("Keep the uploaded file").tag(OnDeletePolicy.keep)
                Text("Delete it from the bucket too").tag(OnDeletePolicy.deleteRemote)
            }
            .disabled(!available)
            if available, folder.onDelete == .deleteRemote {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Ask before deleting", isOn: $folder.confirmDelete)
                    Text("Aktar asks before it deletes anything from the bucket.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("When a file is deleted")
        } footer: {
            Group {
                if !available {
                    Text("Only available when the original file stays in the folder.")
                } else if folder.onDelete == .deleteRemote {
                    Text("Deleting a file from this folder also deletes its upload. Links to it stop working.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var automationSection: some View {
        Section {
            HookListEditor(hooks: $folder.hooks) { hook in
                try await service.testHook(hook, folder: currentFolder())
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Runs after each upload from this folder. A webhook gets the upload as JSON. A script gets the same JSON on standard input, with the link, the key, the file and the folder as its arguments; put scripts in Aktar\u{2019}s scripts folder (~/Library/Application Scripts/com.getaktar.mac) to pick them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func changeFolder() {
        guard let url = WatchFolderPicker.pick(
            preselected: folder.url,
            message: String(localized: "Choose a folder. New files in it are uploaded automatically.")
        ) else { return }
        if let reason = service.forbiddenReason(for: url, excluding: folder.id) {
            WatchFolderPicker.showProblem(reason.message)
            return
        }
        if folder.name == folder.url.lastPathComponent { folder.name = url.lastPathComponent }
        folder.path = url.path
        folder.bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func currentFolder() -> WatchedFolder {
        var folder = folder
        folder.name = folder.name.trimmingCharacters(in: .whitespaces)
        let template = pathTemplate.trimmingCharacters(in: .whitespaces)
        folder.pathTemplate = customPath && !template.isEmpty ? template : nil
        folder.filter.include = WatchFileRules.patterns(from: includeText)
        folder.filter.exclude = WatchFileRules.patterns(from: excludeText)
        folder.filter.minBytes = minMB.flatMap { $0 > 0 ? Int64($0) * Self.bytesPerMB : nil }
        folder.filter.maxBytes = maxMB.flatMap { $0 > 0 ? Int64($0) * Self.bytesPerMB : nil }
        return folder
    }
}
