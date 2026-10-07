import CoreServices
import Foundation
import Observation

/// One file handed to the upload queue.
struct WatchUploadRequest: Sendable {
    let id: UUID
    let folder: WatchedFolder
    let fileURL: URL
    /// "/"-separated path inside the folder.
    let relativePath: String
    /// What {subpath} stands for; "" unless the folder keeps its structure.
    let subpath: String
    /// Upload to exactly this key, replacing the earlier upload so its link
    /// keeps working.
    let overwriteKey: String?
    /// The file's SHA-256 when the watcher already has it (it compared a
    /// changed file), so the upload doesn't read the file for it again.
    var sha256: String? = nil
    /// The folder reacts to changes, so the ledger needs the file's hash:
    /// the upload computes it in the pass it makes anyway.
    var wantsContentHash = false
    /// The inode the watcher checked; the upload only reads the file while
    /// it's still that one.
    var fileID: UInt64? = nil
}

struct WatchUploadSuccess: Sendable, Equatable {
    var objectKey: String
    var publicURL: String
    /// What's shared: the public URL or a temporary link (the short link,
    /// when there is one, is `shortUrl`).
    var link: String
    /// The same file was already uploaded, and its link was reused.
    var reused: Bool
    var byteSize: Int64
    var destinationID: UUID
    /// The name the upload went by (a converted photo's new extension).
    var filename: String
    /// SHA-256 of the file as it is on disk, when the upload computed it
    /// from the original bytes (not a converted or cleaned copy).
    var contentHash: String?
    /// The upload's short link, which is copied instead of `link`.
    var shortUrl: String? = nil
}

enum WatchUploadOutcome: Sendable, Equatable {
    case succeeded(WatchUploadSuccess)
    /// `retryable`: the network or a busy provider, worth trying again
    /// later without being asked.
    case failed(message: String, retryable: Bool)
    case cancelled
}

/// The upload queue as the watcher sees it. The app's is `UploadManager`;
/// tests use a fake.
@MainActor
protocol WatchUploading: AnyObject {
    func enqueue(_ requests: [WatchUploadRequest])
    /// Whether the bucket really has `key` at `size` bytes, checked before
    /// the original is moved away.
    func verifyUploaded(key: String, destinationID: UUID, size: Int64) async -> Bool
    /// Deletes an upload whose file was deleted from the folder, the way
    /// the Library deletes one (history included).
    func deleteUpload(key: String, destinationID: UUID, folderID: UUID) async -> WatchDeleteOutcome
    /// Whether history has the object from anywhere but this folder (a
    /// manual upload to the same key), so it isn't the folder's to delete.
    func isReferencedInHistory(key: String, destinationID: UUID, folderID: UUID) -> Bool
}

enum WatchDeleteOutcome: Sendable, Equatable {
    case deleted
    case failed(message: String, retryable: Bool)
}

/// Uploads deleted from the bucket together, reported once all are done.
struct WatchDeleteSummary: Sendable {
    let folder: WatchedFolder
    /// File names.
    let deleted: [String]
    let failures: [WatchedFileFailure]
}

/// A file of a watched folder that was uploaded, after the folder's
/// "After upload" was applied.
struct WatchedFileUpload: Sendable {
    let folder: WatchedFolder
    let relativePath: String
    /// Where the file was when it was uploaded.
    let fileURL: URL
    let size: Int64
    let success: WatchUploadSuccess
}

struct WatchedFileFailure: Sendable {
    let folder: WatchedFolder
    let relativePath: String
    let message: String
    /// The first failure of this file. Automatic retries that fail again
    /// stay quiet: one notification per outage, not one per try.
    var isFirstFailure = true
}

/// Files enqueued together, reported once all of them are done.
struct WatchBatchSummary: Sendable {
    let folder: WatchedFolder
    let uploads: [WatchedFileUpload]
    let failures: [WatchedFileFailure]
}

@MainActor
protocol WatchEngineDelegate: AnyObject {
    func engine(_ engine: FolderWatchEngine, didUpload upload: WatchedFileUpload)
    func engine(_ engine: FolderWatchEngine, didSettle batch: WatchBatchSummary)
    /// More new files than `WatchTiming.largeBatch` are waiting for
    /// Upload or Skip. `count` is 0 once their files were all deleted and
    /// the ask is withdrawn.
    func engine(_ engine: FolderWatchEngine, needsConfirmation count: Int)
    /// After Upload couldn't be applied, or a similar problem worth showing
    /// on the folder.
    func engine(_ engine: FolderWatchEngine, reportError message: String)
    /// A deleted file's upload was deleted from the bucket.
    func engine(_ engine: FolderWatchEngine, didDeleteRemote name: String)
    func engine(_ engine: FolderWatchEngine, didSettleDeletes summary: WatchDeleteSummary)
    /// The uploads waiting for Delete from Bucket or Keep Uploaded Files
    /// changed (a large deletion, or a folder that asks first). `names` is
    /// all of them now, empty once nothing is left to ask; `added` says new
    /// ones joined.
    func engine(_ engine: FolderWatchEngine, deleteAsksChanged names: [String], added: Bool)
}

/// Runs at most `limit` bodies at once; the rest wait their turn.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiting.isEmpty {
                running -= 1
            } else {
                // The slot passes straight to the next one.
                waiting.removeFirst().resume()
            }
        }
        return await body()
    }
}

/// Which system monitors Watched Folders needs. With no folders, none: the
/// feature costs nothing while unused.
enum WatchMonitoring {
    struct Needs: Equatable, Sendable {
        /// Network changes: metered networks, and retrying once back online.
        var network = false
        /// Power source changes, only to pause on battery.
        var power = false
    }

    static func needs(folderCount: Int, pauseOnBattery: Bool) -> Needs {
        guard folderCount > 0 else { return Needs() }
        return Needs(network: true, power: pauseOnBattery)
    }
}

/// Watches one folder and uploads what lands in it. Events and scans only
/// say where to look; every decision is made from the file on disk and the
/// ledger:
///
/// 1. a file shows up (event, scan) and passes `WatchFileRules`;
/// 2. it's checked until it stops changing (`StabilityTracker`);
/// 3. the ledger says whether it's new, changed or renamed (`LedgerRules`);
/// 4. ready files are collected for a moment and enqueued together, or held
///    for a confirmation when there are too many;
/// 5. once uploaded, the original is kept, trashed, moved or tagged, and
///    the ledger records it.
///
/// It's event driven: idle, it holds one timer, for the hourly safety
/// scan, and work done in bulk (a scan, a drop of thousands of files)
/// updates counts and the timer once per run loop turn.
@MainActor
@Observable
final class FolderWatchEngine {
    enum Health: Equatable, Sendable {
        case ok
        case notFound
        /// The folder is there but can't be watched.
        case error(String)
    }

    private enum RunState {
        /// Not watching at all (turned off, no access).
        case stopped
        /// Watching for the folder's health, uploading nothing.
        case paused
        case running
    }

    private(set) var folder: WatchedFolder
    private(set) var health: Health = .ok
    private(set) var isRunning = false
    /// Files that appeared and are still being written, or about to be
    /// enqueued.
    private(set) var waitingCount = 0
    private(set) var uploadingCount = 0
    private(set) var failedCount = 0
    /// New files held until the user says Upload or Skip.
    private(set) var awaitingConfirmation = 0
    private(set) var lastUploadAt: Date?
    /// Uploads of deleted files waiting to be deleted from the bucket, or
    /// being deleted.
    private(set) var deletingCount = 0
    /// Uploads of deleted files held until the user says Delete or Keep.
    private(set) var awaitingDeleteConfirmation = 0
    /// Their file names.
    private(set) var awaitingDeleteNames: [String] = []

