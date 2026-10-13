import XCTest

/// The S3 layer's pieces that don't need a bucket: part sizes, key
/// encoding, presigned links, which failures are retried, error mapping,
/// resuming multipart uploads, and the Cloudflare R2 setup's derived keys.
final class S3ProviderTests: XCTestCase {
    private let mib: Int64 = 1024 * 1024

    // MARK: - Multipart

    func testPartSizeIsAtLeast16MiBInWholeMiB() {
        XCTAssertEqual(S3Provider.partSize(forFileSize: 0), 16 * mib)
        XCTAssertEqual(S3Provider.partSize(forFileSize: S3Provider.multipartThreshold + 1), 16 * mib)
        XCTAssertEqual(S3Provider.partSize(forFileSize: 10 * 1024 * mib), 16 * mib)
        for size: Int64 in [200 * 1024 * mib, 1_000_000_000_000, 5 * 1024 * 1024 * 1024 * mib] {
            let part = S3Provider.partSize(forFileSize: size)
            XCTAssertEqual(part % mib, 0)
            XCTAssertGreaterThanOrEqual(part, 16 * mib)
            // S3 allows 10,000 parts; the size leaves room to spare.
            XCTAssertLessThanOrEqual(S3Provider.partCount(fileSize: size, partSize: part), 9000)
        }
    }

    func testPartCount() {
        XCTAssertEqual(S3Provider.partCount(fileSize: 0, partSize: 16 * mib), 1)
        XCTAssertEqual(S3Provider.partCount(fileSize: 16 * mib, partSize: 16 * mib), 1)
        XCTAssertEqual(S3Provider.partCount(fileSize: 16 * mib + 1, partSize: 16 * mib), 2)
        XCTAssertEqual(S3Provider.partCount(fileSize: 100 * mib, partSize: 16 * mib), 7)
    }

