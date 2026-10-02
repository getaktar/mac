import XCTest

final class WatchFileRulesTests: XCTestCase {
    private func facts(size: Int64 = 10, regular: Bool = true, symlink: Bool = false, hidden: Bool = false, cloudOnly: Bool = false, screenshot: Bool = false) -> FileFacts {
        FileFacts(
            isRegularFile: regular,
            isSymlink: symlink,
            isHidden: hidden,
            size: size,
            modified: Date(timeIntervalSince1970: 1_000),
            fileID: 1,
            isCloudOnly: cloudOnly,
            isScreenCapture: screenshot
        )
    }

    private func folder(_ configure: (inout WatchedFolder) -> Void = { _ in }) -> WatchedFolder {
        var folder = WatchedFolder(name: "Test", path: "/tmp/test")
        configure(&folder)
        return folder
    }

    private func rejection(_ path: String, _ facts: FileFacts? = nil, folder: WatchedFolder? = nil) -> FileRejection? {
        WatchFileRules.rejection(relativePath: path, facts: facts ?? self.facts(), folder: folder ?? self.folder())
    }

    func testBuiltInIgnoreList() {
        for name in ["movie.mp4.crdownload", "a.PART", "b.partial", "c.download", "x.tmp", "y.TEMP", "~$report.docx",
                     "~WRL0001.tmp", "~syncthing~file.txt", "desktop.ini", "THUMBS.DB", "notes.swp", "yarn.lock", "photo.icloud"] {
            XCTAssertEqual(rejection(name), .ignoredName, name)
        }
        XCTAssertNil(rejection("photo.png"))
        XCTAssertNil(rejection("partial-results.csv"))
    }

    func testHiddenAndDotFiles() {
        XCTAssertEqual(rejection(".DS_Store"), .hidden)
        XCTAssertEqual(rejection(".env"), .hidden)
        XCTAssertEqual(rejection(".syncthing.photo.png.tmp"), .hidden)
        XCTAssertEqual(rejection("photo.png", facts(hidden: true)), .hidden)
        XCTAssertEqual(rejection("a/.git/config", folder: folder { $0.subfolders = .keepStructure }), .hidden)
    }

    func testFileTypeAndSize() {
        XCTAssertEqual(rejection("link.png", facts(symlink: true)), .symlink)
        XCTAssertEqual(rejection("dir", facts(regular: false)), .notRegularFile)
        XCTAssertEqual(rejection("empty.txt", facts(size: 0)), .empty)
        let limited = folder {
            $0.filter.minBytes = 5
            $0.filter.maxBytes = 100
        }
        XCTAssertEqual(rejection("a.bin", facts(size: 4), folder: limited), .tooSmall)
        XCTAssertEqual(rejection("a.bin", facts(size: 101), folder: limited), .tooLarge)
        XCTAssertNil(rejection("a.bin", facts(size: 50), folder: limited))
    }

    func testSubfoldersAndUploadedFolder() {
        XCTAssertEqual(rejection("sub/photo.png"), .inSubfolder)
        let recursive = folder { $0.subfolders = .keepStructure }
        XCTAssertNil(rejection("sub/photo.png", folder: recursive))
        XCTAssertEqual(rejection("Uploaded/photo.png", folder: recursive), .inUploadedFolder)
        XCTAssertEqual(rejection("uploaded/photo.png", folder: recursive), .inUploadedFolder)
        XCTAssertEqual(rejection("Uploaded/photo.png"), .inUploadedFolder)
        XCTAssertNil(rejection("sub/Uploaded/photo.png", folder: recursive))
    }

    func testKinds() {
        let images = folder { $0.filter.kind = .images }
        XCTAssertNil(rejection("a.PNG", folder: images))
        XCTAssertNil(rejection("a.heic", folder: images))
        XCTAssertEqual(rejection("a.pdf", folder: images), .filteredOut)

        let videos = folder { $0.filter.kind = .videos }
        XCTAssertNil(rejection("clip.mov", folder: videos))
        XCTAssertEqual(rejection("a.png", folder: videos), .filteredOut)

        let screenshots = folder { $0.filter.kind = .screenshots }
        XCTAssertNil(rejection("Screenshot.png", facts(screenshot: true), folder: screenshots))
        XCTAssertEqual(rejection("photo.png", facts(screenshot: false), folder: screenshots), .filteredOut)
    }

