import AppKit
import UserNotifications
import Observation

/// What a watched folder is doing, as Settings, the panel and the local
/// API report it.
enum WatchFolderStatus: String, Sendable {
    case watching
    /// Watching as a whole is paused (by the user, battery or network).
    case paused
    /// This folder is turned off.
    case disabled
    /// The sandbox lost access (the bookmark no longer resolves).
    case accessNeeded
    case notFound
    case error
}

/// Runs Watched Folders: one `FolderWatchEngine` per folder, the pause
/// rules, access to the folders, and what happens around an upload that
/// the engine leaves to the app (the queue, clipboard, notifications and
/// Automation).
@MainActor
@Observable
final class WatchService {
    let store: WatchedFolderStore
    private(set) var engines: [UUID: FolderWatchEngine] = [:]
    /// Folders whose access couldn't be restored.
    private(set) var accessNeeded: Set<UUID> = []
    /// The last problem per folder (After upload, Automation), shown on its
    /// card until the next success.
    private(set) var lastErrors: [UUID: String] = [:]
    /// Set by "Watch Folder with Aktar" and aktar://watch; Settings picks it
    /// up and runs the add flow there.
    var pendingAddURL: URL?
    /// A folder whose form Settings should open (just added).
    var pendingEditID: UUID?

    @ObservationIgnored private let uploadManager: UploadManager
    @ObservationIgnored private let destinationStore: DestinationStore
    @ObservationIgnored let ledger: WatchLedgerStore
    @ObservationIgnored private let conditions = WatchConditions()
    @ObservationIgnored private var accessing: [UUID: URL] = [:]
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var confirmationNotified: Set<UUID> = []
    /// Answers Delete from Bucket / Keep Uploaded Files from a notification.
    @ObservationIgnored let notificationActions = WatchNotificationActions()
    @ObservationIgnored private var started = false
    /// Hooks run two at a time; the rest wait.
    @ObservationIgnored private let hookLimiter = AsyncLimiter(limit: 2)
    /// Folders whose new path is being looked at before watching starts.
    @ObservationIgnored private var preparing: Set<UUID> = []
    /// Folders to start with their existing files confirmed (Upload Them).
    @ObservationIgnored private var confirmedStarts: Set<UUID> = []
    /// Finished watched uploads, dropped from the queue together.
    @ObservationIgnored private var finishedJobs: [UploadJob] = []
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// Mirrors `WatchConditions` so views update.
    private var onBattery = false
    private var meteredNetwork = false

    init(uploadManager: UploadManager, destinationStore: DestinationStore) {
        self.uploadManager = uploadManager
        self.destinationStore = destinationStore
        store = WatchedFolderStore()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ledger = SQLiteLedger(path: dir.appendingPathComponent("watched-folders.sqlite").path)
        uploadManager.onWatchedUploadFinished = { [weak self] job, outcome in
            self?.uploadFinished(job, outcome: outcome)
        }
    }

    /// Starts watching, at launch.
    func start() {
        guard !started else { return }
        started = true
        notificationActions.service = self
        conditions.onChange = { [weak self] cameOnline in
            guard let self else { return }
            self.onBattery = self.conditions.onBattery
            self.meteredNetwork = self.conditions.meteredNetwork
            self.sync()
            if cameOnline {
                for engine in self.engines.values { engine.retryNetworkFailures() }
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumeMounted() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for engine in self.engines.values { engine.recheckHealth() }
            }
        }
        sync()
    }

    var folders: [WatchedFolder] { store.folders }

    // MARK: - Pausing

    /// The user's own pause, while it lasts.
    var manualPause: WatchSettings.Pause? {
        switch store.settings.pausedUntil {
        case .until(let date) where date > Date(): return .until(date)
        case .forever: return .forever
        default: return nil
        }
    }

    var pausedOnBattery: Bool { store.settings.pauseOnBattery && onBattery }
    var pausedOnMeteredNetwork: Bool { store.settings.pauseOnMetered && meteredNetwork }

    /// Nothing is uploaded from any folder.
    var isPaused: Bool { manualPause != nil || pausedOnBattery || pausedOnMeteredNetwork }

