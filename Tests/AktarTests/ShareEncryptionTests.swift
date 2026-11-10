import CryptoKit
import XCTest

/// The encrypted file format against docs/share-page/vectors.json (made by
/// docs/share-page/test.mjs with the reference and the page's own
/// decryptor): byte for byte the same output, and back.
final class ShareEncryptionTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Link: Decodable {
            let size: Int
            let meta: String
            let encryptedLength: Int
            let sha256: String
            let hex: String?
        }

        struct Password: Decodable {
            let password: String
            let salt: String
            let iterations: UInt32
            let derivedKey: String
            let size: Int
            let meta: String
            let encryptedLength: Int
            let sha256: String
        }

        let rawKey: String
        let noncePrefix: String
        let link: [Link]
        let password: Password
    }

    private var vectors: Vectors!
    private var folder: URL!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vectors", withExtension: "json"))
        vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShareEncryptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Byte i is i % 251.
    private func pattern(_ size: Int, name: String = UUID().uuidString) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data((0..<size).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        ShareEncryption.hex(Data(SHA256.hash(data: try Data(contentsOf: url))))
    }

    private func metadata(_ json: String) throws -> ShareEncryption.Metadata {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ShareEncryption.Metadata(
            name: try XCTUnwrap(object["name"] as? String),
            type: try XCTUnwrap(object["type"] as? String),
            size: Int64(try XCTUnwrap(object["size"] as? Int)),
            syntax: object["syntax"] as? String
        )
    }

    private var linkKeys: ShareEncryption.KeyMaterial {
        ShareEncryption.KeyMaterial(key: ShareEncryption.data(hex: vectors.rawKey)!, salt: nil)
    }

    private var noncePrefix: Data { ShareEncryption.data(hex: vectors.noncePrefix)! }

    func testLinkVectorsByteForByte() throws {
        for vector in vectors.link {
            let source = try pattern(vector.size)
            let meta = try metadata(vector.meta)
            XCTAssertEqual(String(decoding: meta.json, as: UTF8.self), vector.meta, "metadata JSON for \(vector.size)")
            let sealed = folder.appendingPathComponent("sealed-\(vector.size)")
            let length = try ShareEncryption.encrypt(file: source, to: sealed, metadata: meta, keys: linkKeys, noncePrefix: noncePrefix)
            XCTAssertEqual(length, Int64(vector.encryptedLength))
            XCTAssertEqual(ShareEncryption.encryptedSize(plaintextSize: Int64(vector.size), metadataLength: meta.json.count), Int64(vector.encryptedLength))
            XCTAssertEqual(try sha256(sealed), vector.sha256, "sha256 for \(vector.size)")
            if let hex = vector.hex {
                XCTAssertEqual(ShareEncryption.hex(try Data(contentsOf: sealed)), hex)
            }

            // And back.
            let opened = folder.appendingPathComponent("opened-\(vector.size)")
            let got = try ShareEncryption.decrypt(file: sealed, to: opened) { header in
                XCTAssertEqual(header.kdf, 0)
                XCTAssertEqual(header.iterations, 0)
                return self.linkKeys.key
            }
            XCTAssertEqual(got, meta)
            XCTAssertEqual(try Data(contentsOf: opened), try Data(contentsOf: source))
        }
    }

    func testPasswordVector() throws {
        let vector = vectors.password
        let salt = try XCTUnwrap(ShareEncryption.data(hex: vector.salt))
        let derived = ShareEncryption.deriveKey(password: vector.password, salt: salt, iterations: vector.iterations)
        XCTAssertEqual(ShareEncryption.hex(derived), vector.derivedKey)
        let keys = ShareEncryption.KeyMaterial(key: derived, salt: salt)
        XCTAssertEqual(keys.iterations, 600_000)
        XCTAssertNil(keys.fragment, "a password's key is never in the link")
        let meta = try metadata(vector.meta)
        XCTAssertEqual(String(decoding: meta.json, as: UTF8.self), vector.meta)
        let source = try pattern(vector.size)
        let sealed = folder.appendingPathComponent("sealed-pw")
        XCTAssertEqual(try ShareEncryption.encrypt(file: source, to: sealed, metadata: meta, keys: keys, noncePrefix: noncePrefix), Int64(vector.encryptedLength))
        XCTAssertEqual(try sha256(sealed), vector.sha256)

        let opened = folder.appendingPathComponent("opened-pw")
        let got = try ShareEncryption.decrypt(file: sealed, to: opened) { header in
            XCTAssertEqual(header.kdf, 1)
            XCTAssertEqual(header.salt, salt)
            return ShareEncryption.deriveKey(password: vector.password, salt: header.salt, iterations: header.iterations)
        }
        XCTAssertEqual(got.syntax, "markdown")
        XCTAssertEqual(try Data(contentsOf: opened), try Data(contentsOf: source))

        XCTAssertThrowsError(try ShareEncryption.decrypt(file: sealed, to: opened) { header in
            ShareEncryption.deriveKey(password: "wrong", salt: header.salt, iterations: header.iterations)
        }) { XCTAssertEqual($0 as? ShareEncryption.Failure, .wrongKey) }
    }

    func testPasswordsAreNormalized() {
        let salt = Data(repeating: 0x5A, count: 16)
        XCTAssertEqual(
            ShareEncryption.deriveKey(password: "caf\u{E9}", salt: salt, iterations: 100_000),
            ShareEncryption.deriveKey(password: "cafe\u{301}", salt: salt, iterations: 100_000)
        )
    }

    func testTruncatedAndAlteredFilesAreRefused() throws {
        for size in [0, 5, 65_536, 65_537, 200_000] {
            let meta = ShareEncryption.Metadata(name: "f", type: "application/octet-stream", size: Int64(size))
            let sealed = folder.appendingPathComponent("t-\(size)")
            try ShareEncryption.encrypt(file: try pattern(size), to: sealed, metadata: meta, keys: linkKeys, noncePrefix: noncePrefix)
            let bytes = try Data(contentsOf: sealed)
            let opened = folder.appendingPathComponent("o-\(size)")
            // Cut at a record boundary or inside one: never accepted.
            for cut in [bytes.count - 16, bytes.count - 1, 42 + meta.json.count + 16] where cut > 42 && cut < bytes.count {
                let truncated = folder.appendingPathComponent("cut")
                try bytes.prefix(cut).write(to: truncated)
                XCTAssertThrowsError(try ShareEncryption.decrypt(file: truncated, to: opened) { _ in self.linkKeys.key }, "cut at \(cut) of \(size)")
            }
            // One flipped bit after the header.
            var flipped = bytes
            flipped[flipped.count - 3] ^= 1
            let altered = folder.appendingPathComponent("flipped")
            try flipped.write(to: altered)
            XCTAssertThrowsError(try ShareEncryption.decrypt(file: altered, to: opened) { _ in self.linkKeys.key })
            // A wrong key fails on the metadata.
            XCTAssertThrowsError(try ShareEncryption.decrypt(file: sealed, to: opened) { _ in Data(repeating: 7, count: 32) }) {
                XCTAssertEqual($0 as? ShareEncryption.Failure, .wrongKey)
            }
        }
    }

    func testReorderedRecordsAreRefused() throws {
        let size = 3 * 65_536
        let meta = ShareEncryption.Metadata(name: "f", type: "application/octet-stream", size: Int64(size))
        let sealed = folder.appendingPathComponent("r")
        try ShareEncryption.encrypt(file: try pattern(size), to: sealed, metadata: meta, keys: linkKeys, noncePrefix: noncePrefix)
        var bytes = try Data(contentsOf: sealed)
        let start = 42 + meta.json.count + 16
        let record = 65_536 + 16
        let first = bytes.subdata(in: start..<start + record)
        let second = bytes.subdata(in: start + record..<start + 2 * record)
        bytes.replaceSubrange(start..<start + record, with: second)
        bytes.replaceSubrange(start + record..<start + 2 * record, with: first)
        let swapped = folder.appendingPathComponent("swapped")
        try bytes.write(to: swapped)
        XCTAssertThrowsError(try ShareEncryption.decrypt(file: swapped, to: folder.appendingPathComponent("o")) { _ in self.linkKeys.key })
    }

    func testAChangedFileIsNotSealed() throws {
        let source = try pattern(100)
        let meta = ShareEncryption.Metadata(name: "f", type: "text/plain", size: 99)
        XCTAssertThrowsError(try ShareEncryption.encrypt(file: source, to: folder.appendingPathComponent("x"), metadata: meta, keys: linkKeys))
    }

    func testBigFileRoundTripWithNewKeys() throws {
        let size = 5_000_003
        let source = try pattern(size)
        let keys = ShareEncryption.KeyMaterial.newLinkKey()
        XCTAssertEqual(keys.key.count, 32)
        let fragment = try XCTUnwrap(keys.fragment)
        XCTAssertTrue(fragment.hasPrefix("k="))
        XCTAssertFalse(fragment.dropFirst(2).contains("="), "no padding")
        XCTAssertEqual(ShareEncryption.base64URLDecoded(String(fragment.dropFirst(2))), keys.key)
        let meta = ShareEncryption.Metadata(name: "big.bin", type: "application/octet-stream", size: Int64(size))
        let sealed = folder.appendingPathComponent("big.sealed")
        let length = try ShareEncryption.encrypt(file: source, to: sealed, metadata: meta, keys: keys)
        XCTAssertEqual(length, ShareEncryption.encryptedSize(plaintextSize: Int64(size), metadataLength: meta.json.count))
        let opened = folder.appendingPathComponent("big.opened")
        XCTAssertEqual(try ShareEncryption.decrypt(file: sealed, to: opened) { _ in keys.key }, meta)
        XCTAssertEqual(try sha256(opened), try sha256(source))
        // Every file gets its own nonce prefix.
        let again = folder.appendingPathComponent("big.sealed2")
        try ShareEncryption.encrypt(file: source, to: again, metadata: meta, keys: keys)
        XCTAssertNotEqual(try sha256(again), try sha256(sealed))
    }

    func testHeaderChecks() throws {
        var header = ShareEncryption.Header(kdf: 0, iterations: 0, salt: Data(count: 16), noncePrefix: Data(count: 8), recordSize: 65_536, metadataLength: 40).bytes
        XCTAssertEqual(header.count, 42)
        XCTAssertNoThrow(try ShareEncryption.Header(parsing: header))
        header[6 + 3] = 1 // iterations for kdf 0
        XCTAssertThrowsError(try ShareEncryption.Header(parsing: header))
        let password = ShareEncryption.Header(kdf: 1, iterations: 99_999, salt: Data(count: 16), noncePrefix: Data(count: 8), recordSize: 65_536, metadataLength: 40).bytes
        XCTAssertThrowsError(try ShareEncryption.Header(parsing: password), "too few iterations")
        var magic = ShareEncryption.Header(kdf: 0, iterations: 0, salt: Data(count: 16), noncePrefix: Data(count: 8), recordSize: 65_536, metadataLength: 40).bytes
        magic[3] = 0x32
        XCTAssertThrowsError(try ShareEncryption.Header(parsing: magic))
    }
}