    func testFileSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 1234).write(to: url)
        XCTAssertEqual(try S3Provider.fileSize(of: url), 1234)
        XCTAssertThrowsError(try S3Provider.fileSize(of: url.appendingPathExtension("missing")))
    }

    func testSessionsResumeOnlyForTheSameFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 10).write(to: url)
        let modified = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        func session(path: String = url.standardizedFileURL.path, size: Int64 = 10, modifiedAt: Date? = modified, hash: String? = nil) -> MultipartSession {
            MultipartSession(
                destinationID: UUID(), bucket: "b", objectKey: "k", uploadId: "u", partSize: 16 * mib,
                fileSize: size, fileModifiedAt: modifiedAt, sourcePath: path, contentHash: hash,
                keyBasis: nil, completedParts: [], createdAt: .now
            )
        }

        let identity = MultipartFileIdentity(fileURL: url, size: 10, contentHash: nil)
        XCTAssertTrue(identity.matches(session()))
        XCTAssertFalse(identity.matches(session(size: 11)))
        XCTAssertFalse(identity.matches(session(path: "/elsewhere.bin")))
        XCTAssertFalse(identity.matches(session(modifiedAt: modified.addingTimeInterval(5))))
        XCTAssertFalse(identity.matches(session(modifiedAt: nil)))

        // With a hash on both sides, the hash decides: a moved file still resumes.
        let hashed = MultipartFileIdentity(fileURL: url, size: 10, contentHash: "abc")
        XCTAssertTrue(hashed.matches(session(path: "/moved.bin", modifiedAt: nil, hash: "abc")))
        XCTAssertFalse(hashed.matches(session(hash: "def")))
    }

    func testOldSessionsAreStale() {
        func session(age: TimeInterval) -> MultipartSession {
            MultipartSession(
                destinationID: UUID(), bucket: "b", objectKey: "k", uploadId: "u", partSize: 1, fileSize: 1,
                fileModifiedAt: nil, sourcePath: "/a", contentHash: nil, keyBasis: nil, completedParts: [],
                createdAt: Date.now.addingTimeInterval(-age)
            )
        }
        XCTAssertFalse(session(age: 60).isStale)
        XCTAssertFalse(session(age: MultipartSession.maxAge - 60).isStale)
        XCTAssertTrue(session(age: MultipartSession.maxAge + 60).isStale)
    }

    // MARK: - Keys and links

    func testKeysArePercentEncodedPerSegment() {
        XCTAssertEqual(S3Provider.encodePath("2026/10/photo.png"), "2026/10/photo.png")
        XCTAssertEqual(S3Provider.encodePath("a b/c?d#e.png"), "a%20b/c%3Fd%23e.png")
        XCTAssertEqual(S3Provider.encodePath("çay/ğ.txt"), "%C3%A7ay/%C4%9F.txt")
        // Empty segments stay, so "a//b" isn't turned into another key.
        XCTAssertEqual(S3Provider.encodePath("a//b"), "a//b")
        XCTAssertEqual(S3Provider.encodePath("folder/"), "folder/")
    }

    func testTemporaryLinksArePresignedForTheRightAddress() async throws {
        let pathStyle = S3Provider(config: Self.destination(endpoint: "https://minio.example.com:9000", pathStyle: true), credentials: Self.credentials)
        let url = try await pathStyle.temporaryURL(for: "a b/c.png", expiresIn: 300)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "minio.example.com")
        XCTAssertEqual(components.port, 9000)
        XCTAssertEqual(components.percentEncodedPath, "/bucket/a%20b/c.png")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["X-Amz-Expires"], "300")
        XCTAssertEqual(query["X-Amz-Algorithm"], "AWS4-HMAC-SHA256")
        XCTAssertTrue(query["X-Amz-Credential"]?.hasPrefix("AKIDEXAMPLE/") == true)
        XCTAssertNotNil(query["X-Amz-Signature"])

        // Virtual hosted, and a bare endpoint gets https.
        let virtual = S3Provider(config: Self.destination(endpoint: "s3.us-east-1.amazonaws.com", pathStyle: false), credentials: Self.credentials)
        let hosted = try await virtual.temporaryURL(for: "c.png", expiresIn: 60)
        XCTAssertEqual(hosted.scheme, "https")
        XCTAssertEqual(hosted.host, "bucket.s3.us-east-1.amazonaws.com")
        XCTAssertEqual(hosted.path, "/c.png")
    }

    func testShortCacheSetsCacheControl() {
        var config = Self.destination(endpoint: "https://s3.example.com", pathStyle: true)
        XCTAssertNil(S3Provider(config: config, credentials: Self.credentials).cacheControl)
        config.shortCache = true
        XCTAssertEqual(S3Provider(config: config, credentials: Self.credentials).cacheControl, "public, max-age=60")
    }

    // MARK: - Failures

    func testOnlyFailuresThatMightPassAreRetried() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(S3Provider.isTransient(URLError(code)), "\(code)")
        }
        for code: URLError.Code in [.cancelled, .badURL, .userAuthenticationRequired, .serverCertificateUntrusted] {
            XCTAssertFalse(S3Provider.isTransient(URLError(code)), "\(code)")
        }
        XCTAssertFalse(S3Provider.isTransient(StorageError.accessDenied))
        XCTAssertFalse(S3Provider.isTransient(CancellationError()))
    }

    func testErrorsAreMappedFromTheProvidersCodes() {
        struct Raw: Error, CustomStringConvertible { let description: String }
        func mapped(_ text: String) -> String { "\(S3Provider.mapError(Raw(description: text), bucket: "photos"))" }

        XCTAssertEqual(mapped("NoSuchBucket: The specified bucket does not exist"), "\(StorageError.bucketNotFound("photos"))")
        XCTAssertEqual(mapped("AccessDenied"), "\(StorageError.accessDenied)")
        XCTAssertEqual(mapped("403 Forbidden"), "\(StorageError.accessDenied)")
        XCTAssertEqual(mapped("InvalidAccessKeyId"), "\(StorageError.invalidCredentials)")
        XCTAssertEqual(mapped("SignatureDoesNotMatch"), "\(StorageError.invalidCredentials)")
        XCTAssertEqual(mapped("PreconditionFailed"), "\(StorageError.alreadyExists)")
        XCTAssertEqual(mapped("ConditionalRequestConflict"), "\(StorageError.alreadyExists)")
        guard case .unknown(let message) = S3Provider.mapError(Raw(description: "SlowDown"), bucket: "photos") else {
            return XCTFail("an unknown failure keeps its own description")
        }
        XCTAssertTrue(message.contains("SlowDown"))
    }

    // MARK: - Cloudflare R2

    func testR2KeysAreDerivedFromTheToken() {
        // The secret is the SHA-256 of the token's value, in lowercase hex:
        // for "abc", the standard SHA-256 test vector.
        let digestOfABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let credentials = CloudflareSetup.credentials(tokenID: "token-id", token: "abc")
        XCTAssertEqual(credentials.accessKeyId, "token-id")
        XCTAssertEqual(credentials.secretAccessKey, digestOfABC)
        XCTAssertNil(credentials.sessionToken)
        XCTAssertEqual(DestinationConfig.deriveR2Endpoint(accountID: "0123abc"), "https://0123abc.r2.cloudflarestorage.com")
    }

    func testR2BucketNames() {
        for name in ["abc", "my-bucket-1", String(repeating: "a", count: 63)] {
            XCTAssertTrue(CloudflareSetup.isValidBucketName(name), name)
        }
        for name in ["ab", "-abc", "abc-", "My-Bucket", "a_b", "a.b", String(repeating: "a", count: 64), ""] {
            XCTAssertFalse(CloudflareSetup.isValidBucketName(name), name)
        }
    }

    func testR2CustomDomainsMustBeInTheZone() {
        let zone = CloudflareSetup.Zone(id: "z", name: "example.com")
        XCTAssertTrue(CloudflareSetup.isValidDomain("example.com", in: zone))
        XCTAssertTrue(CloudflareSetup.isValidDomain("files.example.com", in: zone))
        XCTAssertTrue(CloudflareSetup.isValidDomain("CDN.Example.com", in: zone))
        XCTAssertFalse(CloudflareSetup.isValidDomain("badexample.com", in: zone))
        XCTAssertFalse(CloudflareSetup.isValidDomain("example.com.evil.net", in: zone))
        XCTAssertFalse(CloudflareSetup.isValidDomain("-x.example.com", in: zone))
        XCTAssertFalse(CloudflareSetup.isValidDomain("a b.example.com", in: zone))
    }

    func testR2TokenLinkAsksForTheRightPermissions() throws {
        let components = try XCTUnwrap(URLComponents(url: CloudflareSetup.tokenURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "dash.cloudflare.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let permissions = try XCTUnwrap(items["permissionGroupKeys"])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(permissions.utf8)) as? [[String: String]])
        XCTAssertEqual(Set(parsed.map { "\($0["key"]!):\($0["type"]!)" }), ["workers_r2:edit", "zone:read"])
        XCTAssertEqual(items["name"], "Aktar")
    }

    // MARK: - Fixtures

    private static let credentials = StorageCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: nil)

    private static func destination(endpoint: String, pathStyle: Bool) -> DestinationConfig {
        DestinationConfig(
            name: "Test", preset: .customS3, accountID: nil, endpoint: endpoint, region: "us-east-1",
            bucket: "bucket", publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: pathStyle, isDefault: false
        )
    }
}