    /// `minutes` nil pauses until Resume; others are kept within a year
    /// (see `WatchPause`).
    func pause(minutes: Int?) {
        if let minutes {
            store.setPausedUntil(.until(WatchPause.end(minutes: minutes)))
        } else {
            store.setPausedUntil(.forever)
        }
        sync()
    }

    func pauseUntilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        store.setPausedUntil(.until(tomorrow))
        sync()
    }

    func resume() {
        store.setPausedUntil(nil)
        sync()
    }

    func setPauseOnBattery(_ on: Bool) {
        store.setPauseOnBattery(on)
        sync()
    }

    func setPauseOnMetered(_ on: Bool) {
        store.setPauseOnMetered(on)
        sync()
    }

    /// "Watching 2 folders", "Paused until 14:00" or "Paused".
    var statusLine: String {
        if let pause = manualPause {
            if case .until(let date) = pause {
                let time = Calendar.current.isDateInToday(date)
                    ? date.formatted(date: .omitted, time: .shortened)
                    : date.formatted(date: .abbreviated, time: .shortened)
                return String(localized: "Paused until \(time)")
            }
            return String(localized: "Paused")
        }
        if pausedOnBattery { return String(localized: "Paused on battery power") }
        if pausedOnMeteredNetwork { return String(localized: "Paused on a metered network") }
        let count = folders.filter(\.enabled).count
        return count == 1 ? String(localized: "Watching 1 folder") : String(localized: "Watching \(count) folders")
    }

    // MARK: - Engines

    /// Starts and stops engines to match the folders, their switches and
    /// the pause rules. Called after anything that could change that.
    /// Pausing keeps the engines watching (cheaply), so resuming doesn't
    /// start over; only a folder that's off or out of reach stops.
    func sync() {
        resumeTask?.cancel()
        resumeTask = nil
        conditions.setMonitoring(WatchMonitoring.needs(folderCount: folders.count, pauseOnBattery: store.settings.pauseOnBattery))
        onBattery = conditions.onBattery
        meteredNetwork = conditions.meteredNetwork
        let ids = Set(folders.map(\.id))
        for (id, engine) in engines where !ids.contains(id) {
            engine.stop()
            engines[id] = nil
            stopAccessing(id)
        }
        for folder in folders where !preparing.contains(folder.id) {
            let engine = engine(for: folder)
            guard folder.enabled, ensureAccess(folder) else {
                engine.stop()
                continue
            }
            if isPaused {
                engine.pause()
            } else {
                engine.start(confirmed: confirmedStarts.remove(folder.id) != nil)
            }
        }
        // A timed pause ends on its own.
        if case .until(let date) = manualPause {
            // Waited for a day at most at a time, so a far-off date (a
            // settings file edited by hand) can't overflow the timer.
            resumeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(WatchPause.wait(until: date)))
                guard !Task.isCancelled else { return }
                if date <= Date() { self?.store.setPausedUntil(nil) }
                self?.sync()
            }
        }
    }

    private func engine(for folder: WatchedFolder) -> FolderWatchEngine {
        if let engine = engines[folder.id] {
            if engine.folder.path == folder.path {
                if engine.folder != folder { engine.update(folder) }
                return engine
            }
            // Moved to another folder: a new engine for the new path.
            engine.stop()
            stopAccessing(folder.id)
        }
        let engine = FolderWatchEngine(folder: folder, ledger: ledger, uploader: self)
        engine.delegate = self
        engines[folder.id] = engine
        return engine
    }

    func engine(id: UUID) -> FolderWatchEngine? { engines[id] }

    /// After sleep, each folder is looked at once, a little later and all
    /// at the same moment rather than as soon as the Mac wakes.
    private func didWake() {
        guard !engines.isEmpty else { return }
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10), tolerance: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            for engine in self.engines.values where engine.isRunning { engine.reconcile() }
        }
    }

    private func volumeMounted() {
        // A folder on that disk may be back, and may need its access again.
        accessNeeded = []
        sync()
        for engine in engines.values { engine.recheckHealth() }
    }

    // MARK: - Access

    /// Restores the sandbox's access to the folder from its bookmark. The
    /// folder itself is still the saved path: a bookmark follows a folder
    /// into the Trash, and that's not where files should come from.
    private func ensureAccess(_ folder: WatchedFolder) -> Bool {
        if accessing[folder.id] != nil { return true }
        guard let bookmark = folder.bookmark else {
            // Without a bookmark only a folder the app can already read works.
            let readable = FileManager.default.isReadableFile(atPath: folder.path)
            setAccessNeeded(folder.id, !readable && FileManager.default.fileExists(atPath: folder.path))
            return readable || !FileManager.default.fileExists(atPath: folder.path)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            setAccessNeeded(folder.id, true)
            return false
        }
        accessing[folder.id] = url
        setAccessNeeded(folder.id, false)
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var updated = folder
            updated.bookmark = fresh
            store.update(updated)
        }
        return true
    }

    private func setAccessNeeded(_ id: UUID, _ needed: Bool) {
        if needed, !accessNeeded.contains(id) { accessNeeded.insert(id) }
        if !needed, accessNeeded.contains(id) { accessNeeded.remove(id) }
    }

    private func stopAccessing(_ id: UUID) {
        accessing[id]?.stopAccessingSecurityScopedResource()
        accessing[id] = nil
    }

    // MARK: - Status

    func status(for folder: WatchedFolder) -> WatchFolderStatus {
        if !folder.enabled { return .disabled }
        if accessNeeded.contains(folder.id) { return .accessNeeded }
        if let engine = engines[folder.id] {
            switch engine.health {
            case .notFound: return .notFound
            case .error: return .error
            case .ok: break
            }
        }
        return isPaused ? .paused : .watching
    }

    var totalWaiting: Int { engines.values.reduce(0) { $0 + $1.waitingCount } }
    var totalUploading: Int { engines.values.reduce(0) { $0 + $1.uploadingCount } }

    /// Folders holding a large batch for Upload or Skip.
    var confirmations: [(folder: WatchedFolder, count: Int)] {
        folders.compactMap { folder in
            guard let count = engines[folder.id]?.awaitingConfirmation, count > 0 else { return nil }
            return (folder, count)
        }
    }

    /// Folders holding deletions for Delete or Keep, with the files' names.
    var deleteConfirmations: [(folder: WatchedFolder, names: [String])] {
        folders.compactMap { folder in
            guard let names = engines[folder.id]?.awaitingDeleteNames, !names.isEmpty else { return nil }
            return (folder, names)
        }
    }

    // MARK: - Folders

    /// `existing` is what's in the folder already (see `existingFiles`):
    /// remembered as handled, unless `uploadExisting`.
    func add(_ folder: WatchedFolder, existing: [(path: String, facts: FileFacts)], uploadExisting: Bool) {
        store.add(folder)
        if uploadExisting {
            confirmedStarts.insert(folder.id)
        } else {
            writeBaseline(existing, for: folder)
        }
        sync()
    }

    func update(_ folder: WatchedFolder) {
        let previous = store.folder(id: folder.id)
        store.update(folder)
        lastErrors[folder.id] = nil
        // Another folder: what was handled in the old one means nothing
        // there, and what's already in the new one is left alone.
        if let previous, previous.path != folder.path {
            engines[folder.id]?.stop()
            engines[folder.id] = nil
            stopAccessing(folder.id)
            ledger.deleteAll(folderID: folder.id)
            accessNeeded.remove(folder.id)
            // Reading the new folder happens off the main actor; watching
            // starts once its files are remembered.
            preparing.insert(folder.id)
            Task { [weak self] in
                let files = await Task.detached(priority: .userInitiated) {
                    Self.existingFiles(in: folder, root: folder.url)
                }.value
                guard let self else { return }
                self.writeBaseline(files, for: folder)
                self.preparing.remove(folder.id)
                self.sync()
            }
        }
        sync()
    }

    func setEnabled(_ enabled: Bool, folderID: UUID) {
        guard var folder = store.folder(id: folderID) else { return }
        folder.enabled = enabled
        store.update(folder)
        sync()
    }

    func remove(_ folderID: UUID) {
        engines[folderID]?.stop()
        engines[folderID] = nil
        stopAccessing(folderID)
        store.remove(id: folderID)
        ledger.deleteAll(folderID: folderID)
        lastErrors[folderID] = nil
        accessNeeded.remove(folderID)
        sync()
    }

    /// Reset: everything in the folder counts as new again.
    func reset(_ folderID: UUID) {
        engines[folderID]?.reset()
    }

    func confirmPending(_ folderID: UUID) {
        confirmationNotified.remove(folderID)
        engines[folderID]?.confirmPending()
    }

    func skipPending(_ folderID: UUID) {
        confirmationNotified.remove(folderID)
        engines[folderID]?.skipPending()
    }

    /// Delete from Bucket on the large-deletion prompt.
    func confirmPendingDeletes(_ folderID: UUID) {
        engines[folderID]?.confirmPendingDeletes()
    }

    /// Keep Uploaded Files on the large-deletion prompt.
    func keepPendingDeletes(_ folderID: UUID) {
        engines[folderID]?.keepPendingDeletes()
    }

    /// Access again, after the folder was picked anew (Grant Access, Change).
    func replaceBookmark(_ folderID: UUID, url: URL) {
        guard var folder = store.folder(id: folderID) else { return }
        stopAccessing(folderID)
        folder.path = url.path
        folder.bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        accessNeeded.remove(folderID)
        store.update(folder)
        sync()
    }

    /// The files already in a folder that its rules would upload.
    nonisolated static func existingFiles(in folder: WatchedFolder, root: URL) -> [(path: String, facts: FileFacts)] {
        let options = InspectOptions(folder: folder, root: root)
        return (FileInspector.walk(root, recursive: folder.subfolders != .ignore, options: options) ?? []).filter {
            WatchFileRules.rejection(relativePath: $0.path, facts: $0.facts, folder: folder) == nil
        }
    }

    /// Skip Existing Files: what's there now is remembered as handled.
    private func writeBaseline(_ files: [(path: String, facts: FileFacts)], for folder: WatchedFolder) {
        let entries = files.map { file in
            LedgerEntry(
                folderID: folder.id,
                relativePath: file.path,
                size: file.facts.size,
                mtime: file.facts.modified.timeIntervalSince1970,
                fileID: file.facts.fileID,
                state: .skipped
            )
        }
        ledger.upsert(entries)
    }

    /// Why `url` can't be watched, if it can't.
    func forbiddenReason(for url: URL, excluding folderID: UUID? = nil) -> ForbiddenFolderReason? {
        let isVolumeRoot = (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        let existing = folders.filter { $0.id != folderID }.map { (name: $0.name, path: ForbiddenFolders.canonicalPath($0.path)) }
        return ForbiddenFolders.reason(
            for: ForbiddenFolders.canonicalPath(url.path),
            home: ForbiddenFolders.canonicalPath(UserPaths.home),
            appDataFolders: UserPaths.appDataFolders,
            existing: existing,
            isVolumeRoot: isVolumeRoot
        )
    }

    // MARK: - Destinations

    /// Where a folder's files go; nil when its destination was removed or
    /// there are none.
    func destination(for folder: WatchedFolder) -> DestinationConfig? {
        if let id = folder.destinationID {
            return destinationStore.destinations.first { $0.id == id }
        }
        return destinationStore.defaultDestination
    }

    // MARK: - Hooks

    private func runHooks(for upload: WatchedFileUpload) {
        let hooks = upload.folder.hooks.filter(\.enabled)
        guard !hooks.isEmpty else { return }
        let payload = WatchHookPayload(upload: upload)
        let limiter = hookLimiter
        for hook in hooks {
            Task { [weak self] in
                let failure: String? = await limiter.run {
                    do {
                        try await WatchHookRunner.run(hook, payload: payload)
                        return nil
                    } catch {
                        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                if let failure { self?.hookFailed(hook, folder: upload.folder, reason: failure) }
            }
        }
    }

    /// Test on a hook: the sample payload. Throws what went wrong.
    func testHook(_ hook: WatchHook, folder: WatchedFolder) async throws {
        try await WatchHookRunner.run(hook, payload: .sample(folder: folder))
    }

    private func hookFailed(_ hook: WatchHook, folder: WatchedFolder, reason: String) {
        lastErrors[folder.id] = "\(hook.target): \(reason)"
        NotificationService.notifyHookFailed(target: hook.target, reason: reason)
    }
}

// MARK: - The upload queue

extension WatchService: WatchUploading {
    /// One hand-over per folder: a drop of thousands of files is queued
    /// in one go.
    func enqueue(_ requests: [WatchUploadRequest]) {
        let byFolder = Dictionary(grouping: requests, by: \.folder.id)
        for (folderID, requests) in byFolder {
            guard let folder = requests.first?.folder else { continue }
            guard var destination = destination(for: folder) else {
                let message = folder.destinationID == nil
                    ? String(localized: "Add a destination in Aktar's Settings first.")
                    : String(localized: "This folder's destination was removed. Pick another one for it.")
                for request in requests {
                    engines[folderID]?.uploadFinished(requestID: request.id, outcome: .failed(message: message, retryable: false))
                }
                continue
            }
            switch folder.temporaryLink {
            case .publicLink: destination.temporaryLink = nil
            case .temporary(let seconds): destination.temporaryLink = TemporaryLinkDuration(rawValue: seconds) ?? destination.temporaryLink
            case nil: break
            }
            let inputs = requests.map { request in
                var input = UploadInput(fileURL: request.fileURL, originalFilename: request.fileURL.lastPathComponent, source: .watchedFolder(folder.id))
                input.objectKey = request.overwriteKey
                input.watch = WatchUploadContext(
                    requestID: request.id,
                    folderID: folder.id,
                    folderName: folder.name,
                    pathTemplate: folder.pathTemplate,
                    subpath: request.subpath,
                    keepStructure: folder.subfolders == .keepStructure,
                    sha256: request.sha256,
                    wantsContentHash: request.wantsContentHash
                )
                return input
            }
            uploadManager.upload(inputs, to: destination, expiryDays: folder.expiryDays)
        }
    }

    func verifyUploaded(key: String, destinationID: UUID, size: Int64) async -> Bool {
        await uploadManager.verifyUploaded(key: key, destinationID: destinationID, size: size)
    }

    func deleteUpload(key: String, destinationID: UUID, folderID: UUID) async -> WatchDeleteOutcome {
        do {
            try await uploadManager.deleteWatchedUpload(key: key, destinationID: destinationID, folderID: folderID)
            return .deleted
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(message: message, retryable: UploadManager.isTransient(error))
        }
    }

    func isReferencedInHistory(key: String, destinationID: UUID, folderID: UUID) -> Bool {
        uploadManager.isInHistory(key: key, destinationID: destinationID, excludingFolderID: folderID)
    }

    private func uploadFinished(_ job: UploadJob, outcome: WatchUploadOutcome) {
        guard let watch = job.input.watch else { return }
        engines[watch.folderID]?.uploadFinished(requestID: watch.requestID, outcome: outcome)
        // The ledger tracks every outcome (a failure is retried from there,
        // and shows on the folder), so the queue lets go of them, together
        // once per run loop turn.
        if case .cancelled = outcome { return }
        finishedJobs.append(job)
        guard finishedJobs.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.uploadManager.dismiss(self.finishedJobs)
                self.finishedJobs = []
            }
        }
    }
}