    @ObservationIgnored weak var delegate: WatchEngineDelegate?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var roots: [String]
    @ObservationIgnored private let ledger: WatchLedgerStore
    @ObservationIgnored private unowned let uploader: WatchUploading
    @ObservationIgnored private let timing: WatchTiming
    @ObservationIgnored private let ignoreOwnEvents: Bool
    @ObservationIgnored private let hasher: @Sendable (URL) -> String?
    @ObservationIgnored private let hashLimiter = AsyncLimiter(limit: 2)
    @ObservationIgnored private var runState: RunState = .stopped
    @ObservationIgnored private var stream: FolderEventStream?
    @ObservationIgnored private var ancestorWatcher: AncestorWatcher?
    @ObservationIgnored private var isNetworkVolume = false
    @ObservationIgnored private var options = InspectOptions()
    @ObservationIgnored private let snapshot = DirectorySnapshot()

    private struct Candidate {
        var tracker: StabilityTracker
        var nextCheck: Date
    }

    private struct ReadyFile {
        let relativePath: String
        let facts: FileFacts
        let sha256: String?
        let replacing: LedgerEntry?
    }

    private struct InFlight {
        let file: ReadyFile
        var batchID: UUID
        /// The upload is done; the ledger and "After upload" are being
        /// taken care of.
        var completing = false
    }

    private struct Batch {
        var remaining: Set<UUID>
        var uploads: [WatchedFileUpload] = []
        var failures: [WatchedFileFailure] = []
    }

    private struct DeleteBatch {
        var remaining: Set<String>
        var deleted: [String] = []
        var failures: [WatchedFileFailure] = []
    }

    /// What a scan found that the main actor has to look at.
    private struct ScanResult: Sendable {
        var files: [(path: String, facts: FileFacts)] = []
        /// Rows whose file is verifiably gone.
        var missing: [String] = []
        var changed = false
    }

    private enum ScanKind {
        case full
        case subtree(String)
        case networkPoll
    }

    @ObservationIgnored private var candidates: [String: Candidate] = [:]
    /// Candidates whose check is reading the disk right now.
    @ObservationIgnored private var checking: Set<String> = []
    /// Ready, being hashed or compared.
    @ObservationIgnored private var finalizing: Set<String> = []
    @ObservationIgnored private var readyBatch: [ReadyFile] = []
    @ObservationIgnored private var readyPaths: Set<String> = []
    @ObservationIgnored private var batchDeadline: Date?
    @ObservationIgnored private var awaiting: [ReadyFile] = []
    @ObservationIgnored private var awaitingPaths: Set<String> = []
    /// A large batch the user already agreed to (Upload Them when adding).
    @ObservationIgnored private var guardBypassUntil: Date?
    @ObservationIgnored private var inFlight: [UUID: InFlight] = [:]
    @ObservationIgnored private var inFlightByPath: [String: UUID] = [:]
    @ObservationIgnored private var batches: [UUID: Batch] = [:]
    @ObservationIgnored private var failedPaths: Set<String> = []
    /// Network failures and when they're tried again, by path.
    @ObservationIgnored private var retryDue: [String: Date] = [:]
    /// Remote deletes and when they're due, by path.
    @ObservationIgnored private var deleteDue: [String: Date] = [:]
    @ObservationIgnored private var deletesRunning: Set<String> = []
    @ObservationIgnored private var heldDeletes: Set<String> = [] {
        didSet { heldDeletesChanged = true }
    }
    @ObservationIgnored private var heldDeletesChanged = false
    /// Files found deleted together, checked against the large-deletion
    /// guard once the window closes.
    @ObservationIgnored private var goneBatch: [String] = []
    @ObservationIgnored private var goneBatchDeadline: Date?
    @ObservationIgnored private var deleteBatches: [UUID: DeleteBatch] = [:]
    @ObservationIgnored private var nextSafetyScan: Date?
    @ObservationIgnored private var nextNetworkPoll: Date?
    @ObservationIgnored private var networkPollInterval: TimeInterval = 30
    /// Scans run one at a time; these wait for the current one.
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var pendingFullScan = false
    @ObservationIgnored private var pendingSubtrees: Set<String> = []
    @ObservationIgnored private var pendingNetworkPoll = false
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var updateScheduled = false

    /// When the engine wakes up next, if at all; for tests.
    @ObservationIgnored private(set) var nextWakeup: Date?
    /// When the safety scan is due; for tests.
    var safetyScanDue: Date? { nextSafetyScan }
    /// How many full scans ran; for tests.
    @ObservationIgnored private(set) var fullScanCount = 0

    init(
        folder: WatchedFolder,
        root: URL? = nil,
        ledger: WatchLedgerStore,
        uploader: WatchUploading,
        timing: WatchTiming = .standard,
        ignoreOwnEvents: Bool = false,
        hasher: @escaping @Sendable (URL) -> String? = { try? ContentHasher.hashes(of: $0, md5: false, sha256: true).sha256 }
    ) {
        self.folder = folder
        self.root = root ?? folder.url
        self.roots = FileInspector.rootSpellings(root ?? folder.url)
        self.ledger = ledger
        self.uploader = uploader
        self.timing = timing
        self.ignoreOwnEvents = ignoreOwnEvents
        self.hasher = hasher
        lastUploadAt = ledger.lastUploadAt(folderID: folder.id)
        failedPaths = Set(ledger.paths(folderID: folder.id, state: .failed))
        failedCount = failedPaths.count
    }

    // MARK: - Running

    /// Starts uploading (and watching, if it wasn't), then looks at the
    /// whole folder once for anything that arrived meanwhile. `confirmed`
    /// uploads what that scan finds without asking, however many files.
    func start(confirmed: Bool = false) {
        guard runState != .running else { return }
        if runState == .stopped { setUpWatching() }
        runState = .running
        isRunning = true
        if confirmed { guardBypassUntil = Date().addingTimeInterval(120) }
        failedPaths = Set(ledger.paths(folderID: folder.id, state: .failed))
        loadRetries()
        loadDeletes()
        scheduleSafetyScan()
        if health == .ok { reconcile() }
        setNeedsUpdate()
    }

    /// Uploads nothing, but keeps watching the folder (cheaply: events are
    /// ignored), so resuming doesn't start from scratch. Resuming scans the
    /// folder once.
    func pause() {
        switch runState {
        case .paused: return
        case .stopped: setUpWatching()
        case .running: dropPendingWork()
        }
        runState = .paused
        isRunning = false
        setNeedsUpdate()
    }

    /// Stops watching. Uploads already queued carry on; files that were
    /// still waiting are found again by the next start's scan.
    func stop() {
        guard runState != .stopped else { return }
        runState = .stopped
        isRunning = false
        stream?.stop()
        stream = nil
        ancestorWatcher?.stop()
        ancestorWatcher = nil
        dropPendingWork()
        setNeedsUpdate()
    }

    private func dropPendingWork() {
        candidates = [:]
        checking = []
        readyBatch = []
        readyPaths = []
        batchDeadline = nil
        awaiting = []
        awaitingPaths = []
        retryDue = [:]
        deleteDue = [:]
        heldDeletes = []
        goneBatch = []
        goneBatchDeadline = nil
        nextSafetyScan = nil
        nextNetworkPoll = nil
        pendingFullScan = false
        pendingSubtrees = []
        pendingNetworkPoll = false
    }

    /// New settings for the folder (not a new path: that's a new engine).
    /// Its files are looked at again when the rules about them changed.
    func update(_ folder: WatchedFolder) {
        let rulesChanged = folder.subfolders != self.folder.subfolders
            || folder.filter != self.folder.filter || folder.includeCloudOnly != self.folder.includeCloudOnly
            || folder.modified != self.folder.modified || folder.deletesRemotely != self.folder.deletesRemotely
        self.folder = folder
        options = InspectOptions(folder: folder, root: root)
        guard rulesChanged, runState == .running else { return }
        candidates = [:]
        readyBatch = []
        readyPaths = []
        reconcile()
        setNeedsUpdate()
    }

