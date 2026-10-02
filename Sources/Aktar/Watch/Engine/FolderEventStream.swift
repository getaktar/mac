import CoreServices
import Darwin
import Foundation

/// What to read about a file beyond `lstat`, which is free; the rest costs
/// a call per file, so it's only read where it can matter.
struct InspectOptions: Sendable, Equatable {
    /// Ask iCloud whether the file is downloaded: only in iCloud Drive (or
    /// a Desktop or Documents folder it syncs).
    var ubiquity = false
    /// Read the screenshot attribute: only for "Screenshots only".
    var screenCapture = false

    init(ubiquity: Bool = false, screenCapture: Bool = false) {
        self.ubiquity = ubiquity
        self.screenCapture = screenCapture
    }

    init(folder: WatchedFolder, root: URL) {
        ubiquity = FileInspector.isUbiquitous(root)
        screenCapture = folder.filter.kind == .screenshots
    }
}

/// A look at one path on disk.
enum Inspection: Sendable {
    case file(FileFacts)
    /// Nothing there, for certain.
    case missing
    /// Something went wrong reading it (a lost permission): says nothing.
    case unreadable
}

/// Reads `FileFacts` from disk.
enum FileInspector {
    /// macOS sets this on screenshots and screen recordings it saves.
    static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    /// A file whose contents are in iCloud only ("dataless"), not in
    /// <sys/stat.h> for Swift.
    private static let dataless: UInt32 = 0x4000_0000
    static let ubiquityKeys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

