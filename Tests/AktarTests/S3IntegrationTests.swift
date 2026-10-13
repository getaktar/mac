import CryptoKit
import SotoS3
import XCTest

/// The S3 layer against a real S3-compatible server: uploads (single and
/// multipart, resumed), conditional writes, downloads, presigned links,
/// listing and moving, deleting in batches, lifecycle rules, thumbnails in
/// the bucket, and how failures are reported.
///
/// Runs only with AKTAR_TEST_S3_ENDPOINT, AKTAR_TEST_S3_ACCESS_KEY and
/// AKTAR_TEST_S3_SECRET_KEY set (TEST_RUNNER_ prefixed for xcodebuild).
/// Each run creates its own bucket and deletes it afterwards, so the keys
/// must be allowed to create buckets: `scripts/test-integration.sh` starts
/// a throwaway MinIO and sets everything up.
final class S3IntegrationTests: XCTestCase {
    private var endpoint = ""
    private var credentials = StorageCredentials(accessKeyId: "", secretAccessKey: "", sessionToken: nil)
    private var bucket = ""
    private var provider: S3Provider!
    private var directory: URL!
    /// Whether this test made the folder MultipartSessionStore writes to
    /// (the test runner isn't sandboxed, so it's the real Application
    /// Support), to take it away again.
    private var createdSessionFolder = false