    func testCustomIncludeAndExclude() {
        let custom = folder {
            $0.subfolders = .keepStructure
            $0.filter.kind = .custom
            $0.filter.include = ["*.png", "docs/*.pdf"]
            $0.filter.exclude = ["*-draft.*", "private/*"]
        }
        XCTAssertNil(rejection("A.PNG", folder: custom))
        XCTAssertNil(rejection("docs/spec.pdf", folder: custom))
        XCTAssertEqual(rejection("spec.pdf", folder: custom), .filteredOut)
        XCTAssertEqual(rejection("shot-draft.png", folder: custom), .filteredOut)
        XCTAssertEqual(rejection("private/a.png", folder: custom), .filteredOut)

        // Exclude applies to every kind.
        let all = folder { $0.filter.exclude = ["*.psd"] }
        XCTAssertEqual(rejection("art.PSD", folder: all), .filteredOut)
        XCTAssertNil(rejection("art.png", folder: all))
    }

    func testCloudOnly() {
        XCTAssertEqual(rejection("a.png", facts(cloudOnly: true)), .cloudOnly)
        XCTAssertNil(rejection("a.png", facts(cloudOnly: true), folder: folder { $0.includeCloudOnly = true }))
    }

    func testNameOnlyCheckWithoutFacts() {
        XCTAssertNil(WatchFileRules.rejection(relativePath: "a.png", facts: nil, folder: folder()))
        XCTAssertEqual(WatchFileRules.rejection(relativePath: "a.crdownload", facts: nil, folder: folder()), .ignoredName)
    }

    func testPatternsFromText() {
        XCTAssertEqual(WatchFileRules.patterns(from: " *.png, *.jpg\n docs/* ,"), ["*.png", "*.jpg", "docs/*"])
    }
}

final class WatchKeysTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    func testFolderAndSubpathTokens() {
        let key = ObjectKeyGenerator.generate(
            template: "{folder}/{subpath}/{filename}.{ext}",
            originalFilename: "shot.png",
            date: date,
            folder: "Screen/Shots",
            subpath: "2026/trip"
        )
        XCTAssertEqual(key, "Screen-Shots/2026/trip/shot.png")
    }

    func testEmptyTokensCollapse() {
        let key = ObjectKeyGenerator.generate(template: "{folder}/{subpath}/{filename}.{ext}", originalFilename: "a.txt", date: date)
        XCTAssertEqual(key, "a.txt")
        XCTAssertEqual(WatchKeys.collapsingEmptySegments("/a//b///c"), "a/b/c")
        XCTAssertEqual(WatchKeys.collapsingEmptySegments("a//b/"), "a/b/")
    }

    func testSubpath() {
        XCTAssertEqual(WatchKeys.subpath(relativePath: "a/b/c.png", mode: .keepStructure), "a/b")
        XCTAssertEqual(WatchKeys.subpath(relativePath: "c.png", mode: .keepStructure), "")
        XCTAssertEqual(WatchKeys.subpath(relativePath: "a/b/c.png", mode: .flatten), "")
        XCTAssertEqual(WatchKeys.subpath(relativePath: "a/b/c.png", mode: .ignore), "")
    }

    func testSubpathInsertedBeforeLastComponent() {
        XCTAssertEqual(WatchKeys.insertingSubpath("trip/day1", into: "2026/10/shot.png"), "2026/10/trip/day1/shot.png")
        XCTAssertEqual(WatchKeys.insertingSubpath("trip", into: "shot.png"), "trip/shot.png")
        XCTAssertEqual(WatchKeys.insertingSubpath("", into: "2026/shot.png"), "2026/shot.png")
    }

    func testOtherTokensUnchanged() {
        let key = ObjectKeyGenerator.generate(template: "{year}/{month}/{filename}.{ext}", originalFilename: "a.png", date: date)
        XCTAssertTrue(key.hasSuffix("/a.png"))
        XCTAssertEqual(key.split(separator: "/").count, 3)
    }
}

final class ForbiddenFoldersTests: XCTestCase {
    private let home = "/Users/me"
    private let appData = ["/Users/me/Library/Containers/com.getaktar.mac", "/Users/me/Library/Application Support/Aktar"]

    private func reason(_ path: String, existing: [(name: String, path: String)] = [], volumeRoot: Bool = false) -> ForbiddenFolderReason? {
        ForbiddenFolders.reason(for: path, home: home, appDataFolders: appData, existing: existing, isVolumeRoot: volumeRoot)
    }

