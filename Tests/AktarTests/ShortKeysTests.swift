import XCTest

final class ShortKeysTests: XCTestCase {
    // MARK: - Generator

    func testCodesAreSevenBase62Characters() {
        let alphabet = Set(ShortCode.alphabet)
        XCTAssertEqual(alphabet.count, 62)
        for _ in 0..<1_000 {
            let code = ShortCode.make()
            XCTAssertEqual(code.count, ShortCode.length)
            XCTAssertTrue(code.allSatisfy(alphabet.contains), code)
        }
    }

    func testCodesAreRoughlyUniform() {
        var counts: [Character: Int] = [:]
        let codes = 20_000
        for _ in 0..<codes {
            for character in ShortCode.make() { counts[character, default: 0] += 1 }
        }
        XCTAssertEqual(counts.count, 62)
        let expected = Double(codes * ShortCode.length) / 62
        for (character, count) in counts {
            XCTAssertEqual(Double(count), expected, accuracy: expected * 0.2, "\(character)")
        }
    }

    func testBytesFrom248UpAreDrawnAgain() {
        var batches: [[UInt8]] = [[248, 255, 0, 61, 62, 247, 250], [1, 2, 3, 4, 5, 6, 7]]
        let code = ShortCode.make { _ in batches.removeFirst() }
        // 0, 61, 62 % 62, 247 % 62, then the next batch fills the rest.
        XCTAssertEqual(code, "0z0z123")
    }

    func testShortCountsAsUnique() {
        XCTAssertTrue(ObjectKeyGenerator.hasUniqueToken("{short}.{ext}"))
        XCTAssertTrue(ObjectKeyGenerator.hasUniqueToken("{year}/{month}/{short}.{ext}"))
        XCTAssertTrue(ObjectKeyGenerator.usesShortCode("{short}.{ext}"))
        XCTAssertFalse(ObjectKeyGenerator.usesShortCode("{filename}.{ext}"))
    }

    func testTemplateUsesTheCode() {
        let key = ObjectKeyGenerator.generate(template: "{year}/{short}.{ext}", originalFilename: "photo.png", date: Date(timeIntervalSince1970: 0)) { "A7kdP2x" }
        XCTAssertEqual(key, "1970/A7kdP2x.png")
        // No code is drawn for a template without {short}.
        _ = ObjectKeyGenerator.generate(template: "{uuid}.{ext}", originalFilename: "photo.png") {
            XCTFail("drew a code")
            return ""
        }
    }

    // MARK: - Collisions

    func testCollisionGetsANewCodeWithConditionalWrites() async throws {
        try await assertSkipsTakenCode(conditional: true)
    }

    func testCollisionGetsANewCodeWhenAskingFirst() async throws {
        try await assertSkipsTakenCode(conditional: false)
    }

    func testFiveCollisionsFailWithoutOverwritingConditional() async {
        await assertFailsAfterFiveCollisions(conditional: true)
    }

    func testFiveCollisionsFailWithoutOverwritingAskingFirst() async {
        await assertFailsAfterFiveCollisions(conditional: false)
    }

    private func assertSkipsTakenCode(conditional: Bool) async throws {
        let bucket = FakeBucket(objects: ["ABC1234.png": "old"])
        let codes = Codes(["ABC1234", "ABC1234", "XYZ9876"])
        let key = try await upload(to: bucket, codes: codes, conditional: conditional)
        XCTAssertEqual(key, "XYZ9876.png")
        XCTAssertEqual(bucket.objects, ["ABC1234.png": "old", "XYZ9876.png": "new"])
        XCTAssertTrue(codes.isEmpty)
    }

    private func assertFailsAfterFiveCollisions(conditional: Bool) async {
        let bucket = FakeBucket(objects: ["ABC1234.png": "old"])
        let codes = Codes(Array(repeating: "ABC1234", count: ShortKeys.maxAttempts))
        do {
            _ = try await upload(to: bucket, codes: codes, conditional: conditional)
            XCTFail("uploaded")
        } catch StorageError.noFreeShortKey {
            // Expected.
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(bucket.objects, ["ABC1234.png": "old"])
        XCTAssertTrue(codes.isEmpty)
        // Only conditional writes are tried on a taken key.
        XCTAssertEqual(bucket.writes, conditional ? ShortKeys.maxAttempts : 0)
    }

    private func upload(to bucket: FakeBucket, codes: Codes, conditional: Bool) async throws -> String {
        func makeKey() -> String {
            ObjectKeyGenerator.generate(template: "{short}.{ext}", originalFilename: "photo.png", shortCode: codes.next)
        }
        return try await ShortKeys.write(
            firstKey: makeKey(),
            conditional: conditional,
            newKey: makeKey,
            exists: { bucket.objects[$0] != nil },
            write: { key, onlyIfNew in try bucket.put(key, "new", onlyIfNew: onlyIfNew) }
        )
    }

    // MARK: - Custom domains

    func testOwnDomainHost() {
        let r2 = "https://abc.r2.cloudflarestorage.com"
        XCTAssertEqual(PublicURLResolver.ownDomainHost(baseURL: "https://files.example.com", endpoint: r2), "files.example.com")
        XCTAssertEqual(PublicURLResolver.ownDomainHost(baseURL: "img.example.com/", endpoint: r2), "img.example.com")
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://pub-123.r2.dev", endpoint: r2))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://b.s3.us-east-1.amazonaws.com", endpoint: "s3.us-east-1.amazonaws.com"))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://f005.backblazeb2.com/file/b", endpoint: "s3.us-west-005.backblazeb2.com"))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://b.fra1.digitaloceanspaces.com", endpoint: "fra1.digitaloceanspaces.com"))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://minio.example.com/bucket", endpoint: "https://minio.example.com"))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "https://bucket.minio.example.com", endpoint: "minio.example.com"))
        XCTAssertNil(PublicURLResolver.ownDomainHost(baseURL: "", endpoint: r2))
    }
}

/// The codes a test hands out, in order.
private final class Codes {
    private var codes: [String]

    init(_ codes: [String]) { self.codes = codes }

    var isEmpty: Bool { codes.isEmpty }

    func next() -> String {
        guard !codes.isEmpty else {
            XCTFail("ran out of codes")
            return "0000000"
        }
        return codes.removeFirst()
    }
}

/// A bucket that refuses a conditional write to a taken key, as S3 and R2
/// do with `If-None-Match: *`.
private final class FakeBucket {
    var objects: [String: String]
    private(set) var writes = 0

    init(objects: [String: String]) { self.objects = objects }

    func put(_ key: String, _ value: String, onlyIfNew: Bool) throws {
        writes += 1
        if onlyIfNew, objects[key] != nil { throw StorageError.alreadyExists }
        objects[key] = value
    }
}
