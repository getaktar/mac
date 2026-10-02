import XCTest

/// Stands in for the upload queue: records what it's asked to upload and
/// answers like a successful upload a moment later (or as told).
@MainActor
private final class FakeUploader: WatchUploading {
    var requests: [WatchUploadRequest] = []
    var autoComplete = true
    var failNext: (message: String, retryable: Bool)?
    /// Uploads of these paths answer as reused duplicate links.
    var reusedPaths: Set<String> = []
    /// Keys history has from elsewhere.
    var historyKeys: Set<String> = []
    var deletedKeys: [String] = []
    /// Files the "upload" hashed, as the real pipeline does when asked.
    var hashedPaths: [String] = []
    weak var engine: FolderWatchEngine?

    var uploadedPaths: [String] { requests.map(\.relativePath) }

    /// Like the real queue, the file is read (and hashed, when asked) off
    /// the main actor.
    func enqueue(_ requests: [WatchUploadRequest]) {
        self.requests.append(contentsOf: requests)
        guard autoComplete else { return }
        for request in requests {
            if let failure = failNext {
                failNext = nil
                finish(request, .failed(message: failure.message, retryable: failure.retryable))
                continue
            }
            let hashes = request.sha256 == nil && request.wantsContentHash
            if hashes { hashedPaths.append(request.relativePath) }
            let reused = reusedPaths.contains(request.relativePath)
            Task { @MainActor in
                let (size, hash) = await Task.detached {
                    let size = FileInspector.facts(at: request.fileURL)?.size ?? 0
                    let hash = hashes ? try? ContentHasher.hashes(of: request.fileURL, md5: false, sha256: true).sha256 : request.sha256
                    return (size, hash)
                }.value
                self.finish(request, .succeeded(WatchUploadSuccess(
                    objectKey: request.overwriteKey ?? "uploads/\(request.relativePath)",
                    publicURL: "https://cdn.example.com/\(request.relativePath)",
                    link: "https://cdn.example.com/\(request.relativePath)",
                    reused: reused,
                    byteSize: size,
                    destinationID: UUID(),
                    filename: request.fileURL.lastPathComponent,
                    contentHash: hash
                )))
            }
        }
    }

    private func finish(_ request: WatchUploadRequest, _ outcome: WatchUploadOutcome) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            self.engine?.uploadFinished(requestID: request.id, outcome: outcome)
        }
    }

    func verifyUploaded(key: String, destinationID: UUID, size: Int64) async -> Bool { true }

    func deleteUpload(key: String, destinationID: UUID, folderID: UUID) async -> WatchDeleteOutcome {
        deletedKeys.append(key)
        return .deleted
    }

    func isReferencedInHistory(key: String, destinationID: UUID, folderID: UUID) -> Bool {
        historyKeys.contains(key)
    }
}

/// Counts the watcher's own hashing.
private final class HashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count
    }

    func hash(_ url: URL) -> String? {
        lock.lock()
        paths.append(url.lastPathComponent)
        lock.unlock()
        return try? ContentHasher.hashes(of: url, md5: false, sha256: true).sha256
    }
}

@MainActor
private final class Recorder: WatchEngineDelegate {
    var uploads: [WatchedFileUpload] = []
    var failures: [WatchedFileFailure] = []
    var batches: [WatchBatchSummary] = []
    var confirmations: [Int] = []
    var errors: [String] = []
    var remoteDeleted: [String] = []
    var deleteAsks: [(names: [String], added: Bool)] = []
    var deleteSummaries: [WatchDeleteSummary] = []

    func engine(_ engine: FolderWatchEngine, didUpload upload: WatchedFileUpload) { uploads.append(upload) }
    func engine(_ engine: FolderWatchEngine, didSettle batch: WatchBatchSummary) {
        batches.append(batch)
        failures += batch.failures
    }
    func engine(_ engine: FolderWatchEngine, needsConfirmation count: Int) { confirmations.append(count) }
    func engine(_ engine: FolderWatchEngine, reportError message: String) { errors.append(message) }
    func engine(_ engine: FolderWatchEngine, didDeleteRemote name: String) { remoteDeleted.append(name) }
    func engine(_ engine: FolderWatchEngine, didSettleDeletes summary: WatchDeleteSummary) { deleteSummaries.append(summary) }
    func engine(_ engine: FolderWatchEngine, deleteAsksChanged names: [String], added: Bool) { deleteAsks.append((names, added)) }
}