// MARK: - What happens after uploads

extension WatchService: WatchEngineDelegate {
    func engine(_ engine: FolderWatchEngine, didUpload upload: WatchedFileUpload) {
        lastErrors[upload.folder.id] = nil
        runHooks(for: upload)
        if upload.folder.notifications == .each {
            NotificationService.notifyWatchedUpload(filename: upload.success.filename, folderName: upload.folder.name, reused: upload.success.reused)
        }
    }

    func engine(_ engine: FolderWatchEngine, didSettle batch: WatchBatchSummary) {
        let folder = batch.folder
        if folder.clipboard == .copyLink, !batch.uploads.isEmpty {
            let links = batch.uploads.compactMap { upload -> String? in
                guard let url = URL(string: upload.success.link) else { return nil }
                return uploadManager.formatted(url, filename: upload.success.filename, destinationID: upload.success.destinationID)
            }
            ClipboardService.copy(links.joined(separator: "\n"))
        }
        if folder.notifications == .grouped {
            if batch.uploads.count == 1, let upload = batch.uploads.first {
                NotificationService.notifyWatchedUpload(filename: upload.success.filename, folderName: folder.name, reused: upload.success.reused)
            } else if batch.uploads.count > 1 {
                NotificationService.notifyWatchedBatch(count: batch.uploads.count, folderName: folder.name)
            }
        }
        // Failures say so whatever the folder's choice, one notification per
        // batch, and only the first time: automatic retries that fail again
        // during the same outage stay quiet.
        let failures = batch.failures.filter(\.isFirstFailure)
        if failures.count == 1, let failure = failures.first {
            NotificationService.notifyUploadFailed(filename: (failure.relativePath as NSString).lastPathComponent, reason: failure.message)
        } else if failures.count > 1 {
            NotificationService.notifyWatchedFailures(count: failures.count, folderName: folder.name)
        }
    }