    private func setUpWatching() {
        options = InspectOptions(folder: folder, root: root)
        if checkHealth() { startStream() }
    }

    private func startStream() {
        stream?.stop()
        stream = nil
        isNetworkVolume = FileInspector.isNetworkVolume(root)
        // Even a network volume reports what this Mac writes to it.
        stream = FolderEventStream(path: roots[0], ignoreSelf: ignoreOwnEvents) { [weak self] events in
            self?.handle(events)
        }
        if stream == nil {
            health = .error(String(localized: "Couldn't watch this folder for changes."))
        } else if case .error = health {
            health = .ok
        }
        if isNetworkVolume { networkPollInterval = timing.networkPoll }
    }

    /// Whether the folder is there. When it isn't, the folder above it is
    /// watched, and everything resumes once it's back: no polling.
    @discardableResult
    private func checkHealth() -> Bool {
        if FileInspector.isDirectory(root) {
            if health == .notFound {
                health = .ok
                ancestorWatcher?.stop()
                ancestorWatcher = nil
                roots = FileInspector.rootSpellings(root)
                startStream()
                if runState == .running { reconcile() }
                setNeedsUpdate()
            }
            return true
        }
        if health != .notFound {
            health = .notFound
            stream?.stop()
            stream = nil
            candidates = [:]
            checking = []
            readyBatch = []
            readyPaths = []
            setNeedsUpdate()
        }
        if ancestorWatcher == nil {
            ancestorWatcher = AncestorWatcher(path: root.path) { [weak self] in
                guard let self, self.runState != .stopped else { return }
                self.checkHealth()
            }
        }
        return false
    }

    /// Looks for the folder again now (a disk was mounted).
    func recheckHealth() {
        guard runState != .stopped else { return }
        if health == .notFound {
            checkHealth()
        } else if !FileInspector.isDirectory(root) {
            checkHealth()
        }
    }

    // MARK: - Events

    private func handle(_ events: [FolderEventStream.Event]) {
        guard runState != .stopped else { return }
        if events.contains(where: \.rootChanged) {
            guard checkHealth() else { return }
        }
        // Paused: nothing to do until resuming, which scans anyway.
        guard runState == .running else { return }
        var fullScan = false
        var subtrees: Set<String> = []
        var missing: [String] = []
        for event in events {
            if event.rootChanged { fullScan = true; continue }
            if event.needsRescan { fullScan = true }
            guard let relative = FileInspector.relativePath(event.path, roots: roots) else { continue }
            if event.isDirectory {
                // Only folders whose files could be uploaded, and only that
                // folder: not .git, node_modules/* when excluded, Uploaded.
                guard !WatchFileRules.isIgnoredDirectory(relativePath: relative, folder: folder),
                      !FileInspector.isInsidePackage(relative + "/x", root: root) else { continue }
                subtrees.insert(relative)
                continue
            }
            // The path's own rules first: no disk access for what they
            // leave out.
            guard WatchFileRules.rejection(relativePath: relative, facts: nil, folder: folder) == nil else { continue }
            switch FileInspector.inspect(URL(fileURLWithPath: event.path), options: options) {
            case .file(let facts): consider(relative, facts: facts, fromScan: false)
            case .missing: missing.append(relative)
            case .unreadable: break
            }
        }
        markGone(missing)
        // Activity: a network volume is polled often again for a while.
        if isNetworkVolume { networkPollInterval = timing.networkPoll }
        if fullScan {
            reconcile()
        } else {
            // A folder inside another one that's rescanned anyway adds nothing.
            for path in subtrees where !subtrees.contains(where: { ForbiddenFolders.contains($0, path) }) {
                scan(.subtree(path))
            }
        }
        setNeedsUpdate()
    }

    // MARK: - Scans

    /// Looks at every file in the folder: on start and resume, after a
    /// rescan event, on wake and as the hourly safety scan.
    func reconcile() {
        scan(.full)
    }