    func testRootsAndHome() {
        XCTAssertEqual(reason("/"), .root)
        XCTAssertEqual(reason("/Volumes/Backup"), .root)
        XCTAssertEqual(reason("/Users/me/External", volumeRoot: true), .root)
        XCTAssertEqual(reason("/Users/me"), .home)
        XCTAssertEqual(reason("/Users/me/"), .home)
        XCTAssertNil(reason("/Volumes/Backup/Photos"))
        XCTAssertNil(reason("/Users/me/Desktop"))
    }

    func testSystemFolders() {
        for path in ["/System", "/Library", "/Library/Fonts", "/Applications", "/usr", "/usr/local/bin", "/private/var"] {
            XCTAssertEqual(reason(path), .system, path)
        }
        XCTAssertNil(reason("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Shots"))
    }

    func testAppData() {
        XCTAssertEqual(reason("/Users/me/Library/Containers/com.getaktar.mac/Data"), .appData)
        XCTAssertEqual(reason("/Users/me/Library"), .appData)
        XCTAssertEqual(reason("/Users/me/Library/Application Support/Aktar"), .appData)
    }

    func testOverlappingFolders() {
        let existing = [(name: "Shots", path: "/Users/me/Desktop/Shots")]
        XCTAssertEqual(reason("/Users/me/Desktop/Shots", existing: existing), .insideWatched("Shots"))
        XCTAssertEqual(reason("/Users/me/desktop/shots/2026", existing: existing), .insideWatched("Shots"))
        XCTAssertEqual(reason("/Users/me/Desktop", existing: existing), .containsWatched("Shots"))
        // A sibling whose name only starts the same way is fine.
        XCTAssertNil(reason("/Users/me/Desktop/Shots2", existing: existing))
    }
}

final class LedgerRulesTests: XCTestCase {
    private let folderID = UUID()
    private let modified = Date(timeIntervalSince1970: 2_000)

    private func entry(_ path: String = "a.png", state: LedgerEntry.State = .uploaded, size: Int64 = 10, mtime: Double = 2_000, fileID: UInt64? = 7, sha: String? = nil) -> LedgerEntry {
        LedgerEntry(folderID: folderID, relativePath: path, size: size, mtime: mtime, fileID: fileID, sha256: sha, state: state, objectKey: "key/\(path)")
    }

    private func decide(
        entry: LedgerEntry?,
        policy: ModifiedPolicy = .ignore,
        size: Int64 = 10,
        modified: Date? = nil,
        renames: [LedgerEntry] = [],
        exists: @escaping (String) -> Bool = { _ in false },
        sha: String? = nil
    ) -> LedgerDecision {
        LedgerRules.decide(
            size: size,
            modified: modified ?? self.modified,
            fileID: 7,
            entry: entry,
            modifiedPolicy: policy,
            renameCandidates: renames,
            pathExists: exists,
            sha256: sha
        )
    }

    func testNewFile() {
        XCTAssertEqual(decide(entry: nil), .upload)
    }

    func testHandledFilesAreSkipped() {
        XCTAssertEqual(decide(entry: entry()), .skip(refresh: false))
        XCTAssertEqual(decide(entry: entry(state: .skipped), size: 99), .skip(refresh: false))
        XCTAssertEqual(decide(entry: entry(state: .failed)), .failedEarlier)
    }

    func testUnfinishedUploadGoesAgain() {
        XCTAssertEqual(decide(entry: entry(state: .pending)), .upload)
    }

    func testRename() {
        let old = entry("old.png")
        XCTAssertEqual(decide(entry: nil, renames: [old]), .renamed(from: old))
        // The old path is still there: a copy, not a rename.
        XCTAssertEqual(decide(entry: nil, renames: [old], exists: { _ in true }), .upload)
        // Different size: another file that reused the inode.
        XCTAssertEqual(decide(entry: nil, size: 11, renames: [old]), .upload)
    }

    func testModifiedIgnored() {
        XCTAssertEqual(decide(entry: entry(), policy: .ignore, size: 20), .skip(refresh: false))
    }

    func testModifiedNeedsHashThenDecides() {
        let uploaded = entry(sha: "aaa")
        XCTAssertEqual(decide(entry: uploaded, policy: .uploadAgain, size: 20), .needsHash)
        XCTAssertEqual(decide(entry: uploaded, policy: .uploadAgain, size: 20, sha: "aaa"), .skip(refresh: true))
        XCTAssertEqual(decide(entry: uploaded, policy: .overwrite, size: 20, sha: "bbb"), .uploadChanged(replacing: uploaded))
        // Unchanged size and date: nothing to hash.
        XCTAssertEqual(decide(entry: uploaded, policy: .overwrite), .skip(refresh: false))
    }

