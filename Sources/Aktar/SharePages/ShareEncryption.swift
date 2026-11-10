import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The encrypted file format of share pages (docs/share-pages.md,
/// "Encrypted links"), version 1: a 42-byte header, then AES-256-GCM
/// records of 64 KiB. All integers big-endian.
///
///     0   4  "AKE1"
///     4   1  version 1
///     5   1  kdf: 0 key in the link, 1 PBKDF2-HMAC-SHA256 password
///     6   4  iterations (0 for kdf 0)
///     10  16 salt (zeros for kdf 0)
///     26  8  nonce prefix
///     34  4  record size (65536)
///     38  4  metadata record length (plaintext + 16)
///
/// Record i (0 is the metadata) is sealed with nonce = prefix || i and
/// additional data = header || final, where final is 1 only for the last
/// content record. Files are read and written record by record, never
/// whole. `docs/share-page/vectors.json` has the reference's output.
enum ShareEncryption {
    static let headerLength = 42
    static let recordSize = 65536
    static let tagLength = 16
    static let passwordIterations: UInt32 = 600_000
    static let keyLength = 32
    static let saltLength = 16
    static let noncePrefixLength = 8
    static let magic: [UInt8] = [0x41, 0x4B, 0x45, 0x31]

    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The key is the link's fragment: `#k=<base64url>`.
        case link
        /// The key is derived from a password asked for each upload.
        case password

        var id: String { rawValue }
    }

    enum Failure: Error, Equatable {
        /// The metadata record didn't open: a wrong key or password.
        case wrongKey
        /// Truncated, reordered, altered, or not this format.
        case damaged
    }

    /// The file's name, type and size, sealed as record 0.
    struct Metadata: Equatable, Sendable {
        var name: String
        var type: String
        var size: Int64
        /// For text with a known language.
        var syntax: String?

        /// Exactly `{"name":..,"type":..,"size":..}` plus `"syntax"`.
        var json: Data {
            var fields: [(String, JSJSON)] = [("name", .string(name)), ("type", .string(type)), ("size", .int(size))]
            if let syntax, !syntax.isEmpty { fields.append(("syntax", .string(syntax))) }
            return Data(JSJSON.object(fields).serialized.utf8)
        }
    }

    struct Header: Equatable {
        var kdf: UInt8
        var iterations: UInt32
        var salt: Data
        var noncePrefix: Data
        var recordSize: UInt32
        var metadataLength: UInt32

        var bytes: Data {
            var data = Data(magic)
            data.append(1)
            data.append(kdf)
            data.append(bigEndian: iterations)
            data.append(salt)
            data.append(noncePrefix)
            data.append(bigEndian: recordSize)
            data.append(bigEndian: metadataLength)
            return data
        }

        /// Checked as the page checks it.
        init(parsing data: Data) throws {
            let bytes = [UInt8](data)
            guard bytes.count == headerLength, Array(bytes[0..<4]) == magic, bytes[4] == 1 else { throw Failure.damaged }
            kdf = bytes[5]
            iterations = Self.uint32(bytes, at: 6)
            salt = Data(bytes[10..<26])
            noncePrefix = Data(bytes[26..<34])
            recordSize = Self.uint32(bytes, at: 34)
            metadataLength = Self.uint32(bytes, at: 38)
            switch kdf {
            case 0: guard iterations == 0 else { throw Failure.damaged }
            case 1: guard (100_000...10_000_000).contains(iterations) else { throw Failure.damaged }
            default: throw Failure.damaged
            }
            guard (1024...16_777_216).contains(recordSize),
                  metadataLength >= UInt32(tagLength + 2), metadataLength <= UInt32(65536 + tagLength) else { throw Failure.damaged }
        }

        init(kdf: UInt8, iterations: UInt32, salt: Data, noncePrefix: Data, recordSize: UInt32, metadataLength: UInt32) {
            self.kdf = kdf
            self.iterations = iterations
            self.salt = salt
            self.noncePrefix = noncePrefix
            self.recordSize = recordSize
            self.metadataLength = metadataLength
        }

        private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
    }

    /// The key material of one encrypted upload.
    struct KeyMaterial: Equatable, Sendable {
        /// The raw key (link mode) or the one derived from the password.
        var key: Data
        /// The password's salt; nil in link mode.
        var salt: Data?
        var iterations: UInt32 { salt == nil ? 0 : passwordIterations }
        var kdf: UInt8 { salt == nil ? 0 : 1 }

        /// The link's fragment, `k=<base64url>`; nil for a password, which
        /// the link never carries.
        var fragment: String? {
            salt == nil ? "k=" + base64URL(key) : nil
        }

        static func newLinkKey() -> KeyMaterial {
            KeyMaterial(key: randomBytes(keyLength), salt: nil)
        }

        /// PBKDF2 over 600 000 iterations: a moment's work, so off the main
        /// thread.
        static func fromPassword(_ password: String, salt: Data = randomBytes(saltLength)) -> KeyMaterial {
            KeyMaterial(key: deriveKey(password: password, salt: salt, iterations: passwordIterations), salt: salt)
        }
    }

    /// Length of the encrypted file for a plaintext of `size` bytes.
    static func encryptedSize(plaintextSize size: Int64, metadataLength: Int) -> Int64 {
        let records = max(1, (size + Int64(recordSize) - 1) / Int64(recordSize))
        return Int64(headerLength + metadataLength + tagLength) + size + records * Int64(tagLength)
    }

    // MARK: - Encrypting

    /// Encrypts `source` into a new file at `destination`, record by
    /// record. Returns the encrypted file's length. `metadata.size` must be
    /// the source's size; a file that changes meanwhile fails.
    @discardableResult
    static func encrypt(
        file source: URL,
        to destination: URL,
        metadata: Metadata,
        keys: KeyMaterial,
        noncePrefix: Data = randomBytes(noncePrefixLength)
    ) throws -> Int64 {
        let metadataPlain = metadata.json
        let header = Header(
            kdf: keys.kdf,
            iterations: keys.iterations,
            salt: keys.salt ?? Data(count: saltLength),
            noncePrefix: noncePrefix,
            recordSize: UInt32(recordSize),
            metadataLength: UInt32(metadataPlain.count + tagLength)
        ).bytes
        let key = SymmetricKey(data: keys.key)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        try output.write(contentsOf: header)
        try output.write(contentsOf: seal(metadataPlain, key: key, header: header, index: 0, final: false))
        var written = Int64(header.count + metadataPlain.count + tagLength)

        let count = max(1, (metadata.size + Int64(recordSize) - 1) / Int64(recordSize))
        var read: Int64 = 0
        for index in 0..<count {
            try autoreleasepool {
                let expected = Int(min(Int64(recordSize), metadata.size - read))
                let chunk = try input.read(upToCount: expected) ?? Data()
                guard chunk.count == expected else { throw ShareEncryptionError.fileChanged }
                read += Int64(chunk.count)
                let sealed = try seal(chunk, key: key, header: header, index: UInt32(index + 1), final: index == count - 1)
                try output.write(contentsOf: sealed)
                written += Int64(sealed.count)
            }
        }
        // Nothing may follow what the metadata says.
        if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw ShareEncryptionError.fileChanged }
        return written
    }

    private static func seal(_ plaintext: Data, key: SymmetricKey, header: Data, index: UInt32, final: Bool) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce(header: header, index: index), authenticating: aad(header: header, final: final))
        return box.ciphertext + box.tag
    }

    private static func nonce(header: Data, index: UInt32) throws -> AES.GCM.Nonce {
        var bytes = Data(header[header.startIndex + 26..<header.startIndex + 34])
        bytes.append(bigEndian: index)
        return try AES.GCM.Nonce(data: bytes)
    }

    private static func aad(header: Data, final: Bool) -> Data {
        var aad = header
        aad.append(final ? 1 : 0)
        return aad
    }

    // MARK: - Decrypting

    /// Decrypts `source` into `destination`, record by record, the way the
    /// page does: a missing final record, records out of order or altered,
    /// and a size that doesn't match the metadata are all refused.
    /// `keyFor` gets the header (for a password's salt and iterations).
    @discardableResult
    static func decrypt(file source: URL, to destination: URL, keyFor: (Header) throws -> Data) throws -> Metadata {
        let total = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard let headerData = try input.read(upToCount: headerLength), headerData.count == headerLength else { throw Failure.damaged }
        let header = try Header(parsing: headerData)
        let key = SymmetricKey(data: try keyFor(header))

        guard let sealedMeta = try input.read(upToCount: Int(header.metadataLength)), sealedMeta.count == Int(header.metadataLength) else {
            throw Failure.damaged
        }
        let metaPlain: Data
        do {
            metaPlain = try open(sealedMeta, key: key, header: headerData, index: 0, final: false)
        } catch {
            throw Failure.wrongKey
        }
        guard let object = (try? JSONSerialization.jsonObject(with: metaPlain)) as? [String: Any],
              let name = object["name"] as? String, let type = object["type"] as? String,
              let size = (object["size"] as? NSNumber)?.int64Value else { throw Failure.damaged }
        let metadata = Metadata(name: name, type: type, size: size, syntax: object["syntax"] as? String)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var offset = Int64(headerLength) + Int64(header.metadataLength)
        let full = Int64(header.recordSize) + Int64(tagLength)
        var index: UInt32 = 1
        var plainSize: Int64 = 0
        while true {
            let remaining = total - offset
            let final = remaining <= full
            let length = final ? remaining : full
            guard length >= Int64(tagLength) else { throw Failure.damaged }
            try autoreleasepool {
                guard let sealed = try input.read(upToCount: Int(length)), sealed.count == Int(length) else { throw Failure.damaged }
                let plain: Data
                do {
                    plain = try open(sealed, key: key, header: headerData, index: index, final: final)
                } catch {
                    throw Failure.damaged
                }
                try output.write(contentsOf: plain)
                plainSize += Int64(plain.count)
            }
            offset += length
            index += 1
            if final { break }
        }
        guard plainSize == metadata.size else { throw Failure.damaged }
        return metadata
    }

    private static func open(_ sealed: Data, key: SymmetricKey, header: Data, index: UInt32, final: Bool) throws -> Data {
        let box = try AES.GCM.SealedBox(
            nonce: nonce(header: header, index: index),
            ciphertext: sealed.prefix(sealed.count - tagLength),
            tag: sealed.suffix(tagLength)
        )
        return try AES.GCM.open(box, using: key, authenticating: aad(header: header, final: final))
    }

    // MARK: - Keys

    /// PBKDF2-HMAC-SHA256 of the NFC UTF-8 password, 32 bytes.
    static func deriveKey(password: String, salt: Data, iterations: UInt32) -> Data {
        let password = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var key = [UInt8](repeating: 0, count: keyLength)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, password.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &key, key.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (\(status))")
        return Data(key)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ string: String) -> Data? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard string.allSatisfy(allowed.contains) else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

enum ShareEncryptionError: Error, LocalizedError {
    case fileChanged

    var errorDescription: String? {
        String(localized: "The file changed while it was being encrypted.")
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
