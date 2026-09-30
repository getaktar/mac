import Foundation

/// How a folder is uploaded. Set per destination in its Upload Defaults;
/// nil there means `.default`.
enum FolderUploadMode: String, CaseIterable, Identifiable, Codable {
    /// One .zip file, and one link to it.
    case zip
    /// Every file under one new folder in the bucket, with the same
    /// subfolders, and all the links copied at the end.
    case keepStructure

    static let `default` = FolderUploadMode.zip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: return String(localized: "Upload as ZIP")
        case .keepStructure: return String(localized: "Keep folder structure")
        }
    }
}

enum FolderUploadError: LocalizedError {
    case empty(String)
    case tooManyFiles(String, Int)
    case couldNotZip(String)

    var errorDescription: String? {
        switch self {
        case .empty(let name):
            return String(localized: "\(name) has no files to upload.")
        case .tooManyFiles(let name, let limit):
            return String(localized: "\(name) has more than \(limit) files. Upload it as a ZIP instead.")
        case .couldNotZip(let name):
            return String(localized: "Couldn't make a ZIP of \(name).")
        }
    }
}

enum FolderUpload {
    /// More than this is almost certainly a mistake (a whole home folder),
    /// and would flood the bucket and the history.
    static let maxFiles = 2000

    struct Entry {
        let fileURL: URL
        /// Path inside the folder, with "/" separators, e.g. "css/site.css".
        let relativePath: String
    }

    /// A folder the user picked, as opposed to a file. Packages (a Keynote
    /// document, an app) look like files in Finder, but they're folders on
    /// disk and have to be zipped too.
    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The files in `folder` and its subfolders, skipping hidden ones such
    /// as .DS_Store, .env or .git: a shared link shouldn't carry secrets
    /// or a repository along. Packages inside it are listed as single
    /// items, and get zipped when they're uploaded. `limit` is nil when
    /// they all go into one ZIP anyway.
    static func files(in folder: URL, limit: Int? = maxFiles) throws -> [Entry] {
        let name = folder.lastPathComponent
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw FolderUploadError.empty(name) }

        let root = folder.standardizedFileURL.path
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true || values?.isPackage == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            entries.append(Entry(fileURL: url, relativePath: String(path.dropFirst(root.count + 1))))
            if let limit, entries.count > limit { throw FolderUploadError.tooManyFiles(name, limit) }
        }
        guard !entries.isEmpty else { throw FolderUploadError.empty(name) }
        return entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Where a folder's files go in the bucket: the destination's path
    /// template, used as if for a file named like the folder, as a folder.
    /// `{year}/{month}/{uuid}.{ext}` and "Project" give
    /// "2026/09/7f3c…/Project/", so two uploads of the same folder never
    /// collide and the folder name still shows in every link.
    static func keyPrefix(template: String, folderName: String, date: Date = .now) -> String {
        var base = ObjectKeyGenerator.generate(template: template, originalFilename: folderName, date: date)
        // The folder has no extension, so "{uuid}.{ext}" ends in a dot.
        while base.hasSuffix(".") || base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return folderName + "/" }
        let last = (base as NSString).lastPathComponent
        return last == folderName ? base + "/" : base + "/" + folderName + "/"
    }

    /// A .zip of `folder`, named after it, in a temporary folder the caller
    /// deletes with `removeZip`. Hidden files are left out, the same as
    /// when the folder keeps its structure: the visible files are copied
    /// aside first, then archived with the system's own zip
    /// (NSFileCoordinator's "for uploading", as Finder's Compress uses).
    /// A package (a Keynote document) is zipped whole, as Finder would.
    static func zip(_ folder: URL) throws -> URL {
        let name = folder.lastPathComponent
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarZip", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(name + ".zip")

        var source = folder
        if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true {
            source = directory.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            do {
                for entry in try files(in: folder, limit: nil) {
                    let target = source.appendingPathComponent(entry.relativePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: entry.fileURL, to: target)
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinationError) { zipped in
            // The system's zip is deleted when this block returns.
            do {
                try FileManager.default.copyItem(at: zipped, to: output)
            } catch {
                copyError = error
            }
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("staged"))
        guard coordinationError == nil, copyError == nil, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: directory)
            throw FolderUploadError.couldNotZip(name)
        }
        return output
    }

    static func removeZip(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