    func testGoneRowAfterGracePeriodIsNew() {
        var gone = entry()
        gone.state = .gone
        gone.goneAt = modified.addingTimeInterval(-60)
        XCTAssertEqual(LedgerRules.decide(size: 10, modified: modified, fileID: 7, entry: gone, modifiedPolicy: .ignore,
                                          renameCandidates: [], pathExists: { _ in false }, now: modified, grace: 10), .upload)
    }

    func testGoneRowWithinGracePeriodIsTheSameFile() {
        var gone = entry()
        gone.state = .gone
        gone.goneAt = modified.addingTimeInterval(-2)
        gone.remoteDelete = .scheduled
        var restored = gone
        restored.state = .uploaded
        restored.goneAt = nil
        restored.remoteDelete = .none
        XCTAssertEqual(LedgerRules.decide(size: 10, modified: modified, fileID: 7, entry: gone, modifiedPolicy: .ignore,
                                          renameCandidates: [], pathExists: { _ in false }, now: modified, grace: 10), .reappeared(restored: restored))
    }

    func testRenameMatchesGoneRow() {
        var gone = entry("old.png")
        gone.state = .gone
        gone.goneAt = modified.addingTimeInterval(-3600)
        XCTAssertEqual(decide(entry: nil, renames: [gone]), .renamed(from: gone))
    }

    func testModifiedWithoutStoredHash() {
        let uploaded = entry(sha: nil)
        XCTAssertEqual(decide(entry: uploaded, policy: .uploadAgain, modified: modified.addingTimeInterval(5)), .uploadChanged(replacing: uploaded))
    }
}

final class StabilityTrackerTests: XCTestCase {
    private var timing: WatchTiming {
        var timing = WatchTiming()
        timing.stabilityInitial = 1
        timing.stabilityMax = 30
        timing.minimumAge = 2
        return timing
    }

    func testReadyAfterTwoEqualChecksOfAnOldFile() {
        var tracker = StabilityTracker(timing: timing)
        let modified = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(tracker.observe(.init(size: 5, modified: modified), now: now), .wait(1))
        XCTAssertEqual(tracker.observe(.init(size: 5, modified: modified), now: now.addingTimeInterval(1)), .ready)
    }

    func testGrowingFileBacksOff() {
        var tracker = StabilityTracker(timing: timing)
        var now = Date(timeIntervalSince1970: 1_000)
        var delays: [TimeInterval] = []
        for step in 0..<8 {
            let verdict = tracker.observe(.init(size: Int64(step * 100), modified: now), now: now)
            guard case .wait(let delay) = verdict else { return XCTFail("ready while growing") }
            delays.append(delay)
            now = now.addingTimeInterval(delay)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testFreshFileWaitsUntilOldEnough() {
        var tracker = StabilityTracker(timing: timing)
        let modified = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(tracker.observe(.init(size: 5, modified: modified), now: modified), .wait(1))
        // Same size and date, but written only 1 s ago.
        guard case .wait(let delay) = tracker.observe(.init(size: 5, modified: modified), now: modified.addingTimeInterval(1)) else {
            return XCTFail("ready too early")
        }
        XCTAssertEqual(delay, 1, accuracy: 0.001)
        XCTAssertEqual(tracker.observe(.init(size: 5, modified: modified), now: modified.addingTimeInterval(2)), .ready)
    }

    func testRetryDelays() {
        let timing = WatchTiming()
        XCTAssertEqual(timing.retryDelay(afterAttempts: 1), 60)
        XCTAssertEqual(timing.retryDelay(afterAttempts: 2), 300)
        XCTAssertEqual(timing.retryDelay(afterAttempts: 3), 900)
        XCTAssertEqual(timing.retryDelay(afterAttempts: 4), 3600)
        XCTAssertEqual(timing.retryDelay(afterAttempts: 9), 3600)
    }
}

final class WatchSettingsCodingTests: XCTestCase {
    func testJSONShape() throws {
        var settings = WatchSettings()
        var folder = WatchedFolder(name: "Shots", path: "/Users/me/Desktop", bookmark: Data([1, 2, 3]))
        folder.temporaryLink = .publicLink
        folder.hooks = [WatchHook(kind: .webhook, target: "https://example.com")]
        settings.folders = [folder, .screenshots(path: "/x", bookmark: nil)]
        settings.pausedUntil = .forever

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.encoded()) as? [String: Any])
        XCTAssertEqual(json["pausedUntil"] as? String, "forever")
        XCTAssertEqual(json["pauseOnBattery"] as? Bool, false)
        let folders = try XCTUnwrap(json["folders"] as? [[String: Any]])
        let first = folders[0]
        XCTAssertEqual(first["bookmark"] as? String, "AQID")
        XCTAssertEqual(first["temporaryLink"] as? String, "public")
        XCTAssertEqual(first["clipboard"] as? String, "none")
        XCTAssertEqual(first["subfolders"] as? String, "ignore")
        XCTAssertTrue(first["destinationID"] is NSNull)
        XCTAssertTrue(first["expiryDays"] is NSNull)
        let filter = try XCTUnwrap(first["filter"] as? [String: Any])
        XCTAssertTrue(filter["minBytes"] is NSNull)
        XCTAssertEqual(filter["kind"] as? String, "all")
        let screenshots = folders[1]
        XCTAssertEqual(screenshots["preset"] as? String, "screenshots")
        XCTAssertEqual(screenshots["clipboard"] as? String, "copyLink")
        XCTAssertEqual(screenshots["notifications"] as? String, "each")
        XCTAssertEqual(first["onDelete"] as? String, "keep")
        XCTAssertEqual(first["confirmDelete"] as? Bool, true)

        let decoded = try WatchSettings.decode(settings.encoded())
        XCTAssertEqual(decoded.folders.count, 2)
        XCTAssertEqual(decoded.folders[0].bookmark, Data([1, 2, 3]))
        XCTAssertEqual(decoded.pausedUntil, .forever)
    }