    /// Symlinks are described, not followed. `prefetched` is what a
    /// directory listing already read about the file.
    static func inspect(_ url: URL, options: InspectOptions = InspectOptions(), prefetched: URLResourceValues? = nil) -> Inspection {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        let type = info.st_mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        var cloudOnly = info.st_flags & dataless != 0
        if !cloudOnly, options.ubiquity, type == S_IFREG {
            let values = prefetched ?? (try? url.resourceValues(forKeys: ubiquityKeys))
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus {
                cloudOnly = status != .current
            }
        }
        return .file(FileFacts(
            isRegularFile: type == S_IFREG,
            isSymlink: type == S_IFLNK,
            isHidden: info.st_flags & UInt32(UF_HIDDEN) != 0,
            size: Int64(info.st_size),
            modified: modified,
            fileID: UInt64(info.st_ino),
            isCloudOnly: cloudOnly,
            isScreenCapture: options.screenCapture && type == S_IFREG
                && getxattr(url.path, screenCaptureAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        ))
    }

    /// Nil when there's nothing at `url` (or it can't be read).
    static func facts(at url: URL, options: InspectOptions = InspectOptions()) -> FileFacts? {
        if case .file(let facts) = inspect(url, options: options) { return facts }
        return nil
    }

    /// Whether files under `root` can be iCloud placeholders.
    static func isUbiquitous(_ root: URL) -> Bool {
        if root.path.contains("/Library/Mobile Documents/") { return true }
        return (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// Whether one of the folders `relativePath` is in is a package (a
    /// Keynote document, an app): its insides aren't separate files.
    static func isInsidePackage(_ relativePath: String, root: URL) -> Bool {
        var url = root
        for component in relativePath.split(separator: "/").dropLast() {
            url.appendPathComponent(String(component), isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        }
        return false
    }

    /// Whether nothing is at `url`, for certain: an error such as a lost
    /// permission doesn't count as missing.
    static func isMissing(_ url: URL) -> Bool {
        if case .missing = inspect(url) { return true }
        return false
    }

    /// The folder is there and its contents can be read.
    static func canList(_ url: URL) -> Bool {
        guard let dir = opendir(url.path) else { return false }
        closedir(dir)
        return true
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// SMB, AFP, NFS and WebDAV volumes don't report changes made by other
    /// computers, so they're also polled.
    static func isNetworkVolume(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return ["smbfs", "afpfs", "nfs", "webdav"].contains(type)
    }

    /// The files under `root` (or its subfolder `subpath`) worth looking at,
    /// with their facts: regular files, not hidden, outside `Uploaded` and
    /// packages, and only the top level unless `recursive`. Paths are
    /// relative to `root`, with "/" separators. Nil when the folder couldn't
    /// be read, which says nothing about its files.
    static func walk(_ root: URL, subpath: String? = nil, recursive: Bool, options: InspectOptions = InspectOptions()) -> [(path: String, facts: FileFacts)]? {
        let start = subpath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        guard canList(start) else { return nil }
        var enumeration: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { enumeration.insert(.skipsSubdirectoryDescendants) }
        var keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        if options.ubiquity { keys += Array(ubiquityKeys) }
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: keys, options: enumeration) else { return nil }
        let roots = rootSpellings(root)
        var result: [(path: String, facts: FileFacts)] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let relative = relativePath(url.standardizedFileURL.path, roots: roots) else { continue }
            if values?.isDirectory == true {
                if relative.caseInsensitiveCompare(WatchFileRules.uploadedFolderName) == .orderedSame {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  case .file(let facts) = inspect(url, options: options, prefetched: values) else { continue }
            result.append((relative, facts))
        }
        return result
    }

    /// The ways a path under `root` can be spelled: as given and with
    /// symlinks resolved ("/var/..." and "/private/var/..."); file events
    /// use the second.
    static func rootSpellings(_ root: URL) -> [String] {
        let given = ForbiddenFolders.normalized(root.standardizedFileURL.path)
        let canonical = ForbiddenFolders.canonicalPath(root.path)
        return given == canonical ? [given] : [canonical, given]
    }

    /// `path` relative to whichever of `roots` it's under, or nil.
    static func relativePath(_ path: String, roots: [String]) -> String? {
        for root in roots where ForbiddenFolders.contains(root, path) {
            return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        }
        return nil
    }
}

/// What a network volume looked like at the last poll, folder by folder,
/// so the next poll only lists folders whose modification date changed
/// (adding or removing a file changes it). Used from one scan at a time.
final class DirectorySnapshot: @unchecked Sendable {
    private struct Folder {
        var modified: Date
        var files: Set<String>
        var subfolders: [String]
    }

    struct Changes: Sendable {
        /// Files in folders that changed, with their facts.
        var files: [(path: String, facts: FileFacts)] = []
        /// Files that were there at the last poll and aren't now.
        var removed: [String] = []
        var changed: Bool { !files.isEmpty || !removed.isEmpty }
    }

    private var folders: [String: Folder] = [:]
    private let lock = NSLock()

    /// Forgets everything: the next poll lists every folder.
    func reset() {
        lock.lock()
        folders = [:]
        lock.unlock()
    }

    /// Nil when the folder couldn't be read.
    func poll(_ root: URL, recursive: Bool, options: InspectOptions) -> Changes? {
        lock.lock()
        defer { lock.unlock() }
        guard FileInspector.canList(root) else { return nil }
        var changes = Changes()
        var seen: Set<String> = []
        visit("", root: root, recursive: recursive, options: options, changes: &changes, seen: &seen)
        // Folders that went away take their files along.
        for (path, folder) in folders where !seen.contains(path) {
            changes.removed += folder.files.map { path.isEmpty ? $0 : path + "/" + $0 }
            folders[path] = nil
        }
        return changes
    }

    private func visit(_ path: String, root: URL, recursive: Bool, options: InspectOptions, changes: inout Changes, seen: inout Set<String>) {
        seen.insert(path)
        let url = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
        guard let modified = FileInspector.facts(at: url)?.modified else { return }
        var folder: Folder
        if let known = folders[path], known.modified == modified {
            folder = known
        } else {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            var files: Set<String> = []
            var subfolders: [String] = []
            for item in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                let name = item.lastPathComponent
                if values?.isDirectory == true, values?.isPackage != true {
                    if path.isEmpty, name.caseInsensitiveCompare(WatchFileRules.uploadedFolderName) == .orderedSame { continue }
                    subfolders.append(name)
                } else if values?.isRegularFile == true {
                    files.insert(name)
                }
            }
            let previous = folders[path]?.files ?? []
            for name in files {
                let relative = path.isEmpty ? name : path + "/" + name
                if let facts = FileInspector.facts(at: url.appendingPathComponent(name), options: options) {
                    changes.files.append((relative, facts))
                }
            }
            changes.removed += previous.subtracting(files).map { path.isEmpty ? $0 : path + "/" + $0 }
            folder = Folder(modified: modified, files: files, subfolders: subfolders)
            folders[path] = folder
        }
        guard recursive else { return }
        for name in folder.subfolders {
            visit(path.isEmpty ? name : path + "/" + name, root: root, recursive: true, options: options, changes: &changes, seen: &seen)
        }
    }
}

/// Waits for a missing folder to come back without polling: it watches the
/// nearest folder above it that still exists, and calls `onChange` when
/// something in it changes (then looks again, one level closer).
@MainActor
final class AncestorWatcher {
    /// Only replaced on the main actor; cancelling is thread-safe.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        anchor()
    }

    /// Watches the closest existing ancestor again.
    func anchor() {
        source?.cancel()
        source = nil
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        while url.path != "/", !FileInspector.isDirectory(url) {
            url.deleteLastPathComponent()
        }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.anchor()
                self?.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}

/// File system events for one folder and everything under it, delivered
/// on the main queue. They're only hints: the watcher always looks at the
/// file itself before doing anything.
@MainActor
final class FolderEventStream {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId

        /// Events were dropped or merged, so the whole folder needs a look.
        var needsRescan: Bool {
            let rescan = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            return flags & FSEventStreamEventFlags(rescan) != 0
        }

        /// The watched folder itself was moved or deleted.
        var rootChanged: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 }
        var isDirectory: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 }
    }

    /// Holds the handler for the C callback; the stream keeps it alive.
    private final class Box {
        let handler: @MainActor ([Event]) -> Void
        init(handler: @escaping @MainActor ([Event]) -> Void) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    /// Starts with events from now on: what changed before is found by the
    /// scan that follows. `ignoreSelf` leaves out the process's own changes.
    /// The app keeps it off: its After upload moves are already in the
    /// ledger, and a file it writes into a watched folder (a download from
    /// the bucket browser, a saved QR code) should be seen right away.
    init?(path: String, ignoreSelf: Bool = false, latency: TimeInterval = 0.3, handler: @escaping @MainActor ([Event]) -> Void) {
        box = Box(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            for index in 0..<count {
                guard let path = array[index] as? String else { continue }
                events.append(Event(path: path, flags: flags[index], id: ids[index]))
            }
            // The stream is scheduled on the main queue.
            MainActor.assumeIsolated { box.handler(events) }
        }
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes
        )
        if ignoreSelf { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf) }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