@MainActor
final class FolderWatchEngineTests: XCTestCase {
    private var root: URL!
    private var ledger: SQLiteLedger!
    private var uploader: FakeUploader!
    private var recorder: Recorder!
    private var engines: [FolderWatchEngine] = []

    /// Everything a hundred times faster than in the app.
    private var timing: WatchTiming {
        var timing = WatchTiming()
        timing.stabilityInitial = 0.05
        timing.stabilityMax = 0.2
        timing.minimumAge = 0.15
        timing.batchWindow = 0.2
        timing.safetyScan = 60
        timing.deleteGrace = 0.5
        return timing
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = SQLiteLedger(path: nil)
        uploader = FakeUploader()
        recorder = Recorder()
    }

    override func tearDown() async throws {
        for engine in engines { engine.stop() }
        engines = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEngine(timing custom: WatchTiming? = nil, hashes: HashCounter? = nil, _ configure: (inout WatchedFolder) -> Void = { _ in }) -> FolderWatchEngine {
        var folder = WatchedFolder(name: "Inbox", path: root.path)
        configure(&folder)
        let counter = hashes ?? HashCounter()
        let engine = FolderWatchEngine(
            folder: folder,
            ledger: ledger,
            uploader: uploader,
            timing: custom ?? timing,
            ignoreOwnEvents: false,
            hasher: { counter.hash($0) }
        )
        engine.delegate = recorder
        uploader.engine = engine
        engines.append(engine)
        return engine
    }

    private func write(_ name: String, _ text: String = "hello") throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Polls `condition` until it holds, failing after `timeout`.
    private func waitUntil(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Lets timers and events run for a while.
    private func settle(_ seconds: TimeInterval = 1) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testNewFileIsUploadedOnce() async throws {
        let engine = makeEngine()
        engine.start()
        try write("photo.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle()
        engine.reconcile()
        await settle()
        XCTAssertEqual(uploader.uploadedPaths, ["photo.png"])
        XCTAssertEqual(ledger.entry(folderID: engine.folder.id, relativePath: "photo.png")?.state, .uploaded)
        XCTAssertEqual(recorder.batches.count, 1)
    }

    func testSixtyFilesAtOnceNeedConfirmation() async throws {
        let engine = makeEngine()
        engine.start()
        for index in 0..<60 { try write("file-\(index).txt", "content \(index)") }
        await waitUntil { engine.awaitingConfirmation == 60 }
        XCTAssertEqual(recorder.confirmations.last, 60)
        XCTAssertTrue(uploader.requests.isEmpty)

        engine.confirmPending()
        await waitUntil { self.recorder.uploads.count == 60 }
        XCTAssertEqual(Set(uploader.uploadedPaths).count, 60)
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches.first?.uploads.count, 60)
    }

    func testSkippingALargeBatchRemembersTheFiles() async throws {
        let engine = makeEngine()
        engine.start()
        for index in 0..<55 { try write("file-\(index).txt") }
        await waitUntil { engine.awaitingConfirmation == 55 }
        engine.skipPending()
        XCTAssertEqual(ledger.count(folderID: engine.folder.id, state: .skipped), 55)
        engine.reconcile()
        await settle()
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(engine.awaitingConfirmation, 0)
    }

    func testDeletingAHeldBatchWithdrawsTheAsk() async throws {
        let engine = makeEngine()
        engine.start()
        for index in 0..<60 { try write("file-\(index).txt", "content \(index)") }
        await waitUntil { engine.awaitingConfirmation == 60 }
        for index in 0..<60 { try remove("file-\(index).txt") }
        await waitUntil { engine.awaitingConfirmation == 0 }
        XCTAssertEqual(recorder.confirmations.last, 0)
        // The folder isn't stuck behind the old ask: a new file goes up.
        try write("after.txt", "after")
        await waitUntil { self.uploader.uploadedPaths == ["after.txt"] }
    }

    func testUploadingAHeldBatchLeavesOutDeletedFiles() async throws {
        let engine = makeEngine()
        engine.start()
        for index in 0..<60 { try write("file-\(index).txt", "content \(index)") }
        await waitUntil { engine.awaitingConfirmation == 60 }
        // Deleted, maybe before the engine hears about it.
        for index in 0..<10 { try remove("file-\(index).txt") }
        engine.confirmPending()
        await waitUntil { self.uploader.uploadedPaths.count == 50 }
        await settle()
        XCTAssertEqual(uploader.uploadedPaths.count, 50)
        XCTAssertFalse(uploader.uploadedPaths.contains("file-0.txt"))
    }

    func testSkippingAHeldBatchLeavesOutDeletedFiles() async throws {
        let engine = makeEngine()
        engine.start()
        for index in 0..<55 { try write("file-\(index).txt") }
        await waitUntil { engine.awaitingConfirmation == 55 }
        for index in 0..<5 { try remove("file-\(index).txt") }
        engine.skipPending()
        XCTAssertEqual(ledger.count(folderID: engine.folder.id, state: .skipped), 50)
    }

    func testPartialDownloadRenamedToFinalName() async throws {
        let engine = makeEngine()
        engine.start()
        try write("movie.mp4.crdownload", "partial")
        await settle(0.6)
        XCTAssertTrue(uploader.requests.isEmpty)
        try FileManager.default.moveItem(at: root.appendingPathComponent("movie.mp4.crdownload"), to: root.appendingPathComponent("movie.mp4"))
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.5)
        XCTAssertEqual(uploader.uploadedPaths, ["movie.mp4"])
    }

    func testSlowlyGrowingFileWaitsUntilDone() async throws {
        let engine = makeEngine()
        engine.start()
        let url = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: Data("start".utf8))
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(100))
            try handle.seekToEnd()
            handle.write(Data(repeating: 1, count: 1024))
            XCTAssertTrue(uploader.requests.isEmpty, "uploaded while still growing")
        }
        try handle.close()
        await waitUntil { self.recorder.uploads.count == 1 }
        XCTAssertEqual(recorder.uploads.first?.size, Int64(5 + 8 * 1024))
        await settle(0.5)
        XCTAssertEqual(uploader.requests.count, 1)
    }

    func testFileAddedWhilePausedIsUploadedOnResume() async throws {
        let engine = makeEngine()
        engine.start()
        await settle(0.3)
        engine.stop()
        try write("while-paused.png")
        await settle(0.8)
        XCTAssertTrue(uploader.requests.isEmpty)
        engine.start()
        await waitUntil { self.recorder.uploads.count == 1 }
        XCTAssertEqual(uploader.uploadedPaths, ["while-paused.png"])
    }

    func testFolderDeletedAndRecreated() async throws {
        let engine = makeEngine()
        engine.start()
        try write("first.png")
        await waitUntil { self.recorder.uploads.count == 1 }

        try FileManager.default.removeItem(at: root)
        await waitUntil { engine.health == .notFound }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await waitUntil { engine.health == .ok }
        try write("second.png")
        await waitUntil { self.recorder.uploads.count == 2 }
        XCTAssertEqual(uploader.uploadedPaths, ["first.png", "second.png"])
    }

    func testMovedToUploadedIsNotUploadedAgain() async throws {
        let engine = makeEngine { $0.afterUpload = .moveToUploaded }
        engine.start()
        try write("report.pdf")
        await waitUntil { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("Uploaded/report.pdf").path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pdf").path))

        // A second file with the same name lands as "report (2).pdf".
        try write("report.pdf", "second version")
        await waitUntil { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("Uploaded/report (2).pdf").path) }
        engine.reconcile()
        await settle()
        XCTAssertEqual(uploader.uploadedPaths, ["report.pdf", "report.pdf"])
    }

    func testUploadedFolderIgnoredEvenWithSubfolders() async throws {
        let engine = makeEngine { $0.subfolders = .keepStructure }
        try write("Uploaded/old.png")
        try write("trip/day1/photo.png")
        engine.start()
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.5)
        XCTAssertEqual(uploader.uploadedPaths, ["trip/day1/photo.png"])
        XCTAssertEqual(uploader.requests.first?.subpath, "trip/day1")
    }

    func testRenameIsNotUploadedAgain() async throws {
        let engine = makeEngine()
        engine.start()
        try write("a.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.3)
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.png"), to: root.appendingPathComponent("b.png"))
        await settle()
        engine.reconcile()
        await settle()
        XCTAssertEqual(uploader.uploadedPaths, ["a.png"])
        XCTAssertNotNil(ledger.entry(folderID: engine.folder.id, relativePath: "b.png"))
    }

    func testOverwriteReusesTheKey() async throws {
        let engine = makeEngine { $0.modified = .overwrite }
        engine.start()
        try write("notes.txt", "one")
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.3)
        try write("notes.txt", "two, longer")
        await waitUntil { self.recorder.uploads.count == 2 }
        XCTAssertEqual(uploader.requests.last?.overwriteKey, "uploads/notes.txt")
    }

    func testChangesIgnoredByDefault() async throws {
        let engine = makeEngine()
        engine.start()
        try write("notes.txt", "one")
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.3)
        try write("notes.txt", "two, longer")
        await settle()
        XCTAssertEqual(uploader.requests.count, 1)
    }

    func testNetworkFailureIsRetried() async throws {
        let engine = makeEngine()
        uploader.failNext = ("offline", true)
        engine.start()
        try write("a.png")
        await waitUntil { self.recorder.failures.count == 1 }
        // Counts catch up once per run loop turn.
        await waitUntil { engine.failedCount == 1 }
        XCTAssertEqual(ledger.entry(folderID: engine.folder.id, relativePath: "a.png")?.retryable, true)
        engine.retryNetworkFailures()
        await waitUntil { self.recorder.uploads.count == 1 }
        await waitUntil { engine.failedCount == 0 }
        XCTAssertEqual(ledger.entry(folderID: engine.folder.id, relativePath: "a.png")?.state, .uploaded)
    }

    // MARK: - Deleted files

    private func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }

    private func state(_ engine: FolderWatchEngine, _ path: String) -> LedgerEntry.State? {
        ledger.entry(folderID: engine.folder.id, relativePath: path)?.state
    }

    func testDeletedThenNewFileWithSameNameIsUploaded() async throws {
        let engine = makeEngine()
        engine.start()
        try write("report.pdf", "first")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("report.pdf")
        await waitUntil { self.state(engine, "report.pdf") == .gone }
        await settle(0.7)
        try write("report.pdf", "a different, longer file")
        await waitUntil { self.recorder.uploads.count == 2 }
        XCTAssertEqual(uploader.uploadedPaths, ["report.pdf", "report.pdf"])
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
    }

    func testRenameAfterDeleteWindowIsNotUploadedAgain() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        let engine = makeEngine()
        engine.start()
        try write("a.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.png"), to: outside)
        await waitUntil { self.state(engine, "a.png") == .gone }
        await settle(0.8)
        try FileManager.default.moveItem(at: outside, to: root.appendingPathComponent("b.png"))
        await waitUntil { self.state(engine, "b.png") == .uploaded }
        await settle(0.5)
        XCTAssertEqual(uploader.uploadedPaths, ["a.png"])
    }

    func testAtomicSaveDoesNotDeleteRemotely() async throws {
        var slow = timing
        slow.deleteGrace = 2
        let engine = makeEngine(timing: slow) { $0.onDelete = .deleteRemote }
        engine.start()
        try write("notes.txt", "one")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("notes.txt")
        await waitUntil { self.state(engine, "notes.txt") == .gone }
        await waitUntil { engine.deletingCount == 1 }
        try write("notes.txt", "one, saved again")
        await waitUntil { self.state(engine, "notes.txt") == .uploaded }
        await settle(2.5)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(engine.deletingCount, 0)
        // Changes are ignored here, so the save isn't uploaded either.
        XCTAssertEqual(uploader.requests.count, 1)
    }

    func testDeletedFileIsDeletedRemotelyAfterGracePeriod() async throws {
        let engine = makeEngine {
            $0.onDelete = .deleteRemote
            $0.confirmDelete = false
        }
        engine.start()
        try write("old.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("old.png")
        await waitUntil { self.uploader.deletedKeys == ["uploads/old.png"] }
        XCTAssertEqual(recorder.remoteDeleted, ["old.png"])
        XCTAssertEqual(recorder.deleteSummaries.count, 1)
        XCTAssertNil(ledger.entry(folderID: engine.folder.id, relativePath: "old.png")?.objectKey)
    }

    func testMissingFolderNeverMarksFilesGone() async throws {
        let engine = makeEngine { $0.onDelete = .deleteRemote }
        engine.start()
        try write("keep.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        try FileManager.default.removeItem(at: root)
        await waitUntil { engine.health == .notFound }
        engine.reconcile()
        await settle(1)
        XCTAssertEqual(state(engine, "keep.png"), .uploaded)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(engine.deletingCount, 0)
    }

    func testLargeDeletionIsHeldForConfirmation() async throws {
        let engine = makeEngine {
            $0.onDelete = .deleteRemote
            $0.confirmDelete = false
        }
        engine.start()
        for index in 0..<12 { try write("file-\(index).txt", "content \(index)") }
        await waitUntil { self.recorder.uploads.count == 12 }
        for index in 0..<12 { try remove("file-\(index).txt") }
        await waitUntil { engine.awaitingDeleteConfirmation == 12 }
        await settle(1)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(recorder.deleteAsks.last?.names.count, 12)

        engine.confirmPendingDeletes()
        await waitUntil { self.uploader.deletedKeys.count == 12 }
        XCTAssertEqual(engine.awaitingDeleteConfirmation, 0)
    }

    func testKeepingALargeDeletionDeletesNothing() async throws {
        let engine = makeEngine {
            $0.onDelete = .deleteRemote
            $0.confirmDelete = false
        }
        engine.start()
        for index in 0..<10 { try write("file-\(index).txt", "content \(index)") }
        await waitUntil { self.recorder.uploads.count == 10 }
        for index in 0..<10 { try remove("file-\(index).txt") }
        await waitUntil { engine.awaitingDeleteConfirmation == 10 }
        engine.keepPendingDeletes()
        await settle(1)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(state(engine, "file-0.txt"), .gone)
    }

    func testReusedOrSharedUploadsAreNeverDeleted() async throws {
        uploader.reusedPaths = ["reused.png"]
        uploader.historyKeys = ["uploads/shared.png"]
        let engine = makeEngine { $0.onDelete = .deleteRemote }
        engine.start()
        try write("reused.png", "a")
        try write("shared.png", "bb")
        try write("twin.png", "ccc")
        await waitUntil { self.recorder.uploads.count == 3 }
        // Another folder's row points at twin.png's object too.
        if let twin = ledger.entry(folderID: engine.folder.id, relativePath: "twin.png") {
            var other = twin
            other.folderID = UUID()
            ledger.upsert(other)
        }
        try remove("reused.png")
        try remove("shared.png")
        try remove("twin.png")
        await waitUntil { self.state(engine, "twin.png") == .gone && self.state(engine, "shared.png") == .gone }
        await settle(1.2)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(engine.deletingCount, 0)
        // Not even asked about: they aren't the folder's to delete.
        XCTAssertEqual(engine.awaitingDeleteConfirmation, 0)
    }

    func testAskHoldsASingleDeletion() async throws {
        let engine = makeEngine { $0.onDelete = .deleteRemote }
        XCTAssertTrue(engine.folder.confirmDelete)
        engine.start()
        try write("one.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("one.png")
        await waitUntil { engine.awaitingDeleteNames == ["one.png"] }
        await settle(1)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(recorder.deleteAsks.last?.names, ["one.png"])
        XCTAssertEqual(recorder.deleteAsks.last?.added, true)

        engine.confirmPendingDeletes()
        await waitUntil { self.uploader.deletedKeys == ["uploads/one.png"] }
        XCTAssertEqual(engine.awaitingDeleteConfirmation, 0)
        XCTAssertEqual(recorder.deleteAsks.last?.names, [])
    }

    func testAskAnsweredWithKeep() async throws {
        let engine = makeEngine { $0.onDelete = .deleteRemote }
        engine.start()
        try write("a.png", "a")
        try write("b.png", "bb")
        await waitUntil { self.recorder.uploads.count == 2 }
        try remove("a.png")
        try remove("b.png")
        await waitUntil { engine.awaitingDeleteConfirmation == 2 }
        // Deletions close together are asked about together.
        XCTAssertEqual(recorder.deleteAsks.filter(\.added).count, 1)
        engine.keepPendingDeletes()
        await settle(1)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertEqual(ledger.entry(folderID: engine.folder.id, relativePath: "a.png")?.remoteDelete, LedgerEntry.RemoteDelete.none)
        XCTAssertEqual(state(engine, "a.png"), .gone)
    }

    func testReappearingFileWithdrawsTheAsk() async throws {
        let engine = makeEngine { $0.onDelete = .deleteRemote }
        engine.start()
        try write("back.png", "same")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("back.png")
        await waitUntil { engine.awaitingDeleteConfirmation == 1 }
        try write("back.png", "a new file at the same path")
        await waitUntil { engine.awaitingDeleteConfirmation == 0 }
        XCTAssertEqual(recorder.deleteAsks.last?.names, [])
        await waitUntil { self.recorder.uploads.count == 2 }
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
    }

    func testOwnMovesNeverDeleteRemotely() async throws {
        let engine = makeEngine {
            $0.onDelete = .deleteRemote
            $0.afterUpload = .moveToUploaded
        }
        XCTAssertFalse(engine.folder.deletesRemotely)
        var trashing = engine.folder
        trashing.afterUpload = .trash
        XCTAssertFalse(trashing.deletesRemotely)
        engine.start()
        try write("moved.png")
        await waitUntil { self.state(engine, "Uploaded/moved.png") == .uploaded }
        await settle(1)
        engine.reconcile()
        await settle(0.5)
        XCTAssertTrue(uploader.deletedKeys.isEmpty)
        XCTAssertNil(ledger.entry(folderID: engine.folder.id, relativePath: "moved.png"))
    }

    func testGoneRowsArePurged() async throws {
        var quick = timing
        quick.goneRetention = 0.3
        let engine = makeEngine(timing: quick)
        engine.start()
        try write("temp.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        try remove("temp.png")
        await waitUntil { self.state(engine, "temp.png") == .gone }
        await settle(0.5)
        engine.reconcile()
        await waitUntil { self.ledger.entry(folderID: engine.folder.id, relativePath: "temp.png") == nil }
    }

    // MARK: - Performance

    /// Idle, the only thing an engine waits for is the hourly safety scan.
    func testIdleEngineSchedulesOnlyTheSafetyScan() async throws {
        let engine = makeEngine()
        XCTAssertNil(engine.nextWakeup)
        engine.start()
        try write("a.png")
        await waitUntil { self.recorder.uploads.count == 1 }
        await settle(0.5)
        let wakeup = try XCTUnwrap(engine.nextWakeup)
        let scan = try XCTUnwrap(engine.safetyScanDue)
        XCTAssertEqual(wakeup.timeIntervalSince1970, scan.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(scan.timeIntervalSinceNow, timing.safetyScan - 2)

        engine.pause()
        await settle(0.1)
        XCTAssertNil(engine.nextWakeup)
        engine.stop()
        await settle(0.1)
        XCTAssertNil(engine.nextWakeup)
    }

    /// With no folders nothing is listened to at all.
    func testNoFoldersNeedNoMonitoring() {
        XCTAssertEqual(WatchMonitoring.needs(folderCount: 0, pauseOnBattery: true), WatchMonitoring.Needs())
        XCTAssertEqual(WatchMonitoring.needs(folderCount: 2, pauseOnBattery: false), WatchMonitoring.Needs(network: true, power: false))
        XCTAssertEqual(WatchMonitoring.needs(folderCount: 1, pauseOnBattery: true), WatchMonitoring.Needs(network: true, power: true))
    }

    func testFiveThousandFilesAreHandledQuicklyAndHashedOnce() async throws {
        for index in 0..<5000 { try write("file-\(index).txt", "content \(index)") }
        var bulk = timing
        bulk.largeBatch = 10_000
        let hashes = HashCounter()
        let engine = makeEngine(timing: bulk, hashes: hashes) { $0.modified = .uploadAgain }
        let started = Date()
        engine.start()
        await waitUntil(30) { self.recorder.uploads.count == 5000 }
        let elapsed = Date().timeIntervalSince(started)
        // About 1 s normally; quadratic work would take tens of seconds.
        XCTAssertLessThan(elapsed, 10, "5,000 files took \(elapsed) s")
        // The watcher hashed nothing new; the upload hashed each file once.
        XCTAssertEqual(hashes.count, 0)
        XCTAssertEqual(uploader.hashedPaths.count, 5000)
        XCTAssertEqual(Set(uploader.hashedPaths).count, 5000)
        XCTAssertEqual(uploader.requests.count, 5000)
    }

    func testEventsInIgnoredFoldersDontRescan() async throws {
        let engine = makeEngine {
            $0.subfolders = .keepStructure
            $0.filter.exclude = ["node_modules/*"]
        }
        engine.start()
        await waitUntil { engine.fullScanCount == 1 }
        await settle(0.5)
        try write(".git/objects/ab/cdef", "blob")
        try write("node_modules/left-pad/index.js", "module")
        try write("Uploaded/old.png", "old")
        await settle(1)
        XCTAssertEqual(engine.fullScanCount, 1)
        XCTAssertTrue(uploader.requests.isEmpty)

        // A folder moved in is scanned on its own, not the whole folder.
        let outside = root.deletingLastPathComponent().appendingPathComponent("trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: outside.appendingPathComponent("photo.png"))
        try FileManager.default.moveItem(at: outside, to: root.appendingPathComponent("trip"))
        await waitUntil { self.recorder.uploads.count == 1 }
        XCTAssertEqual(uploader.uploadedPaths, ["trip/photo.png"])
        XCTAssertEqual(engine.fullScanCount, 1)
    }

    func testSubfoldersIgnoredMeansNoScanForFolderEvents() async throws {
        let engine = makeEngine()
        engine.start()
        await waitUntil { engine.fullScanCount == 1 }
        await settle(0.5)
        try write("sub/deeper/file.png")
        await settle(1)
        XCTAssertEqual(engine.fullScanCount, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    func testOverlappingFoldersRefused() throws {
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let existing = [(name: "Inbox", path: ForbiddenFolders.canonicalPath(root.path))]
        XCTAssertEqual(
            ForbiddenFolders.reason(for: ForbiddenFolders.canonicalPath(inner.path), home: "/Users/nobody", appDataFolders: [], existing: existing),
            .insideWatched("Inbox")
        )
        let parent = ForbiddenFolders.canonicalPath(root.deletingLastPathComponent().path)
        XCTAssertEqual(
            ForbiddenFolders.reason(for: parent, home: "/Users/nobody", appDataFolders: [], existing: existing),
            .containsWatched("Inbox")
        )
        // "/var" and "/private/var" are the same folder.
        XCTAssertEqual(ForbiddenFolders.canonicalPath(root.path), ForbiddenFolders.canonicalPath(root.standardizedFileURL.path))
    }

    func testHookPayloadShape() throws {
        var folder = WatchedFolder(name: "Shots", path: "/Users/me/Shots")
        folder.destinationID = UUID()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: WatchHookPayload.sample(folder: folder).json()) as? [String: Any])
        XCTAssertEqual(json["event"] as? String, "upload.succeeded")
        let file = try XCTUnwrap(json["file"] as? [String: Any])
        XCTAssertEqual(file["name"] as? String, "example.png")
        let upload = try XCTUnwrap(json["upload"] as? [String: Any])
        XCTAssertEqual(upload["destinationID"] as? String, folder.destinationID?.uuidString)
        XCTAssertEqual(upload["reused"] as? Bool, false)
        XCTAssertEqual((json["folder"] as? [String: Any])?["name"] as? String, "Shots")
    }
}