    func testDecodesWindowsStyleFile() throws {
        let json = """
        {"folders":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"C:\\\\Shots","temporaryLink":3600,
        "addedAt":"2026-10-01T10:00:00.123Z","modified":"overwrite","afterUpload":"something-new"},
        {"broken":true}],
        "pausedUntil":"2026-10-02T14:00:00Z","pauseOnMetered":true}
        """
        let settings = try WatchSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.folders.count, 1)
        let folder = settings.folders[0]
        XCTAssertEqual(folder.name, "C:\\Shots")
        XCTAssertEqual(folder.temporaryLink, .temporary(seconds: 3600))
        XCTAssertEqual(folder.modified, .overwrite)
        XCTAssertEqual(folder.afterUpload, .keep)
        XCTAssertTrue(folder.enabled)
        XCTAssertEqual(folder.onDelete, .keep)
        XCTAssertTrue(folder.confirmDelete)
        XCTAssertTrue(settings.pauseOnMetered)
        guard case .until = settings.pausedUntil else { return XCTFail("pausedUntil") }
    }
}

final class SQLiteLedgerTests: XCTestCase {
    func testRoundTripAndQueries() {
        let ledger = SQLiteLedger(path: nil)
        let folder = UUID()
        var entry = LedgerEntry(folderID: folder, relativePath: "a.png", size: 3, mtime: 12.5, fileID: UInt64.max, sha256: "abc", state: .failed)
        entry.attempts = 2
        entry.lastError = "offline"
        entry.retryable = true
        ledger.upsert(entry)
        ledger.upsert(LedgerEntry(folderID: folder, relativePath: "b.png", size: 1, mtime: 1, fileID: 2, state: .uploaded))
        ledger.upsert(LedgerEntry(folderID: UUID(), relativePath: "c.png", size: 1, mtime: 1, fileID: 2, state: .uploaded))

        let loaded = ledger.entry(folderID: folder, relativePath: "a.png")
        XCTAssertEqual(loaded?.fileID, UInt64.max)
        XCTAssertEqual(loaded?.attempts, 2)
        XCTAssertEqual(loaded?.retryable, true)
        XCTAssertEqual(loaded?.lastError, "offline")
        XCTAssertEqual(ledger.entries(folderID: folder).count, 2)
        XCTAssertEqual(ledger.count(folderID: folder, state: .failed), 1)
        XCTAssertEqual(ledger.entries(folderID: folder, fileID: 2).map(\.relativePath), ["b.png"])

        ledger.move(folderID: folder, from: "b.png", to: "d.png")
        XCTAssertNil(ledger.entry(folderID: folder, relativePath: "b.png"))
        XCTAssertNotNil(ledger.entry(folderID: folder, relativePath: "d.png"))

        let date = Date(timeIntervalSince1970: 1_000)
        ledger.setLastUploadAt(date, folderID: folder)
        XCTAssertEqual(ledger.lastUploadAt(folderID: folder), date)

        ledger.deleteAll(folderID: folder)
        XCTAssertTrue(ledger.entries(folderID: folder).isEmpty)
        XCTAssertNil(ledger.lastUploadAt(folderID: folder))
    }
}
