import Foundation

/// One upload the user started: a drop, a paste, a capture, a Finder
/// service call, the local API (not a watched folder's files). Undo takes
/// it back as a whole, and Upload and Paste pastes its link
/// (docs/capture-and-instant-links.md).
@MainActor
final class UploadAction {
    let id = UUID()
    let createdAt = Date.now
    /// Where to paste the link once it's copied.
    var paste: PasteRequest?
    var pasted = false
    /// The clipboard before the action first copied a link; nil when it
    /// couldn't be kept (too big, or marked private), so Undo empties it.
    var snapshot: ClipboardSnapshot?
    var tookSnapshot = false
    /// The clipboard's change count right after the action's last copy,
    /// and what that copy was: Undo only touches a clipboard nobody copied
    /// anything to since.
    var lastChangeCount: Int?
    var lastCopiedText: String?
    /// Undo is offered until then, and while a file of it still uploads.
    var undoDeadline = Date.distantPast
    var jobIDs: [UUID] = []
    /// The history entries it made (not a reused or replaced one).
    var recordIDs: [UUID] = []
    var notificationIDs: Set<String> = []
    var isUndoing = false
}

extension UploadManager {
    /// How long Undo is offered after a link is copied or an upload ends.
    static let undoWindow: TimeInterval = 10
    /// A quick upload only says "Uploaded"; one that takes longer than this
    /// says its link is copied and the file still uploading.
    static let uploadingNoticeDelay: TimeInterval = 2

    // MARK: - Actions

    func newAction(paste: PasteRequest?) -> UploadAction {
        let action = UploadAction()
        action.paste = paste
        actions[action.id] = action
        pruneActions()
        return action
    }

