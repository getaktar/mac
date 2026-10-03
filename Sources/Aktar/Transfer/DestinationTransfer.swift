import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Why a transfer link couldn't be opened.
enum DestinationTransferError: Error, Equatable, LocalizedError {
    /// Not a link (or a broken one), or its contents aren't a destination.
    case notAktarTransfer
    /// Made by an app that writes a newer format.
    case newerVersion
    /// The transfer code didn't decrypt it, or isn't a valid code at all.
    case wrongCode

    var errorDescription: String? {
        switch self {
        case .notAktarTransfer: return String(localized: "This isn\u{2019}t an Aktar transfer link.")
        case .newerVersion: return String(localized: "This was shared from a newer version of Aktar. Update Aktar and try again.")
        case .wrongCode: return String(localized: "That code doesn\u{2019}t match. Check it and try again.")
        }
    }
}

/// Moves one destination, keys included, to another Aktar (Mac, Windows,
/// iOS, Android) as a QR code or a copied link, encrypted with a short
/// transfer code that's typed on the other device and never part of the
/// link. The format is shared with the other apps; see
/// docs/destination-transfer.md.
///
///     link  = "aktar://import#" + base64url([0x01][salt 16][nonce 12][ciphertext + tag 16])
///     key   = PBKDF2-HMAC-SHA256(code, salt, 20000 iterations, 32 bytes)
///     AES-256-GCM, additional data "aktar-transfer-v1"
///
/// Deriving the key takes a moment on purpose, so `seal` and `open` belong
/// off the main thread.
enum DestinationTransfer {
    /// What a link carries. `customTemplate` is the app-level template,
    /// sent along when the destination copies with it.
    struct Payload {
        var destination: DestinationConfig
        var credentials: StorageCredentials
        var customTemplate: String?
    }

    static let formatVersion: UInt8 = 1
    static let linkPrefix = "aktar://import#"
    /// Crockford base32, which leaves out I, L, O and U.
    static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let codeLength = 12
    static let iterations: UInt32 = 20_000

    private static let saltLength = 16
    private static let nonceLength = 12
    private static let tagLength = 16
    private static let headerLength = 1 + saltLength + nonceLength
    private static let additionalData = Data("aktar-transfer-v1".utf8)
    private static let defaultObjectPath = "{year}/{month}/{uuid}.{ext}"

    // MARK: - Transfer code

    /// A new random code, 12 characters (60 bits). 32 divides 256, so
    /// masking a random byte picks every character equally often.
    static func generateCode() -> String {
        String(randomBytes(codeLength).map { codeAlphabet[Int($0 & 31)] })
    }

    /// "K7P2QX9M4TRW" as "K7P2-QX9M-4TRW".
    static func displayCode(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        return stride(from: 0, to: codeLength, by: 4)
            .map { offset in String(code.dropFirst(offset).prefix(4)) }
            .joined(separator: "-")
    }

    /// The code field as it's typed: letters and digits only, uppercased,
    /// at most 12 of them, with a hyphen after every four ("K7P2-QX9").
    /// Look-alike letters stay as typed; `normalizeCode` maps them.
    static func formatCodeInput(_ input: String) -> String {
        grouped(codeCharacters(input))
    }

    /// An edit to the code field, as what the field shows afterwards and
    /// where the caret goes. `proposed` and `caret` are the field's text and
    /// caret right after the edit (UTF-16 offsets), `original` and
    /// `originalCaret` right before it. The caret stays after the same code
    /// character it was after, and deleting a hyphen deletes the character
    /// next to it, which the hyphen would otherwise just come back for.
    static func editCodeInput(proposed: String, caret: Int, original: String, originalCaret: Int) -> (text: String, caret: Int) {
        let proposedUTF16 = Array(proposed.utf16)
        let caret = min(max(caret, 0), proposedUTF16.count)
        var characters = codeCharacters(proposed)
        var before = codeCharacters(String(decoding: proposedUTF16[..<caret], as: UTF16.self)).count
        if proposedUTF16.count < original.utf16.count, characters == codeCharacters(original) {
            if caret < originalCaret, before > 0 {
                // Delete backward over a hyphen.
                characters.remove(at: before - 1)
                before -= 1
            } else if caret == originalCaret, before < characters.count {
                // Delete forward over a hyphen.
                characters.remove(at: before)
            }
        }
        characters = Array(characters.prefix(codeLength))
        before = min(before, characters.count)
        return (grouped(characters), before == 0 ? 0 : before + (before - 1) / 4)
    }

    private static func codeCharacters(_ input: String) -> [Character] {
        input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { $0 }
    }

    private static func grouped(_ characters: [Character]) -> String {
        let code = characters.prefix(codeLength)
        return stride(from: 0, to: code.count, by: 4)
            .map { offset in String(code.dropFirst(offset).prefix(4)) }
            .joined(separator: "-")
    }