/// ListParts replies as providers write them, for resuming uploads.
final class ListPartsXMLTests: XCTestCase {
    func testMinIOsEmptyChecksumElementsAreSkipped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListPartsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>b</Bucket><Key>big.bin</Key><UploadId>abc</UploadId>\
        <PartNumberMarker>0</PartNumberMarker><NextPartNumberMarker>2</NextPartNumberMarker><MaxParts>10000</MaxParts><IsTruncated>false</IsTruncated>\
        <Part><PartNumber>1</PartNumber><LastModified>2026-10-13T16:38:37.566Z</LastModified><ETag>&#34;e1&#34;</ETag><Size>16777216</Size></Part>\
        <Part><PartNumber>2</PartNumber><ETag>&quot;e2&quot;</ETag><Size>10</Size></Part>\
        <ChecksumAlgorithm></ChecksumAlgorithm><ChecksumType></ChecksumType></ListPartsResult>
        """
        let page = try XCTUnwrap(ListPartsXML.page(Data(xml.utf8)))
        XCTAssertEqual(page.parts, [1: UploadedPart(eTag: "\"e1\"", size: 16_777_216), 2: UploadedPart(eTag: "\"e2\"", size: 10)])
        XCTAssertFalse(page.isTruncated)
    }

    func testTruncatedPages() throws {
        let xml = """
        <ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>1000</NextPartNumberMarker>\
        <Part><PartNumber>1000</PartNumber><ETag>"x"</ETag><Size>5</Size><ChecksumCRC32>AAAAAA==</ChecksumCRC32></Part></ListPartsResult>
        """
        let page = try XCTUnwrap(ListPartsXML.page(Data(xml.utf8)))
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextMarker, "1000")
        XCTAssertEqual(page.parts.keys.sorted(), [1000])
    }

    func testNoParts() throws {
        let page = try XCTUnwrap(ListPartsXML.page(Data("<ListPartsResult><IsTruncated>false</IsTruncated></ListPartsResult>".utf8)))
        XCTAssertEqual(page, ListPartsXML.Page())
    }

    func testAnythingElseIsntRead() {
        XCTAssertNil(ListPartsXML.page(Data("<Error><Code>NoSuchUpload</Code></Error>".utf8)))
        XCTAssertNil(ListPartsXML.page(Data("<html>proxy</html>".utf8)))
        XCTAssertNil(ListPartsXML.page(Data("<ListPartsResult><Part>".utf8)))
        XCTAssertNil(ListPartsXML.page(Data()))
    }
}