    func engine(_ engine: FolderWatchEngine, needsConfirmation count: Int) {
        let folder = engine.folder
        // Withdrawn: the next large batch is announced again.
        guard count > 0 else { confirmationNotified.remove(folder.id); return }
        guard !confirmationNotified.contains(folder.id) else { return }
        confirmationNotified.insert(folder.id)
        NotificationService.notifyLargeBatch(count: count, folderName: folder.name)
    }

    func engine(_ engine: FolderWatchEngine, reportError message: String) {
        lastErrors[engine.folder.id] = message
        NotificationService.notifyWatchProblem(folderName: engine.folder.name, message: message)
    }

    func engine(_ engine: FolderWatchEngine, didDeleteRemote name: String) {
        if engine.folder.notifications == .each {
            NotificationService.notifyRemoteDeleted(filename: name)
        }
    }

    func engine(_ engine: FolderWatchEngine, didSettleDeletes summary: WatchDeleteSummary) {
        if summary.folder.notifications == .grouped, !summary.deleted.isEmpty {
            if summary.deleted.count == 1, let name = summary.deleted.first {
                NotificationService.notifyRemoteDeleted(filename: name)
            } else {
                NotificationService.notifyRemoteDeletedBatch(count: summary.deleted.count)
            }
        }
        // Failures always say so, once per batch and outage, like uploads.
        let failures = summary.failures.filter(\.isFirstFailure)
        if failures.count == 1, let failure = failures.first {
            NotificationService.notifyRemoteDeleteFailed(filename: (failure.relativePath as NSString).lastPathComponent, reason: failure.message)
        } else if failures.count > 1 {
            NotificationService.notifyRemoteDeletesFailed(count: failures.count)
        }
    }