    /// What was typed, as the 12 characters the key is derived from, or nil
    /// if it can't be a code. Case, spaces and hyphens don't matter, and the
    /// letters people mistake for digits count as those digits.
    static func normalizeCode(_ input: String) -> String? {
        var code = ""
        for character in input.uppercased() {
            switch character {
            case " ", "-": continue
            case "O": code.append("0")
            case "I", "L": code.append("1")
            default: code.append(character)
            }
        }
        guard code.count == codeLength, code.allSatisfy(codeAlphabet.contains) else { return nil }
        return code
    }

    // MARK: - Sealing and opening

    /// The link for `payload`, encrypted with `code` (from `generateCode`).
    /// A fresh salt and nonce every time.
    static func seal(_ payload: Payload, code: String) throws -> String {
        try seal(plaintext: encodePayload(payload), code: code, salt: randomBytes(saltLength), nonce: randomBytes(nonceLength))
    }

    static func seal(plaintext: Data, code: String, salt: Data, nonce: Data) throws -> String {
        let key = deriveKey(code: code, salt: salt)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: additionalData)
        var envelope = Data([formatVersion])
        envelope.append(salt)
        envelope.append(nonce)
        envelope.append(box.ciphertext)
        envelope.append(box.tag)
        return linkPrefix + base64URLEncoded(envelope)
    }

    /// The destination in a scanned or pasted link (or just its base64url
    /// part), decrypted with what the user typed as the code.
    static func open(_ input: String, code: String) throws -> Payload {
        let envelope = try envelope(from: input)
        guard let code = normalizeCode(code) else { throw DestinationTransferError.wrongCode }
        let salt = envelope.subdata(in: 1..<(1 + saltLength))
        let nonce = envelope.subdata(in: (1 + saltLength)..<headerLength)
        let sealed = envelope.subdata(in: headerLength..<envelope.count)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: sealed.prefix(sealed.count - tagLength),
                tag: sealed.suffix(tagLength)
            )
            plaintext = try AES.GCM.open(box, using: deriveKey(code: code, salt: salt), authenticating: additionalData)
        } catch {
            throw DestinationTransferError.wrongCode
        }
        return try decodePayload(plaintext)
    }

    /// The encrypted bytes of a link, checked before any code is asked for,
    /// so a link that can't work is turned away right after it's pasted.
    @discardableResult
    static func envelope(from input: String) throws -> Data {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var encoded = trimmed
        if let hash = trimmed.firstIndex(of: "#") {
            guard trimmed[..<hash].lowercased() == "aktar://import" else { throw DestinationTransferError.notAktarTransfer }
            encoded = String(trimmed[trimmed.index(after: hash)...])
        } else if trimmed.contains(":") {
            throw DestinationTransferError.notAktarTransfer
        }
        guard let data = base64URLDecoded(encoded), data.count >= headerLength + tagLength else {
            throw DestinationTransferError.notAktarTransfer
        }
        switch data[data.startIndex] {
        case formatVersion: return data
        case let version where version > formatVersion: throw DestinationTransferError.newerVersion
        default: throw DestinationTransferError.notAktarTransfer
        }
    }

    /// Whether `string` looks like a transfer link, for filling the field in
    /// from the clipboard.
    static func looksLikeLink(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(linkPrefix)
    }

    // MARK: - Duplicates

    /// Whether an imported destination still uploads where `existing` does:
    /// the same endpoint (ignoring case, a trailing slash and a missing
    /// https://) and bucket. Updating one that doesn't is worth a warning.
    static func uploadsToSamePlace(_ imported: DestinationConfig, as existing: DestinationConfig) -> Bool {
        comparableEndpoint(imported.endpoint) == comparableEndpoint(existing.endpoint)
            && imported.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            == existing.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparableEndpoint(_ endpoint: String) -> String {
        var endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if endpoint.hasPrefix("https://") { endpoint.removeFirst("https://".count) }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        return endpoint
    }

    // MARK: - Payload

    static func encodePayload(_ payload: Payload) throws -> Data {
        let config = payload.destination
        var destination: [String: Any] = [
            "id": config.id.uuidString,
            "name": config.name,
            "preset": config.preset.rawValue,
            "endpoint": config.endpoint,
            "region": config.region,
            "bucket": config.bucket,
            "publicBaseURL": config.publicBaseURL,
            "objectPathTemplate": config.objectPathTemplate,
            "forcePathStyle": config.forcePathStyle,
        ]
        if let accountID = config.accountID, !accountID.isEmpty { destination["accountID"] = accountID }
        if let outputMode = config.outputMode { destination["outputMode"] = outputMode.rawValue }
        if let expiryDays = config.expiryDays { destination["expiryDays"] = expiryDays }
        if let temporaryLink = config.temporaryLink { destination["temporaryLink"] = temporaryLink.rawValue }
        if let imageMetadata = config.imageMetadata { destination["imageMetadata"] = imageMetadata.rawValue }
        if let folderUpload = config.folderUpload { destination["folderUpload"] = folderUpload.rawValue }
        if let processing = config.imageProcessing {
            var object: [String: Any] = ["format": processing.format.rawValue]
            if let quality = processing.quality { object["quality"] = quality }
            if let maxLongEdge = processing.maxLongEdge { object["maxLongEdge"] = maxLongEdge }
            destination["imageProcessing"] = object
        }

        var credentials: [String: Any] = [
            "accessKeyId": payload.credentials.accessKeyId,
            "secretAccessKey": payload.credentials.secretAccessKey,
        ]
        if let sessionToken = payload.credentials.sessionToken, !sessionToken.isEmpty {
            credentials["sessionToken"] = sessionToken
        }

        var root: [String: Any] = ["v": Int(formatVersion), "destination": destination, "credentials": credentials]
        if config.outputMode == .custom, let template = payload.customTemplate {
            root["customTemplate"] = template
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    /// Lenient: unknown fields are ignored, and an optional field with a
    /// value this app doesn't know is left unset rather than failing the
    /// whole import. Only what a destination can't work without is required.
    static func decodePayload(_ data: Data) throws -> Payload {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DestinationTransferError.notAktarTransfer
        }
        if let version = int(root["v"]), version > Int(formatVersion) { throw DestinationTransferError.newerVersion }
        guard let object = root["destination"] as? [String: Any],
              let keys = root["credentials"] as? [String: Any],
              let id = string(object["id"]).flatMap(UUID.init(uuidString:)),
              let name = string(object["name"]),
              let preset = string(object["preset"]).flatMap(ProviderPreset.init(rawValue:)),
              let endpoint = string(object["endpoint"]),
              let bucket = string(object["bucket"]),
              let publicBaseURL = string(object["publicBaseURL"]),
              let accessKeyId = string(keys["accessKeyId"]),
              let secretAccessKey = string(keys["secretAccessKey"]) else {
            throw DestinationTransferError.notAktarTransfer
        }

        let destination = DestinationConfig(
            id: id,
            name: name,
            preset: preset,
            accountID: string(object["accountID"]),
            endpoint: endpoint,
            region: string(object["region"]) ?? preset.defaultRegion,
            bucket: bucket,
            publicBaseURL: publicBaseURL,
            objectPathTemplate: string(object["objectPathTemplate"]) ?? defaultObjectPath,
            forcePathStyle: bool(object["forcePathStyle"]) ?? preset.defaultForcePathStyle,
            isDefault: false,
            outputMode: string(object["outputMode"]).flatMap(OutputMode.init(rawValue:)),
            expiryDays: int(object["expiryDays"]).flatMap { UploadExpiry.isValid($0) ? $0 : nil },
            temporaryLink: int(object["temporaryLink"]).flatMap { TemporaryLinkDuration(rawValue: Int64($0)) },
            imageMetadata: string(object["imageMetadata"]).flatMap(ImageMetadataPolicy.init(rawValue:)),
            folderUpload: string(object["folderUpload"]).flatMap(FolderUploadMode.init(rawValue:)),
            imageProcessing: imageProcessing(object["imageProcessing"])
        )
        let credentials = StorageCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: string(keys["sessionToken"])
        )
        return Payload(destination: destination, credentials: credentials, customTemplate: string(root["customTemplate"]))
    }

    /// An unknown format drops the whole setting; a quality or size the
    /// pickers don't offer is turned off on its own.
    private static func imageProcessing(_ value: Any?) -> ImageProcessing? {
        guard let object = value as? [String: Any],
              let format = string(object["format"]).flatMap(ImageProcessing.Format.init(rawValue:)) else { return nil }
        let processing = ImageProcessing(
            format: format,
            quality: int(object["quality"]).flatMap { ImageProcessing.qualityOptions.contains($0) ? $0 : nil },
            maxLongEdge: int(object["maxLongEdge"]).flatMap { ImageProcessing.sizeOptions.contains($0) ? $0 : nil }
        )
        return processing.isOff ? nil : processing
    }

    // MARK: - JSON values

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// JSON true and false come back as NSNumbers too, so they're told
    /// apart from numbers by type.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    // MARK: - Primitives

    private static func deriveKey(code: String, salt: Data) -> SymmetricKey {
        let password = Array(code.utf8).map { CChar(bitPattern: $0) }
        var key = [UInt8](repeating: 0, count: 32)
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
        return SymmetricKey(data: key)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Also a CSPRNG on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ string: String) -> Data? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !string.isEmpty, string.allSatisfy(allowed.contains) else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