    /// Keeps the latest 100 actions that are over (a notification's Undo
    /// can still find them), and every one still going.
    private func pruneActions() {
        guard actions.count > 100 else { return }
        let pending = Set(jobs.filter(\.isPending).compactMap(\.actionID))
        let over = actions.values.filter { !pending.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        for action in over.prefix(actions.count - 100) { actions[action.id] = nil }
    }

    func notificationID(for job: UploadJob) -> String {
        "aktar.upload.\(job.id.uuidString)"
    }

    func noteNotification(for job: UploadJob) {
        guard let action = job.actionID.flatMap({ actions[$0] }) else { return }
        action.notificationIDs.insert(notificationID(for: job))
    }

    // MARK: - Copying

    /// Copies an upload's link. For an action, what was on the clipboard
    /// before is kept first (for Undo), and the link is pasted if asked to.
    func copyLink(_ text: String, for job: UploadJob) {
        guard let action = job.actionID.flatMap({ actions[$0] }) else {
            ClipboardService.copy(text)
            return
        }
        copy(text, in: action)
    }

    func copy(_ text: String, in action: UploadAction) {
        if !action.tookSnapshot {
            action.snapshot = ClipboardSnapshot.take()
            action.tookSnapshot = true
        }
        ClipboardService.copy(text)
        action.lastChangeCount = ClipboardService.changeCount
        action.lastCopiedText = text
        extendUndo(action)
        if let request = action.paste, !action.pasted {
            action.pasted = true
            if request.isStillValid {
                Task { await PasteService.paste() }
            }
        }
    }

    /// Whether the clipboard still holds `text` as the job copied it.
    func clipboardStillHolds(_ text: String, for job: UploadJob) -> Bool {
        if let action = job.actionID.flatMap({ actions[$0] }) {
            return action.lastChangeCount == ClipboardService.changeCount && action.lastCopiedText == text
        }
        return ClipboardService.string == text
    }

    /// Puts back what was on the clipboard before the action copied its
    /// link, if the clipboard still holds the action's last copy.
    func restoreClipboard(_ action: UploadAction) {
        guard let count = action.lastChangeCount, ClipboardService.changeCount == count else { return }
        if let snapshot = action.snapshot {
            snapshot.restore()
        } else {
            ClipboardService.clear()
        }
        action.lastChangeCount = nil
    }

    // MARK: - Instant link

    /// Whether a job copies its link before its bytes are sent: a file (or
    /// a folder as a ZIP) the user uploaded, to a key Aktar makes. Not a
    /// watched folder's file, a file of a folder or of a drop to several
    /// destinations (their links are copied together), a replace (its link
    /// doesn't change), an exact key, or an upload someone waits for.
    static func canCopyEarly(_ job: UploadJob) -> Bool {
        job.actionID != nil && job.input.watch == nil && job.input.group == nil && job.input.replacing == nil
            && job.input.objectKey == nil && job.input.folderKey == nil && !job.isWaitedFor
    }

    /// Copies the link to `objectKey` (shortened, as "Copy as" says) before
    /// the bytes go, and keeps the upload in the outbox until they're there.
    /// `withPage`: the link is to the file's share page, written once the
    /// file is up; until then it doesn't open, like the file's.
    func copyEarlyLink(_ job: UploadJob, objectKey: String, destination: DestinationConfig, provider: any StorageBackend, filename: String, withPage: Bool = false) async throws {
        let pageKey = withPage ? SharePages.pageKey(forFileKey: objectKey) : nil
        let linkKey = pageKey ?? objectKey
        guard let publicURL = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: linkKey),
              let fileURL = PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: objectKey) else {
            throw StorageError.invalidPublicBaseURL
        }
        // Signing happens on this Mac, so it works offline too.
        var link = publicURL
        var fileLink = fileURL
        var temporaryExpiresAt: Date?
        if let duration = destination.temporaryLink, let s3 = provider.s3(for: \.temporaryLinks),
           let signed = try? await s3.temporaryURL(for: linkKey, expiresIn: duration.rawValue) {
            link = signed
            temporaryExpiresAt = Date.now.addingTimeInterval(TimeInterval(duration.rawValue))
            if pageKey != nil, let signedFile = try? await s3.temporaryURL(for: objectKey, expiresIn: duration.rawValue) {
                fileLink = signedFile
            }
        }
        let shortening: ShortLinkService.Attempt = job.input.shortLink == false
            ? .skipped
            : await shortLinks.shorten(
                link,
                destination: destination,
                temporaryExpiresAt: temporaryExpiresAt,
                uploadExpiresAt: job.expiryDays.map { Date.now.addingTimeInterval(TimeInterval($0) * 86_400) },
                isFolderFile: false,
                explicit: job.input.shortLink == true
            )
        var early = EarlyLink(objectKey: objectKey, link: link, temporaryExpiresAt: temporaryExpiresAt, copiedText: "", pageKey: pageKey)
        var shortURL: URL?
        switch shortening {
        case .created(let pending):
            early.shortLink = EarlyShortLink(pending)
            shortURL = URL(string: pending.created.shortUrl)
        case .failed(let message):
            early.shortLinkError = message
        case .skipped:
            break
        }
        // Cancelled while the short link was being made.
        guard case .uploading = job.state else {
            deleteEarlyShortLink(early, destination: destination)
            throw CancellationError()
        }
        early.copiedText = format(link, shortURL: shortURL, filename: filename, for: destination, fileURL: pageKey != nil ? fileLink : nil)
        job.earlyLink = early
        copyLink(early.copiedText, for: job)
        keepInOutbox(job)
        scheduleUploadingNotice(for: job, filename: filename)
        closePanelIfWanted()
    }

    /// A job whose link was copied stops without finishing (Cancel, Undo):
    /// its short link is deleted, it leaves the outbox, and the clipboard
    /// gets back what was there before, if it still holds the link.
    func withdrawEarlyLink(of job: UploadJob) {
        if job.isInOutbox {
            outbox.remove(job.id)
            job.isInOutbox = false
        }
        guard let early = job.earlyLink else { return }
        job.earlyLink = nil
        deleteEarlyShortLink(early, destination: job.destination)
        NotificationService.remove(identifier: notificationID(for: job))
        if let action = job.actionID.flatMap({ actions[$0] }), clipboardStillHolds(early.copiedText, for: job) {
            restoreClipboard(action)
        }
    }

    /// Deletes the short link made for an early link that's no longer
    /// used. One that can't be deleted (the provider can't, or isn't the
    /// one set up any more) is left; it points at nothing.
    func deleteEarlyShortLink(_ early: EarlyLink, destination: DestinationConfig) {
        guard let short = early.shortLink else { return }
        deleteUnstoredShortLink(short, destination: destination)
    }

    /// Deletes a short link made at the provider that never made it into
    /// history.
    func deleteUnstoredShortLink(_ short: EarlyShortLink, destination: DestinationConfig) {
        guard let engine = shortLinks.operations(for: destination) else { return }
        let snapshot = ShortLinkSnapshot(
            id: UUID(), provider: short.provider, providerId: short.providerId, domain: short.domain,
            status: .active, createdAt: .now, expiresAt: short.expiresAt
        )
        Task { _ = try? await ShortLinkLifecycle.delete(snapshot, operations: engine) }
    }

    /// "Link copied, still uploading" for an upload that takes a while.
    private func scheduleUploadingNotice(for job: UploadJob, filename: String) {
        guard showsSuccessNotifications else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.uploadingNoticeDelay))
            guard let self, case .uploading = job.state, job.earlyLink != nil else { return }
            NotificationService.notifyLinkCopiedUploading(filename: filename, identifier: self.notificationID(for: job), actionID: job.actionID)
            self.noteNotification(for: job)
        }
    }

    // MARK: - Outbox

    /// Keeps the job's file and early link so the upload goes on after a
    /// restart. A job continued from the outbox reads its file from there.
    func keepInOutbox(_ job: UploadJob) {
        guard let entry = outboxEntry(for: job) else { return }
        if outbox.contains(job.id) {
            job.isInOutbox = outbox.update(entry)
            return
        }
        let file = job.downloaded?.fileURL ?? job.input.fileURL
        let outbox = outbox
        Task {
            let saved = await outbox.save(entry, file: file)
            // It may have finished (or stopped) while the copy was made.
            if job.isPending {
                job.isInOutbox = saved
            } else if saved {
                outbox.remove(job.id)
            }
        }
    }

    func outboxEntry(for job: UploadJob, failure: String? = nil) -> OutboxEntry? {
        guard let early = job.earlyLink else { return nil }
        let file = job.downloaded?.fileURL ?? job.input.fileURL
        return OutboxEntry(
            id: job.id,
            destinationID: job.destination.id,
            originalFilename: job.displayName,
            storedName: file.lastPathComponent,
            expiryDays: job.expiryDays,
            shortLinkOverride: job.input.shortLink,
            earlyLink: early,
            firstAttemptAt: job.firstAttemptAt ?? .now,
            failure: failure
        )
    }

    /// At launch: the uploads whose link was copied before Aktar quit go
    /// on, to the keys their links point at. One whose destination was
    /// removed has nowhere to go and is dropped; one that had failed waits
    /// for Retry or Cancel.
    func restoreOutbox() {
        let entries = outbox.load()
        guard !entries.isEmpty else { return }
        for (entry, fileURL) in entries {
            guard let destination = destinationStore.destinations.first(where: { $0.id == entry.destinationID }) else {
                outbox.remove(entry.id)
                continue
            }
            var input = UploadInput(fileURL: fileURL, originalFilename: entry.originalFilename, source: .outbox)
            input.shortLink = entry.shortLinkOverride
            let job = UploadJob(id: entry.id, input: input, destination: destination, expiryDays: entry.expiryDays)
            job.earlyLink = entry.earlyLink
            job.firstAttemptAt = entry.firstAttemptAt
            job.isInOutbox = true
            let action = newAction(paste: nil)
            action.jobIDs.append(job.id)
            job.actionID = action.id
            jobs.insert(job, at: 0)
            if let failure = entry.failure {
                job.state = .failed(failure)
            } else {
                enqueueForStart(job)
            }
        }
        drainQueue()
    }

    // MARK: - Offline queue

    /// Wakes up for the next upload waiting for the network whose wait is
    /// over.
    func scheduleOfflineRetry() {
        offlineTimer?.cancel()
        let due = jobs.compactMap { job -> Date? in
            guard case .offline = job.state else { return nil }
            return job.nextRetryAt ?? .now
        }.min()
        guard let due else { return }
        offlineTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.retryOffline(onlyDue: true)
        }
    }

    /// Starts the uploads waiting for the network: all of them when it just
    /// came back, otherwise those whose wait is over. While it's down they
    /// wait for it to come back.
    func retryOffline(onlyDue: Bool) {
        guard network.isOnline else {
            offlineTimer?.cancel()
            return
        }
        let now = Date.now
        for job in jobs {
            guard case .offline = job.state else { continue }
            if onlyDue, let next = job.nextRetryAt, next > now { continue }
            retry(job)
        }
        scheduleOfflineRetry()
    }

    // MARK: - Undo

    /// Offers Undo for `action` for `undoWindow` from now, and as long as
    /// one of its files still uploads.
    func extendUndo(_ action: UploadAction) {
        action.undoDeadline = Date.now.addingTimeInterval(Self.undoWindow)
        undoableActionID = action.id
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.undoableActionID == action.id else { return }
                let pending = self.jobs.contains { $0.actionID == action.id && $0.isPending }
                if !pending, Date.now >= action.undoDeadline {
                    self.undoableActionID = nil
                    return
                }
            }
        }
    }

    /// Whether Undo is offered for this history entry right now.
    func isUndoable(recordID: UUID) -> Bool {
        guard let id = undoableActionID else { return false }
        return jobs.contains { $0.actionID == id && $0.recordID == recordID }
    }

    /// The Undo shortcut: takes back the latest upload while Undo is
    /// offered for it. False when there's nothing to undo.
    @discardableResult
    func undoLatest() -> Bool {
        guard let id = undoableActionID else { return false }
        Task { await undo(actionID: id) }
        return true
    }

    /// Takes an upload back: files still going stop (and their short links
    /// are deleted), finished ones are deleted from the bucket with their
    /// short links and history entries, and the clipboard gets back what
    /// was on it before, if it still holds the link Aktar copied. A link
    /// reused from an earlier upload only leaves the clipboard; that file
    /// stays. `uploadID` is for a notification whose action is long gone:
    /// that upload alone is deleted.
    func undo(actionID: UUID, uploadID: UUID? = nil) async {
        guard let action = actions[actionID] else {
            guard let uploadID, let record = repository.record(id: uploadID) else { return }
            let name = record.localFilename
            do {
                try await deleteRemote(record)
                if showsSuccessNotifications { NotificationService.notifyUndone(names: [name]) }
            } catch {
                NotificationService.notifyRemoteDeleteFailed(filename: name, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            return
        }
        guard !action.isUndoing else { return }
        action.isUndoing = true
        if undoableActionID == actionID {
            undoableActionID = nil
            undoTimer?.cancel()
        }
        var names: [String] = []
        var failures: [(name: String, reason: String)] = []
        for job in jobs where job.actionID == actionID {
            switch job.state {
            case .waiting, .uploading, .offline, .failed:
                names.append(job.displayName)
                cancel(job)
            case .succeeded:
                guard !job.reused, let id = job.recordID, let record = repository.record(id: id) else {
                    names.append(job.displayName)
                    continue
                }
                let name = record.localFilename
                names.append(name)
                do {
                    try await deleteRemote(record)
                } catch {
                    failures.append((name, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
            case .cancelled:
                break
            }
        }
        restoreClipboard(action)
        NotificationService.remove(identifiers: Array(action.notificationIDs))
        for failure in failures {
            NotificationService.notifyRemoteDeleteFailed(filename: failure.name, reason: failure.reason)
        }
        if failures.isEmpty, showsSuccessNotifications, !names.isEmpty {
            NotificationService.notifyUndone(names: names)
        }
        actions[actionID] = nil
    }
}

extension EarlyShortLink {
    init(_ pending: ShortLinkService.Pending) {
        self.init(
            shortUrl: pending.created.shortUrl,
            providerId: pending.created.providerId,
            provider: pending.provider,
            providerName: pending.providerName,
            domain: pending.domain,
            targetUrl: pending.targetUrl,
            expiresAt: pending.expiresAt
        )
    }

    var pending: ShortLinkService.Pending {
        ShortLinkService.Pending(
            created: CreatedShortLink(shortUrl: shortUrl, providerId: providerId),
            provider: provider,
            providerName: providerName,
            domain: domain,
            targetUrl: targetUrl,
            expiresAt: expiresAt
        )
    }
}

extension EarlyLink {
    /// What became of the short link when the link was copied, for the
    /// upload's history entry.
    var attempt: ShortLinkService.Attempt {
        if let shortLink { return .created(shortLink.pending) }
        if let shortLinkError { return .failed(shortLinkError) }
        return .skipped
    }
}