    private static let sessionFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aktar", isDirectory: true)

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["AKTAR_TEST_S3_ENDPOINT"],
              let accessKey = environment["AKTAR_TEST_S3_ACCESS_KEY"],
              let secretKey = environment["AKTAR_TEST_S3_SECRET_KEY"] else {
            throw XCTSkip("AKTAR_TEST_S3_ENDPOINT, AKTAR_TEST_S3_ACCESS_KEY and AKTAR_TEST_S3_SECRET_KEY aren't set")
        }
        self.endpoint = endpoint
        credentials = StorageCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: nil)
        bucket = "aktar-it-\(UUID().uuidString.prefix(8).lowercased())"
        provider = S3Provider(config: destination(), credentials: credentials)
        _ = try await provider.s3.createBucket(.init(bucket: bucket))

        directory = FileManager.default.temporaryDirectory.appendingPathComponent("S3IntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdSessionFolder = !FileManager.default.fileExists(atPath: Self.sessionFolder.path)
    }

    override func tearDown() async throws {
        if let provider {
            await Self.empty(bucket, provider: provider)
            _ = try? await provider.s3.deleteBucket(.init(bucket: bucket))
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if createdSessionFolder { try? FileManager.default.removeItem(at: Self.sessionFolder) }
        provider = nil
    }

    // MARK: - Connection

    func testConnectionAndPublicLink() async throws {
        // Uploads work, but the bucket doesn't allow public reads yet.
        var publicConfig = destination()
        publicConfig.publicBaseURL = "\(endpoint)/\(bucket)"
        let result = try await S3Provider(config: publicConfig, credentials: credentials).testConnection()
        XCTAssertTrue(result.bucketReachable)
        XCTAssertTrue(result.writable)
        XCTAssertEqual(result.publicLink, .status(403))

        try await allowPublicReads()
        let open = try await S3Provider(config: publicConfig, credentials: credentials).testConnection()
        XCTAssertEqual(open.publicLink, .reachable)

        // The test file is cleaned up.
        let listing = try await provider.listRecursively(prefix: "", continuationToken: nil)
        XCTAssertEqual(listing.objects, [])

        // Without a public base URL there's nothing to open.
        var noPublicURL = destination()
        noPublicURL.publicBaseURL = ""
        let publicLink = try await S3Provider(config: noPublicURL, credentials: credentials).testConnection().publicLink
        XCTAssertNil(publicLink)
    }

    func testWrongKeysAndMissingBuckets() async throws {
        let wrongSecret = S3Provider(config: destination(), credentials: StorageCredentials(accessKeyId: credentials.accessKeyId, secretAccessKey: "wrong-secret", sessionToken: nil))
        await assertThrows(StorageError.invalidCredentials) { _ = try await wrongSecret.list(prefix: "", continuationToken: nil) }

        let unknownKey = S3Provider(config: destination(), credentials: StorageCredentials(accessKeyId: "nobody", secretAccessKey: "nothing", sessionToken: nil))
        await assertThrows(StorageError.invalidCredentials) { _ = try await unknownKey.list(prefix: "", continuationToken: nil) }

        var missing = destination()
        missing.bucket = "aktar-it-missing-\(UUID().uuidString.prefix(6).lowercased())"
        let noBucket = S3Provider(config: missing, credentials: credentials)
        await assertThrows(StorageError.bucketNotFound(missing.bucket)) { _ = try await noBucket.list(prefix: "", continuationToken: nil) }
        do {
            _ = try await noBucket.testConnection()
            XCTFail("a missing bucket must fail the connection test")
        } catch {}
    }

    // MARK: - Uploading

    func testSingleUploadRoundTrip() async throws {
        let file = try makeFile("photo one.png", bytes: 300_000)
        let fractions = Fractions()
        let result = try await provider.upload(fileURL: file, objectKey: "2026/10/photo one.png", contentType: "image/png") { fractions.add($0) }

        XCTAssertEqual(result.objectKey, "2026/10/photo one.png")
        XCTAssertEqual(result.byteSize, 300_000)
        XCTAssertEqual(result.publicURL.absoluteString, "https://files.example.com/2026/10/photo%20one.png")
        XCTAssertEqual(fractions.values.first, 0)
        XCTAssertEqual(fractions.values.last, 1)

        let objectExists = try await provider.objectExists(key: "2026/10/photo one.png")
        XCTAssertTrue(objectExists)
        let prefixExists = try await provider.objectExists(key: "2026/10/photo")
        XCTAssertFalse(prefixExists)
        let objectSize = try await provider.objectSize(key: "2026/10/photo one.png")
        XCTAssertEqual(objectSize, 300_000)
        let missingSize = try await provider.objectSize(key: "2026/10/nothing.png")
        XCTAssertNil(missingSize)
        let lastModified = try await provider.lastModified(key: "2026/10/photo one.png")
        XCTAssertLessThan(abs(try XCTUnwrap(lastModified).timeIntervalSinceNow), 300)

        let head = try await provider.s3.headObject(.init(bucket: bucket, key: "2026/10/photo one.png"))
        XCTAssertEqual(head.contentType, "image/png")
        XCTAssertNil(head.contentDisposition)
        XCTAssertNil(head.cacheControl)

        let downloaded = directory.appendingPathComponent("downloaded")
        let found = try await provider.download(key: "2026/10/photo one.png", to: downloaded, maxBytes: 1_000_000)
        XCTAssertTrue(found)
        XCTAssertEqual(try Data(contentsOf: downloaded), try Data(contentsOf: file))
        let foundMissing = try await provider.download(key: "nothing.png", to: downloaded, maxBytes: 1_000_000)
        XCTAssertFalse(foundMissing)
        await assertThrows(StorageError.unknown("The object is too large.")) {
            _ = try await self.provider.download(key: "2026/10/photo one.png", to: downloaded, maxBytes: 1000)
        }
    }

    func testUnicodeAndReservedCharactersInKeys() async throws {
        let file = try makeFile("a.txt", bytes: 10)
        let keys = ["çay/ğüşöı.txt", "a+b=c&d/e;f@g.txt", "spaces  and %25/x.txt", "emoji 👩‍💻/note.txt", "q?x#y.txt"]
        for key in keys {
            _ = try await provider.upload(fileURL: file, objectKey: key, contentType: "text/plain", progress: nil)
            let objectExists = try await provider.objectExists(key: key)
            XCTAssertTrue(objectExists, key)
            let data = try await provider.getObject(key: key, maxBytes: 100)?.data
            XCTAssertEqual(data, try Data(contentsOf: file), key)
        }
        let listed = try await provider.listRecursively(prefix: "", continuationToken: nil).objects.map(\.key)
        XCTAssertEqual(Set(listed), Set(keys))
    }

    func testActiveContentIsSentAsAnAttachment() async throws {
        let page = try makeFile("page.html", bytes: 100)
        _ = try await provider.upload(fileURL: page, objectKey: "page.html", contentType: "text/html", progress: nil)
        let head = try await provider.s3.headObject(.init(bucket: bucket, key: "page.html"))
        XCTAssertEqual(head.contentDisposition, "attachment")

        // The key's extension counts too, whatever the content type says.
        let renamed = try makeFile("notes.txt", bytes: 100)
        _ = try await provider.upload(fileURL: renamed, objectKey: "x.svg", contentType: "text/plain", progress: nil)
        let contentDisposition = try await provider.s3.headObject(.init(bucket: bucket, key: "x.svg")).contentDisposition
        XCTAssertEqual(contentDisposition, "attachment")
    }

    func testShortCacheIsSent() async throws {
        var config = destination()
        config.shortCache = true
        let shortCache = S3Provider(config: config, credentials: credentials)
        _ = try await shortCache.upload(fileURL: try makeFile("a.png", bytes: 10), objectKey: "a.png", contentType: "image/png", progress: nil)
        let cacheControl = try await provider.s3.headObject(.init(bucket: bucket, key: "a.png")).cacheControl
        XCTAssertEqual(cacheControl, "public, max-age=60")
    }

    func testConditionalWritesDontReplace() async throws {
        let first = try makeFile("first.txt", contents: "first")
        let second = try makeFile("second.txt", contents: "second")
        try await provider.putObject(fileURL: first, objectKey: "Ab3dE7x.txt", contentType: "text/plain", ifNoneMatch: true) { _ in }
        await assertThrows(StorageError.alreadyExists) {
            try await self.provider.putObject(fileURL: second, objectKey: "Ab3dE7x.txt", contentType: "text/plain", ifNoneMatch: true) { _ in }
        }
        let data = try await provider.getObject(key: "Ab3dE7x.txt", maxBytes: 100)?.data
        XCTAssertEqual(data, Data("first".utf8))
    }

    func testShortKeysFindAFreeKey() async throws {
        let file = try makeFile("a.txt", contents: "new")
        for taken in ["taken1.txt", "taken2.txt"] {
            try await provider.putObject(data: Data("old".utf8), objectKey: taken, contentType: "text/plain")
        }
        let provider = provider!
        for conditional in [true, false] {
            var codes = ["taken2.txt", "free-\(conditional).txt"].makeIterator()
            let key = try await ShortKeys.write(
                firstKey: "taken1.txt",
                conditional: conditional,
                newKey: { codes.next()! },
                exists: { try await provider.objectExists(key: $0) },
                write: { key, ifNoneMatch in
                    try await provider.putObject(fileURL: file, objectKey: key, contentType: "text/plain", ifNoneMatch: ifNoneMatch) { _ in }
                }
            )
            XCTAssertEqual(key, "free-\(conditional).txt")
        }
        // Nothing was replaced.
        let data = try await provider.getObject(key: "taken1.txt", maxBytes: 100)?.data
        XCTAssertEqual(data, Data("old".utf8))
        let data2 = try await provider.getObject(key: "taken2.txt", maxBytes: 100)?.data
        XCTAssertEqual(data2, Data("old".utf8))
    }

    // MARK: - Multipart

    func testLargeFilesGoUpInParts() async throws {
        let size = S3Provider.multipartThreshold + 5 * 1024 * 1024
        let file = try makeFile("big.bin", bytes: Int(size))
        let fractions = Fractions()
        let result = try await provider.upload(fileURL: file, objectKey: "big/big.bin", contentType: "application/octet-stream") { fractions.add($0) }
        XCTAssertEqual(Int64(result.byteSize), size)
        XCTAssertEqual(fractions.values.last, 1)
        XCTAssertEqual(fractions.values, fractions.values.sorted(), "progress only goes forward")

        let head = try await provider.s3.headObject(.init(bucket: bucket, key: "big/big.bin"))
        XCTAssertEqual(head.contentLength, size)
        XCTAssertTrue(head.eTag?.contains("-") == true, "a multipart ETag ends in -<parts>")
        try await assertSameContents(file, key: "big/big.bin", size: size)
        let uploads = try await provider.s3.listMultipartUploads(.init(bucket: bucket)).uploads ?? []
        XCTAssertTrue(uploads.isEmpty)
    }

    func testAnInterruptedUploadResumes() async throws {
        let partSize = S3Provider.partSize(forFileSize: 40 * 1024 * 1024)
        let size = 2 * partSize + 1234
        let file = try makeFile("resume.bin", bytes: Int(size))

        // An earlier try got the first part across.
        let uploadId = try await provider.createMultipartUpload(objectKey: "resume.bin", contentType: "application/octet-stream", fileName: "resume.bin")
        let eTag = try await provider.uploadPart(fileURL: file, partNumber: 1, offset: 0, length: partSize, objectKey: "resume.bin", uploadId: uploadId) { _ in }
        let session = multipartSession(objectKey: "resume.bin", uploadId: uploadId, partSize: partSize, fileSize: size, file: file, parts: [.init(number: 1, eTag: eTag)])
        await MultipartSessionStore.shared.save(session)

        let partsThere = try await provider.uploadedParts(objectKey: "resume.bin", uploadId: uploadId).keys.sorted()
        XCTAssertEqual(partsThere, [1])

        let fractions = Fractions()
        let reporter = ProgressReporter(total: size) { fractions.add($0) }
        try await MultipartUploader.upload(
            provider: provider, fileURL: file, fileSize: size, objectKey: "resume.bin", contentType: "application/octet-stream",
            session: session, identity: nil, reporter: reporter
        )
        try await assertSameContents(file, key: "resume.bin", size: size)
        let forgotten = await MultipartSessionStore.shared.all.allSatisfy { $0.id != session.id }
        XCTAssertTrue(forgotten, "a finished session is forgotten")
        // The first part counted as done before anything was sent.
        await Task.yield()
        XCTAssertGreaterThanOrEqual(fractions.values.first ?? 0, Double(partSize) / Double(size) - 0.001)

        // Once completed, the provider no longer knows the upload.
        await assertThrows(MultipartUploadError.noSuchUpload) {
            _ = try await self.provider.uploadedParts(objectKey: "resume.bin", uploadId: uploadId)
        }
    }

    func testADiscardedUploadStartsOver() async throws {
        let partSize = S3Provider.partSize(forFileSize: 20 * 1024 * 1024)
        let size = partSize + 10
        let file = try makeFile("gone.bin", bytes: Int(size))
        let uploadId = try await provider.createMultipartUpload(objectKey: "gone.bin", contentType: "application/octet-stream", fileName: "gone.bin")
        await provider.abortMultipartUpload(objectKey: "gone.bin", uploadId: uploadId)

        let session = multipartSession(objectKey: "gone.bin", uploadId: uploadId, partSize: partSize, fileSize: size, file: file, parts: [])
        await MultipartSessionStore.shared.save(session)
        try await MultipartUploader.upload(
            provider: provider, fileURL: file, fileSize: size, objectKey: "gone.bin", contentType: "application/octet-stream",
            session: session, identity: nil, reporter: ProgressReporter(total: size, report: nil)
        )
        try await assertSameContents(file, key: "gone.bin", size: size)
        let forgotten = await MultipartSessionStore.shared.all.allSatisfy { $0.objectKey != "gone.bin" }
        XCTAssertTrue(forgotten)
    }

    func testAConditionalMultipartUploadDoesntReplace() async throws {
        try await provider.putObject(data: Data("old".utf8), objectKey: "Ab3dE7x.bin", contentType: "application/octet-stream")
        let size = S3Provider.partSize(forFileSize: 1) + 1
        let file = try makeFile("cond.bin", bytes: Int(size))
        await assertThrows(StorageError.alreadyExists) {
            try await MultipartUploader.upload(
                provider: self.provider, fileURL: file, fileSize: size, objectKey: "Ab3dE7x.bin", contentType: "application/octet-stream",
                session: nil, identity: nil, reporter: ProgressReporter(total: size, report: nil), ifNoneMatch: true
            )
        }
        let data = try await provider.getObject(key: "Ab3dE7x.bin", maxBytes: 100)?.data
        XCTAssertEqual(data, Data("old".utf8))
        // The parts were freed.
        let uploads = try await provider.s3.listMultipartUploads(.init(bucket: bucket)).uploads ?? []
        XCTAssertTrue(uploads.isEmpty)
    }

    // MARK: - Links

    func testTemporaryLinksOpenAndExpire() async throws {
        try await provider.putObject(data: Data("secret".utf8), objectKey: "private/a b.txt", contentType: "text/plain")
        let link = try await provider.temporaryURL(for: "private/a b.txt", expiresIn: 2)
        let (data, response) = try await URLSession.shared.data(from: link)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("secret".utf8))

        // Tampering with the link breaks the signature.
        let tampered = URL(string: link.absoluteString.replacingOccurrences(of: "X-Amz-Expires=2", with: "X-Amz-Expires=600"))!
        let tamperedStatus = try await Self.status(of: tampered)
        XCTAssertEqual(tamperedStatus, 403)

        try await Task.sleep(for: .seconds(3))
        let expiredStatus = try await Self.status(of: link)
        XCTAssertEqual(expiredStatus, 403)

        // Not public without a policy.
        let plain = URL(string: "\(endpoint)/\(bucket)/private/a%20b.txt")!
        let plainStatus = try await Self.status(of: plain)
        XCTAssertEqual(plainStatus, 403)
    }

    // MARK: - Browsing

    func testListingFoldersAndObjects() async throws {
        for key in ["a.txt", "docs/b.txt", "docs/sub/c.txt", "img/d.png"] {
            try await provider.putObject(data: Data(key.utf8), objectKey: key, contentType: "text/plain")
        }
        try await provider.createFolder(prefix: "empty/")

        let root = try await provider.list(prefix: "", continuationToken: nil)
        XCTAssertEqual(Set(root.folders), ["docs/", "img/", "empty/"])
        XCTAssertEqual(root.objects.map(\.key), ["a.txt"])
        XCTAssertNil(root.nextContinuationToken)

        let docs = try await provider.list(prefix: "docs/", continuationToken: nil)
        XCTAssertEqual(docs.folders, ["docs/sub/"])
        XCTAssertEqual(docs.objects.map(\.key), ["docs/b.txt"])
        XCTAssertEqual(docs.objects.first?.size, Int64("docs/b.txt".utf8.count))

        // The empty folder's placeholder isn't a file in it.
        let empty = try await provider.list(prefix: "empty/", continuationToken: nil)
        XCTAssertEqual(empty.objects, [])

        let everything = try await provider.listRecursively(prefix: "", continuationToken: nil)
        XCTAssertEqual(Set(everything.objects.map(\.key)), ["a.txt", "docs/b.txt", "docs/sub/c.txt", "img/d.png"])
        XCTAssertEqual(everything.folders, ["empty/"])
    }

    func testRenamingIsCopyThenDelete() async throws {
        try await provider.putObject(data: Data("x".utf8), objectKey: "old name/ç #1.txt", contentType: "text/plain")
        try await provider.copy(from: "old name/ç #1.txt", to: "new/ç #2.txt")
        try await provider.delete(objectKey: "old name/ç #1.txt")
        let objectExists = try await provider.objectExists(key: "old name/ç #1.txt")
        XCTAssertFalse(objectExists)
        let data = try await provider.getObject(key: "new/ç #2.txt", maxBytes: 10)?.data
        XCTAssertEqual(data, Data("x".utf8))
        // Deleting what isn't there succeeds, as S3 does.
        try await provider.delete(objectKey: "old name/ç #1.txt")
    }

    func testPagesAndBatchDeletesPastOneThousand() async throws {
        let keys = (0..<1005).map { String(format: "many/%04d.txt", $0) }
        let provider = provider!
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = keys.makeIterator()
            for _ in 0..<16 {
                guard let key = pending.next() else { break }
                group.addTask { try await provider.putObject(data: Data(), objectKey: key, contentType: "text/plain") }
            }
            while try await group.next() != nil {
                if let key = pending.next() {
                    group.addTask { try await provider.putObject(data: Data(), objectKey: key, contentType: "text/plain") }
                }
            }
        }

        let first = try await provider.listRecursively(prefix: "many/", continuationToken: nil)
        XCTAssertEqual(first.objects.count, 1000)
        let token = try XCTUnwrap(first.nextContinuationToken)
        let second = try await provider.listRecursively(prefix: "many/", continuationToken: token)
        XCTAssertEqual(second.objects.count, 5)
        XCTAssertNil(second.nextContinuationToken)
        XCTAssertEqual(first.objects.map(\.key) + second.objects.map(\.key), keys)

        try await provider.delete(objectKeys: keys)
        let objects = try await provider.listRecursively(prefix: "many/", continuationToken: nil).objects
        XCTAssertEqual(objects, [])
    }

    // MARK: - Lifecycle rules

    func testExpiryRulesKeepTheBucketsOwnRules() async throws {
        _ = try await provider.s3.putBucketLifecycleConfiguration(.init(
            bucket: bucket,
            lifecycleConfiguration: .init(rules: [
                .init(expiration: .init(days: 90), filter: .init(prefix: "logs/"), id: "logs", status: .enabled),
            ])
        ))
        let inPlaceBefore = try await provider.expiryRulesInPlace()
        XCTAssertFalse(inPlaceBefore)

        try await provider.ensureExpiryRules()
        let inPlace = try await provider.expiryRulesInPlace()
        XCTAssertTrue(inPlace)
        let ids = try await lifecycleRuleIDs()
        XCTAssertEqual(ids, Set(["logs"] + UploadExpiry.options.map(UploadExpiry.ruleID(days:))))
        // Again: nothing to do.
        try await provider.ensureExpiryRules()
        let idsAgain = try await lifecycleRuleIDs()
        XCTAssertEqual(idsAgain, ids)

        try await provider.removeExpiryRules()
        let inPlaceAfter = try await provider.expiryRulesInPlace()
        XCTAssertFalse(inPlaceAfter)
        let idsAfter = try await lifecycleRuleIDs()
        XCTAssertEqual(idsAfter, ["logs"], "the bucket's own rule stays")
    }

    func testExpiryRulesOnABucketWithoutRules() async throws {
        let inPlaceBefore = try await provider.expiryRulesInPlace()
        XCTAssertFalse(inPlaceBefore)
        // Nothing to take out of a bucket without rules.
        try await provider.removeExpiryRules()

        try await provider.putObject(data: Data(), objectKey: UploadExpiry.prefix(days: 7) + "a.txt", contentType: "text/plain")
        let inUseBefore = try await provider.expiryPrefixesInUse()
        XCTAssertEqual(inUseBefore, [UploadExpiry.prefix(days: 7)], "files already there are asked about first")

        try await provider.ensureExpiryRules()
        let inPlace = try await provider.expiryRulesInPlace()
        XCTAssertTrue(inPlace)
        let inUse = try await provider.expiryPrefixesInUse()
        XCTAssertEqual(inUse, [])

        // Only Aktar's rules: the whole configuration goes.
        try await provider.removeExpiryRules()
        let idsAfter = try await lifecycleRuleIDs()
        XCTAssertEqual(idsAfter, [])
    }

    // MARK: - Thumbnails in the bucket

    func testThumbnailsFollowTheirFiles() async throws {
        let prefixes = [".thumbnails/", "thumbs/"]
        let webp = Data("RIFF....WEBP".utf8)
        for prefix in prefixes {
            try await BucketThumbnails.save(webp, for: "2026/a.png", prefix: prefix, provider: provider)
        }
        let fetch = await BucketThumbnails.fetch(for: "2026/a.png", prefix: ".thumbnails/", writtenAfter: nil, provider: provider)
        XCTAssertEqual(fetch, webp)
        // A thumbnail older than the file it shows isn't used.
        let fetch2 = await BucketThumbnails.fetch(for: "2026/a.png", prefix: ".thumbnails/", writtenAfter: Date.now.addingTimeInterval(3600), provider: provider)
        XCTAssertNil(fetch2)
        let fetch3 = await BucketThumbnails.fetch(for: "2026/none.png", prefix: ".thumbnails/", writtenAfter: nil, provider: provider)
        XCTAssertNil(fetch3)

        await BucketThumbnails.copy(from: "2026/a.png", to: "moved/a.png", prefixes: prefixes, provider: provider)
        try await BucketThumbnails.delete(for: "2026/a.png", prefixes: prefixes, provider: provider)
        for prefix in prefixes {
            let fetch4 = await BucketThumbnails.fetch(for: "2026/a.png", prefix: prefix, writtenAfter: nil, provider: provider)
            XCTAssertNil(fetch4)
            let fetch5 = await BucketThumbnails.fetch(for: "moved/a.png", prefix: prefix, writtenAfter: nil, provider: provider)
            XCTAssertEqual(fetch5, webp)
        }

        // Emptying a folder only takes thumbnails.
        try await provider.putObject(data: Data("keep".utf8), objectKey: ".thumbnails/readme.txt", contentType: "text/plain")
        try await BucketThumbnails.save(webp, for: UploadExpiry.prefix(days: 1) + "b.png", prefix: ".thumbnails/", provider: provider)
        try await BucketThumbnails.deleteAll(prefix: ".thumbnails/", provider: provider)
        let left = try await provider.listRecursively(prefix: "", continuationToken: nil).objects.map(\.key)
        XCTAssertTrue(left.contains(".thumbnails/readme.txt"))
        XCTAssertFalse(left.contains { $0.hasPrefix(".thumbnails/") && $0.hasSuffix(".webp") })
        XCTAssertFalse(left.contains { $0.hasPrefix(UploadExpiry.prefix(days: 1)) && $0.hasSuffix(".webp") })
        XCTAssertTrue(left.contains("thumbs/moved/a.png.webp"))
    }

    // MARK: - Helpers

    private func destination() -> DestinationConfig {
        DestinationConfig(
            name: "Integration", preset: .minIO, accountID: nil, endpoint: endpoint, region: "us-east-1",
            bucket: bucket, publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: true, isDefault: false
        )
    }

    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 8) {
                var value = generator.next()
                withUnsafeBytes(of: &value) { random in
                    for offset in 0..<min(8, buffer.count - index) { buffer[index + offset] = random[offset] }
                }
            }
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func multipartSession(objectKey: String, uploadId: String, partSize: Int64, fileSize: Int64, file: URL, parts: [MultipartSession.Part]) -> MultipartSession {
        MultipartSession(
            destinationID: provider.config.id, bucket: bucket, objectKey: objectKey, uploadId: uploadId, partSize: partSize,
            fileSize: fileSize, fileModifiedAt: nil, sourcePath: file.path, contentHash: nil, keyBasis: nil,
            completedParts: parts, createdAt: .now
        )
    }

    private func allowPublicReads() async throws {
        let policy = """
        {"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::\(bucket)/*"]}]}
        """
        _ = try await provider.s3.putBucketPolicy(.init(bucket: bucket, policy: .init(string: policy)))
    }

    private func lifecycleRuleIDs() async throws -> Set<String> {
        do {
            let output = try await provider.s3.getBucketLifecycleConfiguration(.init(bucket: bucket))
            return Set((output.rules ?? []).compactMap(\.id))
        } catch {
            if "\(error)".contains("NoSuchLifecycleConfiguration") { return [] }
            throw error
        }
    }

    private func assertSameContents(_ file: URL, key: String, size: Int64, line: UInt = #line) async throws {
        let downloaded = directory.appendingPathComponent(UUID().uuidString)
        let found = try await provider.download(key: key, to: downloaded, maxBytes: size)
        XCTAssertTrue(found, line: line)
        XCTAssertEqual(try Self.sha256(downloaded), try Self.sha256(file), "the object must be the file, byte for byte", line: line)
    }

    private static func sha256(_ url: URL) throws -> String {
        try ContentHasher.hashes(of: url, md5: false, sha256: true).sha256 ?? ""
    }

    private static func status(of url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static func empty(_ bucket: String, provider: S3Provider) async {
        if let uploads = try? await provider.s3.listMultipartUploads(.init(bucket: bucket)).uploads {
            for upload in uploads {
                if let key = upload.key, let id = upload.uploadId { await provider.abortMultipartUpload(objectKey: key, uploadId: id) }
            }
        }
        var token: String?
        repeat {
            guard let page = try? await provider.listRecursively(prefix: "", continuationToken: token) else { return }
            try? await provider.delete(objectKeys: page.objects.map(\.key) + page.folders)
            token = page.nextContinuationToken
        } while token != nil
    }

    private func assertThrows<E: Error>(_ expected: E, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual("\(error)", "\(expected)", line: line)
        }
    }
}

/// Progress values as they arrive on the main actor.
private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] { lock.withLock { stored } }

    func add(_ value: Double) { lock.withLock { stored.append(value) } }
}