    /// Scans run off the main actor: walking, reading the files and
    /// comparing them with the ledger. The main actor only gets what could
    /// be new or changed, and what's gone.
    private func scan(_ kind: ScanKind) {
        guard runState == .running, health != .notFound else { return }
        if scanning {
            switch kind {
            case .full: pendingFullScan = true
            case .subtree(let path): pendingSubtrees.insert(path)
            case .networkPoll: pendingNetworkPoll = true
            }
            return
        }
        scanning = true
        if case .full = kind { fullScanCount += 1 }
        let root = self.root
        let folder = self.folder
        let options = self.options
        let ledger = self.ledger
        let snapshot = self.snapshot
        let network = isNetworkVolume
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.runScan(kind, root: root, folder: folder, options: options, ledger: ledger, snapshot: snapshot, network: network)
            }.value
            self?.finishScan(kind, result: result)
        }
    }

    private nonisolated static func runScan(
        _ kind: ScanKind,
        root: URL,
        folder: WatchedFolder,
        options: InspectOptions,
        ledger: WatchLedgerStore,
        snapshot: DirectorySnapshot,
        network: Bool
    ) -> ScanResult? {
        let recursive = folder.subfolders != .ignore
        var files: [(path: String, facts: FileFacts)]
        var gone: [String]? = nil
        var prefix: String? = nil
        switch kind {
        case .full where network:
            // Primes the snapshot the polls compare against.
            snapshot.reset()
            guard let changes = snapshot.poll(root, recursive: recursive, options: options) else { return nil }
            files = changes.files
        case .full:
            guard let walked = FileInspector.walk(root, recursive: recursive, options: options) else { return nil }
            files = walked
        case .subtree(let path):
            prefix = path + "/"
            if let walked = FileInspector.walk(root, subpath: path, recursive: true, options: options) {
                files = walked
            } else if FileInspector.canList(root), FileInspector.isMissing(root.appendingPathComponent(path)) {
                // The folder was deleted or moved away with its files.
                files = []
            } else {
                return nil
            }
        case .networkPoll:
            guard let changes = snapshot.poll(root, recursive: recursive, options: options) else { return nil }
            files = changes.files
            gone = changes.removed
        }

        let rows = ledger.snapshot(folderID: folder.id)
        var result = ScanResult()
        for file in files {
            guard WatchFileRules.rejection(relativePath: file.path, facts: Self.checked(file.facts, folder), folder: folder) == nil else { continue }
            if let row = rows[file.path], Self.isSettled(row, facts: file.facts, policy: folder.modified) { continue }
            result.files.append(file)
        }
        let candidatesForGone: [String]
        if let gone {
            candidatesForGone = gone.filter { rows[$0].map { Self.canGo($0.state) } ?? false }
        } else {
            let present = Set(files.map(\.path))
            candidatesForGone = rows.compactMap { path, row in
                guard Self.canGo(row.state), !present.contains(path) else { return nil }
                if let prefix, !path.hasPrefix(prefix) { return nil }
                return path
            }
        }
        // A row is only gone when its file verifiably is: rules that
        // changed (subfolders now ignored) mean it wasn't walked, not gone.
        if FileInspector.canList(root) {
            result.missing = candidatesForGone.filter { FileInspector.isMissing(root.appendingPathComponent($0)) }
        }
        result.changed = !result.files.isEmpty || !result.missing.isEmpty
        return result
    }

    /// A row the file on disk can't change anything about.
    private nonisolated static func isSettled(_ row: LedgerSnapshot, facts: FileFacts, policy: ModifiedPolicy) -> Bool {
        switch row.state {
        case .skipped, .failed:
            return true
        case .uploaded:
            return policy == .ignore
                || (row.size == facts.size && abs(row.mtime - facts.modified.timeIntervalSince1970) < 0.001)
        case .pending, .gone:
            return false
        }
    }

    private func finishScan(_ kind: ScanKind, result: ScanResult?) {
        scanning = false
        guard runState == .running else { return }
        if let result {
            for file in result.files { consider(file.path, facts: file.facts, fromScan: true) }
            markGone(result.missing)
            if case .networkPoll = kind {
                networkPollInterval = result.changed ? timing.networkPoll : min(networkPollInterval * 2, 300)
            }
        }
        if case .full = kind {
            ledger.purgeGone(folderID: folder.id, before: Date().addingTimeInterval(-timing.goneRetention))
        }
        if isNetworkVolume {
            switch kind {
            case .full, .networkPoll: nextNetworkPoll = Date().addingTimeInterval(networkPollInterval)
            case .subtree: break
            }
        }
        // What waited for this scan.
        if pendingFullScan {
            pendingFullScan = false
            pendingSubtrees = []
            scan(.full)
        } else if let next = pendingSubtrees.first {
            pendingSubtrees.remove(next)
            scan(.subtree(next))
        } else if pendingNetworkPoll {
            pendingNetworkPoll = false
            scan(.networkPoll)
        }
        setNeedsUpdate()
    }

    private func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private nonisolated static func checked(_ facts: FileFacts, _ folder: WatchedFolder) -> FileFacts {
        // An online-only file is downloaded, then treated like any other.
        var checked = facts
        if facts.isCloudOnly, folder.includeCloudOnly { checked.isCloudOnly = false }
        return checked
    }

    /// A file that might be new. Ones that are already being followed,
    /// handled before or filtered out stop here.
    private func consider(_ relativePath: String, facts: FileFacts, fromScan: Bool) {
        guard runState == .running, candidates[relativePath] == nil, !finalizing.contains(relativePath),
              !readyPaths.contains(relativePath), !awaitingPaths.contains(relativePath),
              inFlightByPath[relativePath] == nil else { return }
        guard WatchFileRules.rejection(relativePath: relativePath, facts: Self.checked(facts, folder), folder: folder) == nil else { return }
        // A scan doesn't go into packages in the first place.
        if !fromScan, relativePath.contains("/"), FileInspector.isInsidePackage(relativePath, root: root) { return }

        switch decide(relativePath, facts: facts, entry: ledger.entry(folderID: folder.id, relativePath: relativePath)).decision {
        case .skip, .failedEarlier, .reappeared:
            return
        case .renamed(let entry):
            applyRename(from: entry, to: relativePath)
            return
        case .upload, .uploadChanged, .needsHash:
            break
        }
        if facts.isCloudOnly {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url(for: relativePath))
        }
        var tracker = StabilityTracker(timing: timing)
        let now = Date()
        let verdict = tracker.observe(.init(size: facts.size, modified: facts.modified), now: now)
        let delay: TimeInterval = if case .wait(let seconds) = verdict { seconds } else { timing.stabilityInitial }
        candidates[relativePath] = Candidate(tracker: tracker, nextCheck: now.addingTimeInterval(delay))
        setNeedsUpdate()
    }

    /// The ledger's decision for a file on disk. A file that arrived at the
    /// path of a deleted one calls off the remote delete of the old one
    /// first; one that came back within the grace period is the same file
    /// again, and is decided as such.
    private func decide(_ path: String, facts: FileFacts, entry: LedgerEntry?, sha256: String? = nil) -> (decision: LedgerDecision, entry: LedgerEntry?) {
        var entry = entry
        if var gone = entry, gone.state == .gone, gone.remoteDelete != .none {
            gone.remoteDelete = .none
            ledger.upsert(gone)
            cancelDelete(path)
            entry = gone
        }
        let renames = entry == nil ? facts.fileID.map { ledger.entries(folderID: folder.id, fileID: $0) } ?? [] : []
        func run(_ entry: LedgerEntry?) -> LedgerDecision {
            LedgerRules.decide(
                size: facts.size,
                modified: facts.modified,
                fileID: facts.fileID,
                entry: entry,
                modifiedPolicy: folder.modified,
                renameCandidates: renames,
                pathExists: { [root] in !FileInspector.isMissing(root.appendingPathComponent($0)) },
                sha256: sha256,
                grace: timing.deleteGrace
            )
        }
        let decision = run(entry)
        guard case .reappeared(let restored) = decision else { return (decision, entry) }
        ledger.upsert(restored)
        return (run(restored), restored)
    }

    /// The same file under a new path. A deleted one is back: its remote
    /// delete is called off.
    private func applyRename(from moved: LedgerEntry, to path: String) {
        ledger.move(folderID: folder.id, from: moved.relativePath, to: path)
        cancelDelete(moved.relativePath)
        if moved.state == .gone, var entry = ledger.entry(folderID: folder.id, relativePath: path) {
            entry.state = moved.stateBeforeGone
            entry.goneAt = nil
            entry.remoteDelete = .none
            ledger.upsert(entry)
        }
    }

    // MARK: - Timer and updates

    /// Counts and the timer are brought up to date once per run loop turn,
    /// however many files changed in it.
    private func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushUpdates() }
        }
    }

    private func flushUpdates() {
        updateScheduled = false
        updateCounts()
        reschedule()
    }

    private func scheduleSafetyScan() {
        // A different moment for every folder, so they don't all wake at once.
        nextSafetyScan = Date().addingTimeInterval(timing.safetyScan + Double.random(in: 0...(timing.safetyScan * 0.15)))
    }

    /// One deadline timer, for the earliest moment something is really due.
    /// Idle, that's the safety scan.
    private func reschedule() {
        guard runState == .running, health != .notFound else {
            cancelTimer()
            return
        }
        var next: Date?
        func consider(_ date: Date?) {
            guard let date else { return }
            next = next.map { min($0, date) } ?? date
        }
        for (path, candidate) in candidates where !checking.contains(path) { consider(candidate.nextCheck) }
        consider(batchDeadline)
        consider(goneBatchDeadline)
        consider(retryDue.values.min())
        consider(deleteDue.values.min())
        consider(nextSafetyScan)
        if isNetworkVolume { consider(nextNetworkPoll) }
        guard let next else {
            cancelTimer()
            return
        }
        if next == nextWakeup, timerTask != nil { return }
        timerTask?.cancel()
        nextWakeup = next
        let delay = max(next.timeIntervalSinceNow, 0)
        // Short timers may fire a little late; the safety scan a minute.
        let tolerance = next == nextSafetyScan ? 60 : max(0.1, delay * 0.1)
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(tolerance))
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        nextWakeup = nil
    }

    private func timerFired() {
        timerTask = nil
        nextWakeup = nil
        guard runState == .running, health != .notFound else { return }
        let now = Date()

        let due = candidates.filter { $0.value.nextCheck <= now && !checking.contains($0.key) }.map(\.key)
        if !due.isEmpty { check(due) }
        if let batchDeadline, batchDeadline <= now {
            self.batchDeadline = nil
            flushBatch()
        }
        let dueRetries = retryDue.filter { $0.value <= now }.map(\.key)
        if !dueRetries.isEmpty {
            for path in dueRetries { retryDue[path] = nil }
            retry(paths: dueRetries)
        }
        var dueDeletes = deleteDue.filter { $0.value <= now }.map(\.key)
        // A folder that asks first asks once about deletions close together.
        if !dueDeletes.isEmpty, folder.deletesRemotely, folder.confirmDelete {
            dueDeletes = deleteDue.filter { $0.value <= now.addingTimeInterval(timing.batchWindow) }.map(\.key)
        }
        // The large-deletion guard always looks at deletions before any of
        // them runs.
        if let goneBatchDeadline, goneBatchDeadline <= now || dueDeletes.contains(where: goneBatch.contains) {
            self.goneBatchDeadline = nil
            flushGoneBatch()
        }
        let stillDue = dueDeletes.filter { deleteDue[$0] != nil }
        if !stillDue.isEmpty {
            for path in stillDue { deleteDue[path] = nil }
            runDeletes(stillDue)
        }
        if let nextSafetyScan, nextSafetyScan <= now {
            scheduleSafetyScan()
            // Low Power Mode: the backstop waits for another round.
            if !ProcessInfo.processInfo.isLowPowerModeEnabled { reconcile() }
        }
        if isNetworkVolume, let nextNetworkPoll, nextNetworkPoll <= now {
            self.nextNetworkPoll = nil
            scan(.networkPoll)
        }
        setNeedsUpdate()
    }

    /// Checks candidates whose time came: the disk is read off the main
    /// actor, the verdicts are applied here.
    private func check(_ paths: [String]) {
        checking.formUnion(paths)
        let root = self.root
        let options = self.options
        Task { [weak self] in
            let looks = await Task.detached(priority: .utility) {
                paths.map { ($0, FileInspector.inspect(root.appendingPathComponent($0), options: options)) }
            }.value
            self?.applyChecks(looks)
        }
    }

    private func applyChecks(_ looks: [(String, Inspection)]) {
        let now = Date()
        for (path, look) in looks {
            checking.remove(path)
            guard var candidate = candidates[path] else { continue }
            guard case .file(let facts) = look,
                  WatchFileRules.rejection(relativePath: path, facts: Self.checked(facts, folder), folder: folder) == nil else {
                candidates[path] = nil
                continue
            }
            switch candidate.tracker.observe(.init(size: facts.size, modified: facts.modified), now: now) {
            case .ready where !facts.isCloudOnly:
                candidates[path] = nil
                finalize(path, facts: facts)
            case .ready:
                // Still downloading from iCloud.
                candidate.nextCheck = now.addingTimeInterval(timing.stabilityInitial)
                candidates[path] = candidate
            case .wait(let delay):
                candidate.nextCheck = now.addingTimeInterval(delay)
                candidates[path] = candidate
            }
        }
        setNeedsUpdate()
    }

    /// A file that stopped changing: the ledger decides. Only a file that
    /// changed since its upload, under a folder that reacts to changes, is
    /// hashed here (two at a time); new files are hashed by the upload.
    private func finalize(_ path: String, facts: FileFacts) {
        let (decision, entry) = decide(path, facts: facts, entry: ledger.entry(folderID: folder.id, relativePath: path))
        guard decision == .needsHash else {
            act(on: decision, path: path, facts: facts, entry: entry, sha256: nil)
            return
        }
        finalizing.insert(path)
        let fileURL = url(for: path)
        let hasher = self.hasher
        let limiter = hashLimiter
        Task { [weak self] in
            let sha256 = await limiter.run { await Task.detached(priority: .utility) { hasher(fileURL) }.value }
            guard let self else { return }
            self.finalizing.remove(path)
            guard self.runState == .running else { return }
            // The ledger may have moved on while hashing.
            let (decision, entry) = self.decide(path, facts: facts, entry: self.ledger.entry(folderID: self.folder.id, relativePath: path), sha256: sha256)
            self.act(on: decision, path: path, facts: facts, entry: entry, sha256: sha256)
        }
    }

    private func act(on decision: LedgerDecision, path: String, facts: FileFacts, entry: LedgerEntry?, sha256: String?) {
        switch decision {
        case .upload:
            addReady(ReadyFile(relativePath: path, facts: facts, sha256: sha256, replacing: entry?.state == .pending ? entry : nil))
        case .uploadChanged(let previous):
            addReady(ReadyFile(relativePath: path, facts: facts, sha256: sha256, replacing: previous))
        case .renamed(let moved):
            applyRename(from: moved, to: path)
        case .skip(let refresh):
            if refresh, var entry {
                entry.size = facts.size
                entry.mtime = facts.modified.timeIntervalSince1970
                if let sha256 { entry.sha256 = sha256 }
                ledger.upsert(entry)
            }
        case .needsHash, .failedEarlier, .reappeared:
            break
        }
        setNeedsUpdate()
    }

    private func addReady(_ file: ReadyFile) {
        readyBatch.append(file)
        readyPaths.insert(file.relativePath)
        batchDeadline = Date().addingTimeInterval(timing.batchWindow)
    }

    // MARK: - Batches

    /// The batch window closed. Too many files at once wait for the user,
    /// in case the folder was a mistake or a whole archive was dropped in.
    private func flushBatch() {
        let files = readyBatch
        readyBatch = []
        readyPaths = []
        guard !files.isEmpty else { return }
        dropMissingAwaiting()
        let bypass = guardBypassUntil.map { $0 > Date() } ?? false
        if !awaiting.isEmpty || (files.count > timing.largeBatch && !bypass) {
            awaiting.append(contentsOf: files)
            awaitingPaths.formUnion(files.map(\.relativePath))
            updateCounts()
            delegate?.engine(self, needsConfirmation: awaiting.count)
            return
        }
        enqueue(files)
    }

    /// Upload on the large-batch prompt.
    func confirmPending() {
        dropMissingAwaiting()
        let files = awaiting
        awaiting = []
        awaitingPaths = []
        enqueue(files)
        updateCounts()
    }

    /// Skip on the large-batch prompt: the files are remembered as handled
    /// and left where they are.
    func skipPending() {
        dropMissingAwaiting()
        let entries = awaiting.map { file in
            LedgerEntry(
                folderID: folder.id,
                relativePath: file.relativePath,
                size: file.facts.size,
                mtime: file.facts.modified.timeIntervalSince1970,
                fileID: file.facts.fileID,
                sha256: file.sha256,
                state: .skipped
            )
        }
        awaiting = []
        awaitingPaths = []
        ledger.upsert(entries)
        updateCounts()
    }

    var awaitingFiles: Int { awaiting.count }

    /// Held files that are no longer on disk leave the large-batch ask, so
    /// a stale ask doesn't hold every later file back, and Upload or Skip
    /// only apply to files that are still there.
    private func dropMissingAwaiting() {
        guard !awaiting.isEmpty, FileInspector.canList(root) else { return }
        withdrawAwaiting(Set(awaiting.lazy.map(\.relativePath).filter { FileInspector.isMissing(self.root.appendingPathComponent($0)) }))
    }

    private func withdrawAwaiting(_ paths: Set<String>) {
        guard !awaitingPaths.isDisjoint(with: paths) else { return }
        awaiting.removeAll { paths.contains($0.relativePath) }
        awaitingPaths.subtract(paths)
        updateCounts()
        if awaiting.isEmpty { delegate?.engine(self, needsConfirmation: 0) }
    }

    private func enqueue(_ files: [ReadyFile]) {
        guard !files.isEmpty else { return }
        let batchID = UUID()
        var requests: [WatchUploadRequest] = []
        var pending: [LedgerEntry] = []
        var ids: Set<UUID> = []
        for file in files {
            let id = UUID()
            ids.insert(id)
            inFlight[id] = InFlight(file: file, batchID: batchID)
            inFlightByPath[file.relativePath] = id
            failedPaths.remove(file.relativePath)
            requests.append(request(id: id, file: file))
            // Pending until it's done, keeping what the earlier upload of
            // this path left (its key, for replacing it).
            pending.append(LedgerEntry(
                folderID: folder.id,
                relativePath: file.relativePath,
                size: file.facts.size,
                mtime: file.facts.modified.timeIntervalSince1970,
                fileID: file.facts.fileID,
                sha256: file.sha256,
                state: .pending,
                attempts: file.replacing?.state == .failed ? file.replacing?.attempts ?? 0 : 0,
                objectKey: file.replacing?.objectKey,
                url: file.replacing?.url,
                destinationID: file.replacing?.destinationID
            ))
        }
        batches[batchID] = Batch(remaining: ids)
        ledger.upsert(pending)
        setNeedsUpdate()
        uploader.enqueue(requests)
    }

    private func request(id: UUID, file: ReadyFile) -> WatchUploadRequest {
        let overwrite = folder.modified == .overwrite ? file.replacing?.objectKey : nil
        return WatchUploadRequest(
            id: id,
            folder: folder,
            fileURL: url(for: file.relativePath),
            relativePath: file.relativePath,
            subpath: WatchKeys.subpath(relativePath: file.relativePath, mode: folder.subfolders),
            overwriteKey: overwrite,
            sha256: file.sha256,
            wantsContentHash: folder.modified != .ignore,
            fileID: file.facts.fileID
        )
    }

    // MARK: - Results

    /// Called by the upload queue for every upload this engine asked for.
    func uploadFinished(requestID: UUID, outcome: WatchUploadOutcome) {
        guard var flight = inFlight[requestID] else { return }
        let path = flight.file.relativePath
        switch outcome {
        case .succeeded(let success):
            guard !flight.completing else { return }
            flight.completing = true
            inFlight[requestID] = flight
            Task {
                await self.completeSuccess(flight, requestID: requestID, success: success)
                self.removeInFlight(requestID)
                self.setNeedsUpdate()
            }
        case .failed(let message, let retryable):
            removeInFlight(requestID)
            var entry = ledger.entry(folderID: folder.id, relativePath: path) ?? pendingEntry(for: flight.file)
            entry.state = .failed
            entry.attempts += 1
            entry.lastError = message
            entry.retryable = retryable
            entry.handledAt = Date()
            ledger.upsert(entry)
            failedPaths.insert(path)
            if retryable, runState == .running {
                retryDue[path] = Date().addingTimeInterval(timing.retryDelay(afterAttempts: entry.attempts))
            }
            let failure = WatchedFileFailure(folder: folder, relativePath: path, message: message, isFirstFailure: entry.attempts == 1)
            settle(requestID: requestID, batchID: flight.batchID) { $0.failures.append(failure) }
        case .cancelled:
            removeInFlight(requestID)
            var entry = pendingEntry(for: flight.file)
            entry.state = .skipped
            ledger.upsert(entry)
            settle(requestID: requestID, batchID: flight.batchID) { _ in }
        }
        setNeedsUpdate()
    }

    private func removeInFlight(_ requestID: UUID) {
        guard let flight = inFlight.removeValue(forKey: requestID) else { return }
        if inFlightByPath[flight.file.relativePath] == requestID {
            inFlightByPath[flight.file.relativePath] = nil
        }
    }

    private func pendingEntry(for file: ReadyFile) -> LedgerEntry {
        LedgerEntry(
            folderID: folder.id,
            relativePath: file.relativePath,
            size: file.facts.size,
            mtime: file.facts.modified.timeIntervalSince1970,
            fileID: file.facts.fileID,
            sha256: file.sha256,
            state: .pending
        )
    }

    /// Records the upload, then applies "After upload". The original is
    /// only moved away when it's still the file that was uploaded and the
    /// bucket confirms it has every byte.
    private func completeSuccess(_ flight: InFlight, requestID: UUID, success: WatchUploadSuccess) async {
        let file = flight.file
        let fileURL = url(for: file.relativePath)
        var entry = pendingEntry(for: file)
        entry.state = .uploaded
        entry.sha256 = success.contentHash ?? file.sha256
        entry.objectKey = success.objectKey
        entry.url = success.publicURL
        entry.destinationID = success.destinationID
        entry.reused = success.reused
        let now = Date()
        entry.handledAt = now
        ledger.recordUpload(entry, at: now)
        retryDue[file.relativePath] = nil
        failedPaths.remove(file.relativePath)
        lastUploadAt = now

        let action = folder.afterUpload
        if action != .keep {
            await apply(action, to: fileURL, file: file, success: success)
        }
        let upload = WatchedFileUpload(folder: folder, relativePath: file.relativePath, fileURL: fileURL, size: file.facts.size, success: success)
        delegate?.engine(self, didUpload: upload)
        settle(requestID: requestID, batchID: flight.batchID) { $0.uploads.append(upload) }
    }

    private func apply(_ action: AfterUploadAction, to fileURL: URL, file: ReadyFile, success: WatchUploadSuccess) async {
        guard let current = FileInspector.facts(at: fileURL), !current.isSymlink,
              current.fileID == file.facts.fileID,
              current.size == file.facts.size, current.modified == file.facts.modified else {
            // Changed, replaced (or gone) since it was uploaded: leave it
            // alone.
            return
        }
        switch action {
        case .keep:
            return
        case .tag:
            do {
                try WatchFileActions.addTag(to: fileURL)
            } catch {
                delegate?.engine(self, reportError: String(localized: "Couldn't tag \(fileURL.lastPathComponent): \(error.localizedDescription)"))
            }
        case .trash, .moveToUploaded:
            guard await uploader.verifyUploaded(key: success.objectKey, destinationID: success.destinationID, size: success.byteSize) else {
                delegate?.engine(self, reportError: String(localized: "Kept \(fileURL.lastPathComponent): the bucket couldn't confirm the upload."))
                return
            }
            // The ledger moves first, so the file disappearing from its path
            // isn't taken for the user deleting it.
            let entry = ledger.entry(folderID: folder.id, relativePath: file.relativePath)
            do {
                if action == .trash {
                    ledger.delete(folderID: folder.id, relativePath: file.relativePath)
                    try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                } else {
                    let folderURL = root.appendingPathComponent(WatchFileRules.uploadedFolderName, isDirectory: true)
                    // Never into a link to some other folder.
                    if case .file(let existing) = FileInspector.inspect(folderURL), existing.isSymlink || existing.isRegularFile {
                        throw WatchFileActionError.uploadedFolderNotAFolder
                    }
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    let target = WatchFileActions.freeName(for: fileURL.lastPathComponent, in: folderURL)
                    let targetPath = WatchFileRules.uploadedFolderName + "/" + target.lastPathComponent
                    ledger.move(folderID: folder.id, from: file.relativePath, to: targetPath)
                    do {
                        try FileManager.default.moveItem(at: fileURL, to: target)
                    } catch {
                        ledger.delete(folderID: folder.id, relativePath: targetPath)
                        throw error
                    }
                }
            } catch {
                if let entry { ledger.upsert(entry) }
                delegate?.engine(self, reportError: String(localized: "Couldn't move \(fileURL.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    /// Updated in place: a batch of thousands is never copied per file.
    private func settle(requestID: UUID, batchID: UUID, _ update: (inout Batch) -> Void) {
        if batches[batchID] == nil { batches[batchID] = Batch(remaining: [requestID]) }
        update(&batches[batchID]!)
        batches[batchID]!.remaining.remove(requestID)
        guard batches[batchID]!.remaining.isEmpty, let batch = batches.removeValue(forKey: batchID) else { return }
        delegate?.engine(self, didSettle: WatchBatchSummary(folder: folder, uploads: batch.uploads, failures: batch.failures))
    }

    // MARK: - Retrying

    private func loadRetries() {
        retryDue = [:]
        for entry in ledger.entries(folderID: folder.id, state: .failed) where entry.retryable {
            retryDue[entry.relativePath] = entry.handledAt.addingTimeInterval(timing.retryDelay(afterAttempts: entry.attempts))
        }
    }

    /// Retry Failed on the folder: everything that failed, now.
    func retryFailed() {
        retry(paths: Array(failedPaths))
    }

    /// Back online: network failures are retried now instead of on their
    /// schedule.
    func retryNetworkFailures() {
        guard runState == .running else { return }
        let paths = Array(retryDue.keys)
        retryDue = [:]
        retry(paths: paths)
        retryDeletesNow()
        setNeedsUpdate()
    }

    private func retry(paths: [String]) {
        guard runState == .running else { return }
        var fresh: [ReadyFile] = []
        for path in paths where inFlightByPath[path] == nil {
            retryDue[path] = nil
            guard let entry = ledger.entry(folderID: folder.id, relativePath: path), entry.state == .failed else {
                failedPaths.remove(path)
                continue
            }
            guard let facts = FileInspector.facts(at: url(for: path), options: options), facts.isRegularFile else {
                // Gone since: nothing to retry.
                ledger.delete(folderID: folder.id, relativePath: path)
                failedPaths.remove(path)
                continue
            }
            fresh.append(ReadyFile(relativePath: path, facts: facts, sha256: entry.sha256, replacing: entry))
        }
        enqueue(fresh)
        setNeedsUpdate()
    }

    // MARK: - Deleted files

    /// Rows whose file can be found deleted: handled ones (a pending one is
    /// still uploading, a gone one already is).
    private nonisolated static func canGo(_ state: LedgerEntry.State) -> Bool {
        state == .uploaded || state == .skipped || state == .failed
    }

    /// Marks the rows of `paths`, whose files are verifiably gone from
    /// disk, in one transaction, and schedules deleting their uploads when
    /// the folder does that. Nothing is marked unless the folder itself is
    /// there and readable: a missing, unmounted or locked folder hasn't
    /// lost its files.
    private func markGone(_ paths: [String]) {
        guard !paths.isEmpty, runState == .running, health == .ok, FileInspector.canList(root) else { return }
        withdrawAwaiting(Set(paths))
        let now = Date()
        let result = ledger.markGone(
            folderID: folder.id,
            paths: paths.filter { inFlightByPath[$0] == nil },
            at: now,
            deleteRemotely: folder.deletesRemotely
        )
        for path in result.forgotten {
            failedPaths.remove(path)
            retryDue[path] = nil
        }
        for path in result.scheduled {
            deleteDue[path] = now.addingTimeInterval(timing.deleteGrace)
            goneBatch.append(path)
        }
        if !goneBatch.isEmpty, goneBatchDeadline == nil {
            goneBatchDeadline = now.addingTimeInterval(min(timing.batchWindow, timing.deleteGrace / 2))
        }
        setNeedsUpdate()
    }

    /// Calls off a remote delete that hasn't run yet (the file came back,
    /// or was renamed).
    private func cancelDelete(_ path: String) {
        deleteDue[path] = nil
        if goneBatch.contains(path) { goneBatch.removeAll { $0 == path } }
        // An ask about it is withdrawn.
        if heldDeletes.remove(path) != nil {
            updateCounts()
            delegate?.engine(self, deleteAsksChanged: awaitingDeleteNames, added: false)
        }
    }

    private func loadDeletes() {
        deleteDue = [:]
        heldDeletes = []
        let now = Date()
        for entry in ledger.entries(folderID: folder.id, state: .gone) {
            switch entry.remoteDelete {
            case .scheduled, .confirmed:
                let due = entry.attempts > 0
                    ? entry.handledAt.addingTimeInterval(timing.retryDelay(afterAttempts: entry.attempts))
                    : (entry.goneAt ?? now).addingTimeInterval(timing.deleteGrace)
                deleteDue[entry.relativePath] = max(due, now)
            case .awaitingConfirmation:
                heldDeletes.insert(entry.relativePath)
            case .none:
                break
            }
        }
    }

    /// The window for deletions found together closed. Too many at once (or
    /// most of the folder) look like a folder emptied by mistake or a disk
    /// problem, so their uploads wait for the user.
    private func flushGoneBatch() {
        let batch = goneBatch.filter { deleteDue[$0] != nil }
        goneBatch = []
        guard !batch.isEmpty else { return }
        let uploaded = ledger.count(folderID: folder.id, state: .uploaded) + batch.count
        let large = batch.count > timing.largeDeletion || (batch.count >= 10 && batch.count * 2 > uploaded)
        guard large || !heldDeletes.isEmpty else { return }
        for path in batch { deleteDue[path] = nil }
        heldDeletes.formUnion(batch)
        ledger.setRemoteDelete(.awaitingConfirmation, folderID: folder.id, paths: batch)
        updateCounts()
        delegate?.engine(self, deleteAsksChanged: awaitingDeleteNames, added: true)
    }

    /// The deletions waiting for an answer: kept in memory while watching,
    /// in the ledger always (so an answer from a notification works while
    /// the folder is paused too).
    private func askedPaths() -> [String] {
        Array(heldDeletes.union(ledger.entries(folderID: folder.id, state: .gone)
            .filter { $0.remoteDelete == .awaitingConfirmation }
            .map(\.relativePath)))
    }

    /// Delete from Bucket, on the banner or the notification.
    func confirmPendingDeletes() {
        let now = Date()
        let paths = askedPaths()
        ledger.setRemoteDelete(.confirmed, folderID: folder.id, paths: paths)
        if runState == .running {
            for path in paths { deleteDue[path] = now }
        }
        heldDeletes = []
        updateCounts()
        delegate?.engine(self, deleteAsksChanged: [], added: false)
        setNeedsUpdate()
    }

    /// Keep Uploaded Files: the files stay deleted locally, their uploads
    /// stay in the bucket.
    func keepPendingDeletes() {
        ledger.setRemoteDelete(.none, folderID: folder.id, paths: askedPaths())
        heldDeletes = []
        updateCounts()
        delegate?.engine(self, deleteAsksChanged: [], added: false)
    }

    /// Deletes the uploads of files that stayed deleted through the grace
    /// period, unless the upload isn't theirs alone: a reused link, or an
    /// object other rows or history entries point at too.
    private func runDeletes(_ paths: [String]) {
        guard runState == .running else { return }
        let batchID = UUID()
        var started: Set<String> = []
        var asked: [String] = []
        var skipped: [String] = []
        for path in paths {
            guard let entry = ledger.entry(folderID: folder.id, relativePath: path), entry.state == .gone,
                  entry.remoteDelete == .scheduled || entry.remoteDelete == .confirmed else { continue }
            guard folder.deletesRemotely, let key = entry.objectKey, let destinationID = entry.destinationID,
                  !entry.reused,
                  ledger.otherReferences(destinationID: destinationID, objectKey: key, excludingFolderID: folder.id, relativePath: path) == 0,
                  !uploader.isReferencedInHistory(key: key, destinationID: destinationID, folderID: folder.id),
                  FileInspector.isMissing(url(for: path)) else {
                skipped.append(path)
                continue
            }
            // A folder that asks first: nothing goes without an answer, and
            // an unanswered ask stays until the file comes back.
            if folder.confirmDelete, entry.remoteDelete == .scheduled {
                asked.append(path)
                continue
            }
            started.insert(path)
            deletesRunning.insert(path)
            let folderID = folder.id
            let firstTry = entry.attempts == 0
            Task {
                let outcome = await self.uploader.deleteUpload(key: key, destinationID: destinationID, folderID: folderID)
                self.finishDelete(path, outcome: outcome, batchID: batchID, firstTry: firstTry)
            }
        }
        ledger.setRemoteDelete(.none, folderID: folder.id, paths: skipped)
        if !asked.isEmpty {
            ledger.setRemoteDelete(.awaitingConfirmation, folderID: folder.id, paths: asked)
            heldDeletes.formUnion(asked)
        }
        if !started.isEmpty { deleteBatches[batchID] = DeleteBatch(remaining: started) }
        updateCounts()
        if !asked.isEmpty { delegate?.engine(self, deleteAsksChanged: awaitingDeleteNames, added: true) }
        setNeedsUpdate()
    }

    private func finishDelete(_ path: String, outcome: WatchDeleteOutcome, batchID: UUID, firstTry: Bool) {
        deletesRunning.remove(path)
        let name = (path as NSString).lastPathComponent
        if deleteBatches[batchID] == nil { deleteBatches[batchID] = DeleteBatch(remaining: [path]) }
        deleteBatches[batchID]!.remaining.remove(path)
        if var entry = ledger.entry(folderID: folder.id, relativePath: path), entry.state == .gone {
            switch outcome {
            case .deleted:
                entry.remoteDelete = .none
                entry.objectKey = nil
                entry.url = nil
                ledger.upsert(entry)
                deleteBatches[batchID]!.deleted.append(name)
                delegate?.engine(self, didDeleteRemote: name)
            case .failed(let message, let retryable):
                entry.attempts += 1
                entry.lastError = message
                entry.retryable = retryable
                entry.handledAt = Date()
                entry.remoteDelete = retryable ? entry.remoteDelete : .none
                ledger.upsert(entry)
                if retryable, runState == .running {
                    deleteDue[path] = Date().addingTimeInterval(timing.retryDelay(afterAttempts: entry.attempts))
                }
                deleteBatches[batchID]!.failures.append(WatchedFileFailure(folder: folder, relativePath: path, message: message, isFirstFailure: firstTry))
            }
        }
        if deleteBatches[batchID]!.remaining.isEmpty, let batch = deleteBatches.removeValue(forKey: batchID),
           !batch.deleted.isEmpty || !batch.failures.isEmpty {
            delegate?.engine(self, didSettleDeletes: WatchDeleteSummary(folder: folder, deleted: batch.deleted, failures: batch.failures))
        }
        setNeedsUpdate()
    }

    /// Back online: remote deletes waiting for a retry go now.
    private func retryDeletesNow() {
        let now = Date()
        for path in deleteDue.keys {
            if let entry = ledger.entry(folderID: folder.id, relativePath: path), entry.attempts > 0 {
                deleteDue[path] = now
            }
        }
    }

    // MARK: - Folder actions

    /// Upload Pending Now: files still settling are checked right away,
    /// the batch window closes and held files go up.
    func uploadPendingNow() {
        guard runState == .running else { return }
        let now = Date()
        for path in candidates.keys {
            candidates[path]?.tracker.expedite()
            candidates[path]?.nextCheck = now
        }
        if !readyBatch.isEmpty { batchDeadline = now }
        guardBypassUntil = now.addingTimeInterval(5)
        if !awaiting.isEmpty { confirmPending() }
        reconcile()
        setNeedsUpdate()
    }

    /// Reset: forgets every file handled here, so they count as new again,
    /// and looks at the folder again.
    func reset() {
        ledger.deleteAll(folderID: folder.id)
        lastUploadAt = nil
        failedPaths = []
        retryDue = [:]
        deleteDue = [:]
        heldDeletes = []
        goneBatch = []
        goneBatchDeadline = nil
        updateCounts()
        if runState == .running { reconcile() }
    }

    private func updateCounts() {
        let waiting = candidates.count + finalizing.count + readyBatch.count
        if waitingCount != waiting { waitingCount = waiting }
        if uploadingCount != inFlight.count { uploadingCount = inFlight.count }
        if failedCount != failedPaths.count { failedCount = failedPaths.count }
        if awaitingConfirmation != awaiting.count { awaitingConfirmation = awaiting.count }
        let deleting = deleteDue.count + deletesRunning.count
        if deletingCount != deleting { deletingCount = deleting }
        if awaitingDeleteConfirmation != heldDeletes.count {
            awaitingDeleteConfirmation = heldDeletes.count
        }
        if heldDeletesChanged {
            heldDeletesChanged = false
            let names = heldDeletes.sorted().map { ($0 as NSString).lastPathComponent }
            if awaitingDeleteNames != names { awaitingDeleteNames = names }
        }
    }
}

/// What "After upload" does to the original.
enum WatchFileActionError: Error, LocalizedError {
    /// "Uploaded" is a link (or a file), not a folder of its own.
    case uploadedFolderNotAFolder

    var errorDescription: String? {
        switch self {
        case .uploadedFolderNotAFolder:
            return String(localized: "\u{201C}Uploaded\u{201D} in this folder is a link or a file, not a folder, so nothing is moved into it.")
        }
    }
}

enum WatchFileActions {
    static let tagName = "Aktar"

    static func addTag(to url: URL) throws {
        let current = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        guard !current.contains(tagName) else { return }
        try (url as NSURL).setResourceValue(current + [tagName], forKey: .tagNamesKey)
    }

    /// A name for `name` in `folder` that isn't taken: "name (2).ext" and
    /// so on.
    static func freeName(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path), counter < 10_000 {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

/// What a hook receives after each upload, as JSON.
struct WatchHookPayload: Encodable, Sendable {
    struct Folder: Encodable, Sendable {
        let id: String
        let name: String
        let path: String
    }

    struct File: Encodable, Sendable {
        let path: String
        let name: String
        let size: Int64
    }

    struct Upload: Encodable, Sendable {
        let key: String
        let url: String
        let destinationID: String
        let reused: Bool
        /// The upload's short link; null (written out) when it has none.
        var shortUrl: String? = nil

        private enum CodingKeys: String, CodingKey { case key, url, destinationID, reused, shortUrl }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(url, forKey: .url)
            try c.encode(destinationID, forKey: .destinationID)
            try c.encode(reused, forKey: .reused)
            try c.encode(shortUrl, forKey: .shortUrl)
        }
    }

    struct Destination: Encodable, Sendable {
        let id: String
        let name: String
    }

    /// "upload.succeeded", or "upload.replaced" for a file replaced so its
    /// link stays (a destination's hooks).
    var event = "upload.succeeded"
    /// The watched folder the file came from; left out for a destination's
    /// hooks, which run for uploads made by hand.
    var folder: Folder?
    var destination: Destination?
    let file: File
    let upload: Upload

    init(event: String, destination: Destination, file: File, upload: Upload) {
        self.event = event
        self.destination = destination
        self.file = file
        self.upload = upload
    }

    init(upload: WatchedFileUpload) {
        folder = Folder(id: upload.folder.id.uuidString, name: upload.folder.name, path: upload.folder.path)
        file = File(path: upload.fileURL.path, name: upload.fileURL.lastPathComponent, size: upload.size)
        self.upload = Upload(
            key: upload.success.objectKey,
            url: upload.success.link,
            destinationID: upload.success.destinationID.uuidString,
            reused: upload.success.reused,
            shortUrl: upload.success.shortUrl
        )
    }

    /// For the hook's Test button.
    static func sample(folder: WatchedFolder) -> WatchHookPayload {
        let file = folder.url.appendingPathComponent("example.png")
        return WatchHookPayload(upload: WatchedFileUpload(
            folder: folder,
            relativePath: "example.png",
            fileURL: file,
            size: 12345,
            success: WatchUploadSuccess(
                objectKey: "example.png",
                publicURL: "https://example.com/example.png",
                link: "https://example.com/example.png",
                reused: false,
                byteSize: 12345,
                destinationID: folder.destinationID ?? UUID(),
                filename: "example.png",
                contentHash: nil
            )
        ))
    }

    func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