    /// One notification per folder, whatever its notifications choice: it
    /// asks a question. It's replaced as files join and withdrawn once
    /// nothing is left to answer.
    func engine(_ engine: FolderWatchEngine, deleteAsksChanged names: [String], added: Bool) {
        let folder = engine.folder
        if names.isEmpty {
            NotificationService.withdrawDeleteAsk(folderID: folder.id)
        } else if added {
            NotificationService.askToDelete(names: names, folderID: folder.id, folderName: folder.name)
        }
    }
}

/// The actions on a delete ask, which answer it without opening Aktar, and
/// Retry on a failed short link. Also lets Aktar's notifications show while
/// one of its windows is in front.
final class WatchNotificationActions: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Set once at launch, before any notification can be answered.
    @MainActor weak var service: WatchService?
    /// Retry on a failed short link, with the upload's ID.
    @MainActor var retryShortLink: ((UUID) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        if action == NotificationService.retryShortLinkActionID {
            guard let raw = response.notification.request.content.userInfo[NotificationService.uploadIDKey] as? String,
                  let uploadID = UUID(uuidString: raw) else { return }
            await MainActor.run { retryShortLink?(uploadID) }
            return
        }
        guard let raw = response.notification.request.content.userInfo[NotificationService.folderIDKey] as? String,
              let folderID = UUID(uuidString: raw) else { return }
        await MainActor.run {
            switch action {
            case NotificationService.deleteActionID: service?.confirmPendingDeletes(folderID)
            case NotificationService.keepActionID: service?.keepPendingDeletes(folderID)
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
