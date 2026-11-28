import Compression
import Foundation

/// "Import from ShareX" (docs/sharex-import.md): ShareX's
/// `UploadersConfig.json`, or a `.sxb` backup that has it, read into
/// destinations (its Amazon S3 and Backblaze B2 uploaders, SFTP accounts and
/// the ownCloud / Nextcloud uploader as WebDAV), URL shorteners
/// (custom uploaders, through the `.sxcu` import) and the things that
/// can't come along. Nothing is saved here; the review does that.
enum ShareXConfigImport {
    /// Bigger isn't a ShareX settings file.
    static let maxConfigBytes = 5 * 1024 * 1024
    /// A backup holds history and screenshots too; only its settings are read.
    static let maxBackupBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let dpapiPrefix = "$DPAPIEncrypted$"
    static let defaultObjectPrefix = "ShareX/%y/%mo"

    struct Destination: Identifiable, Equatable {
        enum Kind: Equatable { case s3, b2, sftp, webdav }

        let id = UUID()
        var kind: Kind
        var name: String
        var preset: ProviderPreset
        var accountID: String?
        /// Empty for a B2 uploader until `b2_authorize_account` tells it.
        var endpoint: String
        var region: String
        var bucket: String
        /// Empty when it couldn't be worked out (ShareX syntax in a custom
        /// domain, or a B2 key not typed yet).
        var publicBaseURL: String
        var objectPathTemplate: String
        var forcePathStyle: Bool
        var accessKeyID: String
        /// Nil when the file doesn't have it in plain text.
        var secretKey: String?
        /// The secret is there, encrypted with Windows' DPAPI.
        var secretIsEncrypted: Bool
        /// What the review says about it (template parts dropped, ...).
        var notes: [String]
        /// SFTP: the account signs in with a key file, which is on the
        /// Windows PC (`Keypath`); the review asks for the key itself.
        var keyFile: String? = nil
        /// SFTP: the key's passphrase, when the file has it in plain text.
        var keyPassphrase: String? = nil
        /// SFTP: the passphrase is there, encrypted for Windows.
        var passphraseIsEncrypted = false

        static func == (lhs: Destination, rhs: Destination) -> Bool {
            lhs.kind == rhs.kind && lhs.name == rhs.name && lhs.endpoint == rhs.endpoint && lhs.bucket == rhs.bucket
                && lhs.publicBaseURL == rhs.publicBaseURL && lhs.objectPathTemplate == rhs.objectPathTemplate
                && lhs.accessKeyID == rhs.accessKeyID && lhs.secretKey == rhs.secretKey && lhs.region == rhs.region
                && lhs.keyFile == rhs.keyFile && lhs.keyPassphrase == rhs.keyPassphrase
        }

        /// As a destination, once the endpoint and base URL are known.
        func config() -> DestinationConfig {
            DestinationConfig(
                name: name,
                preset: preset,
                accountID: accountID,
                endpoint: endpoint,
                region: region,
                bucket: bucket,
                publicBaseURL: publicBaseURL,
                objectPathTemplate: objectPathTemplate,
                forcePathStyle: forcePathStyle,
                isDefault: false
            )
        }
    }

    struct Shortener: Identifiable {
        let id = UUID()
        let name: String
        let imported: ShareXImport
    }

    struct Skipped: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let reason: String

        static func == (lhs: Skipped, rhs: Skipped) -> Bool { lhs.name == rhs.name && lhs.reason == rhs.reason }
    }

    struct Result {
        var destinations: [Destination] = []
        var shorteners: [Shortener] = []
        var skipped: [Skipped] = []
    }

    enum Failure: LocalizedError, Equatable {
        case tooLarge
        case notShareX
        case backupWithoutSettings

        var errorDescription: String? {
            switch self {
            case .tooLarge: return String(localized: "This file is too large to be ShareX\u{2019}s settings.")
            case .notShareX: return String(localized: "This isn\u{2019}t ShareX\u{2019}s UploadersConfig.json or a ShareX backup (.sxb).")
            case .backupWithoutSettings: return String(localized: "This ShareX backup doesn\u{2019}t have UploadersConfig.json in it.")
            }
        }
    }

    // MARK: - Reading

    /// Reads a picked file: a `.sxb` backup (a ZIP) or the JSON itself.
    static func read(fileAt url: URL) throws -> Result {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard Int64(size) <= maxBackupBytes else { throw Failure.tooLarge }
            guard let json = try ZipReader.file(named: "UploadersConfig.json", in: data, maxBytes: maxConfigBytes) else {
                throw Failure.backupWithoutSettings
            }
            return try parse(json)
        }
        guard data.count <= maxConfigBytes else { throw Failure.tooLarge }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Result {
        guard data.count <= maxConfigBytes,
              let root = (try? JSONSerialization.jsonObject(with: stripBOM(data))) as? [String: Any] else { throw Failure.notShareX }
        // Something only ShareX's uploader settings have.
        let known = ["AmazonS3Settings", "B2ApplicationKeyId", "CustomUploadersList", "FTPAccountList", "ImgurAccountType", "OwnCloudHost"]
        guard known.contains(where: { root[$0] != nil }) else { throw Failure.notShareX }

        var result = Result()
        if let s3 = root["AmazonS3Settings"] as? [String: Any], let destination = amazonS3(s3) {
            result.destinations.append(destination)
        }
        if let destination = backblazeB2(root) {
            result.destinations.append(destination)
        }
        let ftp = ftpAccounts(root["FTPAccountList"] as? [Any] ?? [])
        result.destinations += ftp.destinations
        result.skipped += ftp.skipped
        if let destination = ownCloud(root) {
            result.destinations.append(destination)
        }
        for item in root["CustomUploadersList"] as? [Any] ?? [] {
            guard let object = item as? [String: Any] else { continue }
            let name = (object["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Custom uploader")
            let types = (object["DestinationType"] as? String ?? "").lowercased()
            guard types.contains("urlshortener") else {
                result.skipped.append(Skipped(name: name, reason: String(localized: "Custom file uploaders aren\u{2019}t supported.")))
                continue
            }
            do {
                let json = try JSONSerialization.data(withJSONObject: object)
                // http:// is refused here like in the .sxcu import; the
                // review says why.
                let imported = try ShareXImport.parse(json, allowInsecureHTTP: false)
                result.shorteners.append(Shortener(name: name, imported: imported))
            } catch {
                result.skipped.append(Skipped(name: name, reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        result.skipped += otherUploaders(root)
        return result
    }

    private static func stripBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    // MARK: - Amazon S3

    static func amazonS3(_ settings: [String: Any]) -> Destination? {
        let accessKey = string(settings["AccessKeyID"])
        let rawEndpoint = string(settings["Endpoint"])
        let bucket = string(settings["Bucket"])
        guard !accessKey.isEmpty, !rawEndpoint.isEmpty, !bucket.isEmpty else { return nil }
        var notes: [String] = []
        let endpoint = rawEndpoint.contains("://") ? rawEndpoint : "https://" + rawEndpoint
        let host = URLComponents(string: endpoint)?.host?.lowercased() ?? ""
        let preset = preset(forHost: host)
        let region = string(settings["Region"]).isEmpty ? region(fromEndpointHost: host, preset: preset) : string(settings["Region"])
        let pathStyle = settings["UsePathStyle"] as? Bool ?? false

        var publicBaseURL = trimmedSlashes(endpoint) + "/" + bucket
        if settings["UseCustomCNAME"] as? Bool == true {
            let domain = string(settings["CustomDomain"])
            if domain.contains("$") || domain.contains("{") {
                publicBaseURL = ""
                notes.append(String(localized: "The custom domain uses ShareX syntax, so enter the public base URL yourself."))
            } else if !domain.isEmpty {
                publicBaseURL = trimmedSlashes(domain.contains("://") ? domain : "https://" + domain)
            }
        }
        let template = pathTemplate(fromPrefix: settings["ObjectPrefix"] as? String ?? defaultObjectPrefix)
        notes += template.notes
        if ["RemoveExtensionImage", "RemoveExtensionVideo", "RemoveExtensionText"].contains(where: { settings[$0] as? Bool == true }) {
            notes.append(String(localized: "ShareX removed some file extensions; Aktar keeps them."))
        }
        let (secret, encrypted) = secret(settings["SecretAccessKey"])
        return Destination(
            kind: .s3,
            name: String(localized: "ShareX: \(bucket)"),
            preset: preset,
            accountID: preset == .cloudflareR2 ? host.split(separator: ".").first.map(String.init) : nil,
            endpoint: trimmedSlashes(endpoint),
            region: region,
            bucket: bucket,
            publicBaseURL: publicBaseURL,
            objectPathTemplate: template.template,
            forcePathStyle: pathStyle,
            accessKeyID: accessKey,
            secretKey: secret,
            secretIsEncrypted: encrypted,
            notes: notes
        )
    }

    static func preset(forHost host: String) -> ProviderPreset {
        if host.hasSuffix(".r2.cloudflarestorage.com") { return .cloudflareR2 }
        if host.hasSuffix(".backblazeb2.com") { return .backblazeB2 }
        if host.hasSuffix(".digitaloceanspaces.com") { return .digitalOceanSpaces }
        if host == "amazonaws.com" || host.hasSuffix(".amazonaws.com") { return .amazonS3 }
        return .customS3
    }

    /// As ShareX's `GetRegion` (`s3.<region>.amazonaws.com`, `s3-<region>`,
    /// otherwise us-east-1); `auto` for R2, and the region in a B2 or
    /// Spaces host, whose signatures need it.
    static func region(fromEndpointHost host: String, preset: ProviderPreset) -> String {
        switch preset {
        case .cloudflareR2:
            return "auto"
        case .backblazeB2:
            // s3.us-west-004.backblazeb2.com
            let labels = host.split(separator: ".")
            return labels.count >= 3 && labels[0] == "s3" ? String(labels[1]) : "us-east-1"
        case .digitalOceanSpaces:
            // nyc3.digitaloceanspaces.com
            let labels = host.split(separator: ".")
            return labels.count >= 3 ? String(labels[labels.count - 3]) : "us-east-1"
        default:
            guard let aws = host.range(of: ".amazonaws.com") else { return "us-east-1" }
            var service = String(host[..<aws.lowerBound])
            if service.hasPrefix("s3-") { service = "s3." + service.dropFirst(3) }
            guard let dot = service.lastIndex(of: ".") else { return "us-east-1" }
            return String(service[service.index(after: dot)...])
        }
    }

    // MARK: - Backblaze B2

    static func backblazeB2(_ root: [String: Any]) -> Destination? {
        let keyID = string(root["B2ApplicationKeyId"])
        let bucket = string(root["B2BucketName"])
        guard !keyID.isEmpty, !bucket.isEmpty else { return nil }
        let template = pathTemplate(fromPrefix: root["B2UploadPath"] as? String ?? defaultObjectPrefix)
        var publicBaseURL = ""
        if root["B2UseCustomUrl"] as? Bool == true {
            let custom = string(root["B2CustomUrl"])
            if custom.contains("$") || custom.contains("{") {
                // Left for the review.
            } else if !custom.isEmpty {
                publicBaseURL = trimmedSlashes(custom.contains("://") ? custom : "https://" + custom)
            }
        }
        let (secret, encrypted) = secret(root["B2ApplicationKey"])
        return Destination(
            kind: .b2,
            name: String(localized: "ShareX: \(bucket) (B2)"),
            preset: .backblazeB2,
            accountID: nil,
            endpoint: "",
            region: "us-east-1",
            bucket: bucket,
            publicBaseURL: publicBaseURL,
            objectPathTemplate: template.template,
            forcePathStyle: false,
            accessKeyID: keyID,
            secretKey: secret,
            secretIsEncrypted: encrypted,
            notes: template.notes
        )
    }

    /// What `b2_authorize_account` says about a key: the S3 endpoint (and
    /// its region), and the friendly download URL of the bucket.
    struct B2Account: Equatable {
        let endpoint: String
        let region: String
        let downloadBaseURL: String
    }

    static func b2Account(fromAuthorizeResponse data: Data, bucket: String) -> B2Account? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let storage = (root["apiInfo"] as? [String: Any])?["storageApi"] as? [String: Any],
              let s3 = storage["s3ApiUrl"] as? String, let download = storage["downloadUrl"] as? String,
              let host = URLComponents(string: s3)?.host?.lowercased() else { return nil }
        let labels = host.split(separator: ".")
        let region = labels.count >= 3 && labels[0] == "s3" ? String(labels[1]) : "us-east-1"
        return B2Account(endpoint: trimmedSlashes(s3), region: region, downloadBaseURL: trimmedSlashes(download) + "/file/" + bucket)
    }

    /// Fills in a B2 destination's endpoint (and public base URL, unless it
    /// has its own) once its key is known.
    static func authorizeB2(_ destination: Destination, session: URLSession = .shared) async throws -> Destination {
        guard let key = destination.secretKey, !key.isEmpty else { return destination }
        var request = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        request.timeoutInterval = 20
        let basic = Data("\(destination.accessKeyID):\(key)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let account = b2Account(fromAuthorizeResponse: data, bucket: destination.bucket) else {
            throw StorageError.invalidCredentials
        }
        var authorized = destination
        authorized.endpoint = account.endpoint
        authorized.region = account.region
        if authorized.publicBaseURL.isEmpty { authorized.publicBaseURL = account.downloadBaseURL }
        return authorized
    }

    // MARK: - SFTP accounts

    /// ShareX's FTP accounts (`FTPAccountList`, ShareX.UploadersLib
    /// FTPAccount.cs): those with `Protocol` SFTP become SFTP destinations;
    /// plain FTP and FTPS are listed as skipped.
    static func ftpAccounts(_ accounts: [Any]) -> (destinations: [Destination], skipped: [Skipped]) {
        var destinations: [Destination] = []
        var skipped: [Skipped] = []
        for item in accounts {
            guard let account = item as? [String: Any] else { continue }
            let host = string(account["Host"])
            let accountName = string(account["Name"])
            let label = accountName.isEmpty || accountName == "New account" ? (host.isEmpty ? "FTP" : host) : accountName
            guard ftpProtocol(account["Protocol"]) == "sftp" else {
                skipped.append(Skipped(name: String(localized: "FTP account \(label)"), reason: String(localized: "Plain FTP and FTPS aren\u{2019}t supported. Use SFTP.")))
                continue
            }
            guard !host.isEmpty else { continue }
            if let destination = sftp(account, host: host, label: label) {
                destinations.append(destination)
            }
        }
        return (destinations, skipped)
    }

    /// "SFTP", 2 (the enum's number in older files) or "FTP"/"FTPS".
    private static func ftpProtocol(_ value: Any?) -> String {
        if let text = value as? String { return text.lowercased() }
        if let number = value as? Int { return [0: "ftp", 1: "ftps", 2: "sftp"][number] ?? "" }
        return "ftp"
    }

    /// An SFTP account. ShareX's link is `HttpHomePath` + (the sub folder,
    /// when `HttpHomePathAutoAddSubFolderPath`) + the file name; its file
    /// goes to `SubFolderPath` + the file name, relative to the login
    /// folder unless it starts with `/`. Aktar's Folder is the sub folder's
    /// fixed part, the path template its dated part, and the Public Base
    /// URL the home path with the fixed part.
    static func sftp(_ account: [String: Any], host: String, label: String) -> Destination? {
        var notes: [String] = []
        // FTPAccount's default port is 21, even for SFTP; kept as it is.
        let port = (account["Port"] as? Int) ?? 21
        let endpoint = port == 22 ? host : (host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")

        var subFolder = string(account["SubFolderPath"]).replacingOccurrences(of: "%host", with: host).replacingOccurrences(of: "\\", with: "/")
        while subFolder.count > 1, subFolder.hasSuffix("/") { subFolder.removeLast() }
        let parts = subFolder.split(separator: "/", omittingEmptySubsequences: true)
        let fixedParts = parts.prefix { !$0.contains("%") }
        let datedParts = parts.dropFirst(fixedParts.count)
        let fixed = (subFolder.hasPrefix("/") ? "/" : "") + fixedParts.joined(separator: "/")
        let autoAddSubFolder = account["HttpHomePathAutoAddSubFolderPath"] as? Bool ?? true

        let folder = fixed
        let template: (template: String, notes: [String])
        if autoAddSubFolder {
            template = pathTemplate(fromPrefix: datedParts.joined(separator: "/"))
        } else {
            // The link leaves the sub folder out, so files go straight into it.
            template = ("{filename}.{ext}", [])
            if !datedParts.isEmpty {
                notes.append(String(localized: "ShareX\u{2019}s folder \(subFolder) changes with each upload. Aktar uploads into \(fixed.isEmpty ? "." : fixed)."))
            }
        }
        notes += template.notes

        // The web address: the home path, or the host as ShareX falls back
        // to, with the scheme ShareX was set to.
        var publicBaseURL = ""
        let home = string(account["HttpHomePath"]).replacingOccurrences(of: "%host", with: host)
        let scheme = (account["BrowserProtocol"] as? String)?.lowercased() ?? ((account["BrowserProtocol"] as? Int) == 1 ? "https" : "http")
        if home.contains("$") || home.contains("{") || home.contains("%") || home.contains("?") {
            notes.append(String(localized: "The HTTP home path uses ShareX syntax, so enter the public base URL yourself."))
        } else if !["http", "https"].contains(scheme) {
            notes.append(String(localized: "ShareX linked to these files with \(scheme)://. Enter the web address they\u{2019}re served from as the Public Base URL."))
        } else {
            var base = home.isEmpty ? (host.hasPrefix("ftp.") ? String(host.dropFirst(4)) : host) : home
            if !base.contains("://") { base = "\(scheme)://" + base }
            base = trimmedSlashes(base)
            if autoAddSubFolder, !fixedParts.isEmpty {
                base += "/" + fixedParts.joined(separator: "/")
            }
            publicBaseURL = PublicURLResolver.isValidBaseURL(base) ? base : ""
        }
        if account["HttpHomePathNoExtension"] as? Bool == true {
            notes.append(String(localized: "ShareX removed some file extensions; Aktar keeps them."))
        }

        let keyPath = string(account["Keypath"])
        let (password, passwordEncrypted) = secret(account["Password"])
        let (passphrase, passphraseEncrypted) = secret(account["Passphrase"])
        let usesKey = !keyPath.isEmpty
        if usesKey {
            notes.append(String(localized: "ShareX signed in with the key file \(keyPath). Choose that key on this Mac."))
        }
        return Destination(
            kind: .sftp,
            name: String(localized: "ShareX: \(label)"),
            preset: .sftp,
            accountID: nil,
            endpoint: endpoint,
            region: "",
            bucket: folder,
            publicBaseURL: publicBaseURL,
            objectPathTemplate: template.template,
            forcePathStyle: false,
            accessKeyID: string(account["Username"]),
            secretKey: usesKey ? nil : password,
            secretIsEncrypted: !usesKey && passwordEncrypted,
            notes: notes,
            keyFile: usesKey ? keyPath : nil,
            keyPassphrase: usesKey ? passphrase : nil,
            passphraseIsEncrypted: usesKey && passphraseEncrypted
        )
    }

    // MARK: - ownCloud / Nextcloud

    /// ShareX's ownCloud / Nextcloud uploader (`OwnCloudHost`,
    /// `OwnCloudUsername`, `OwnCloudPassword`, `OwnCloudPath`): files go to
    /// `<host>/remote.php/webdav<path>` over WebDAV, as ShareX's OwnCloud.cs
    /// sends them. ShareX's links were Nextcloud shares, which Aktar doesn't
    /// make, so the review asks for a web address that serves the folder.
    static func ownCloud(_ root: [String: Any]) -> Destination? {
        let rawHost = string(root["OwnCloudHost"])
        let user = string(root["OwnCloudUsername"])
        guard !rawHost.isEmpty, !user.isEmpty else { return nil }
        let host = trimmedSlashes(rawHost.contains("://") ? rawHost : "https://" + rawHost)
        var path = string(root["OwnCloudPath"])
        if path.isEmpty { path = "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        let endpoint = trimmedSlashes(host + "/remote.php/webdav" + path)
        let (password, encrypted) = secret(root["OwnCloudPassword"])
        let hostName = URLComponents(string: host)?.host ?? host
        return Destination(
            kind: .webdav,
            name: String(localized: "ShareX: \(hostName) (Nextcloud)"),
            preset: .webdav,
            accountID: nil,
            endpoint: endpoint,
            region: "",
            bucket: "",
            publicBaseURL: "",
            objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: false,
            accessKeyID: user,
            secretKey: password,
            secretIsEncrypted: encrypted,
            notes: [String(localized: "ShareX made a share link for each file. Aktar links to files at the Public Base URL: enter the web address this folder is served from.")]
        )
    }

    // MARK: - Path template

    /// ShareX's ObjectPrefix as an Aktar template: the prefix converted,
    /// then `/{filename}.{ext}`. Anything Aktar has no variable for makes it
    /// Aktar's default template instead, and the note says what was dropped.
    static func pathTemplate(fromPrefix raw: String) -> (template: String, notes: [String]) {
        var prefix = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard !prefix.isEmpty else { return ("{filename}.{ext}", []) }
        let (converted, unrepresentable) = convert(prefix)
        if !unrepresentable.isEmpty {
            let list = ListFormatter.localizedString(byJoining: unrepresentable)
            return (DestinationConfig.defaultObjectPathTemplate, [String(localized: "Aktar has no match for \(list) in ShareX\u{2019}s path, so it uses its own: \(DestinationConfig.defaultObjectPathTemplate)")])
        }
        return (converted + "/{filename}.{ext}", [])
    }

    /// ShareX's name tokens, longest first so `%mon` isn't read as `%mo`.
    private static let tokens: [(String, String?)] = [
        ("%guid", "{uuid}"), ("%unix", nil), ("%width", nil), ("%height", nil), ("%mon2", nil), ("%mon", nil),
        ("%rna", "{random}"), ("%uln", nil), ("%ra", "{random}"), ("%rn", "{random}"), ("%rx", "{random}"),
        ("%yy", nil), ("%mo", "{month}"), ("%mi", nil), ("%ms", nil), ("%pm", nil), ("%pn", nil), ("%un", nil),
        ("%cn", nil), ("%ib", nil), ("%y", "{year}"), ("%d", "{day}"), ("%h", nil), ("%s", nil), ("%w", nil),
        ("%t", nil), ("%i", nil), ("%n", nil),
    ]

    private static func convert(_ prefix: String) -> (String, [String]) {
        var output = ""
        var unrepresentable: [String] = []
        var rest = Substring(prefix)
        while let character = rest.first {
            if character == "%" {
                if let (token, replacement) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                    rest = rest.dropFirst(token.count)
                    var written = token
                    // %ra{10}: a length, or a set of characters.
                    if rest.first == "{", let close = rest.firstIndex(of: "}") {
                        written += rest[...close]
                        rest = rest[rest.index(after: close)...]
                    }
                    if let replacement {
                        output += replacement
                    } else if !unrepresentable.contains(written) {
                        unrepresentable.append(written)
                    }
                } else {
                    let name = "%" + rest.dropFirst().prefix { $0.isLetter || $0.isNumber }
                    rest = rest.dropFirst(name.count)
                    if !unrepresentable.contains(name) { unrepresentable.append(name) }
                }
                continue
            }
            if character.isASCII, character.isLetter || character.isNumber || "-_./".contains(character) {
                output.append(character)
            } else if !unrepresentable.contains(String(character)) {
                unrepresentable.append(String(character))
            }
            rest = rest.dropFirst()
        }
        return (output, unrepresentable)
    }

    // MARK: - Others

    /// Uploaders set up in ShareX that Aktar doesn't bring along.
    private static func otherUploaders(_ root: [String: Any]) -> [Skipped] {
        var skipped: [Skipped] = []
        let notSupported = String(localized: "Not an S3-compatible uploader.")
        let services: [(String, String)] = [
            ("ImgurOAuth2Info", "Imgur"), ("GoogleDriveOAuth2Info", "Google Drive"), ("DropboxOAuth2Info", "Dropbox"),
            ("OneDriveV2OAuth2Info", "OneDrive"), ("BoxOAuth2Info", "Box"), ("GoogleCloudStorageOAuth2Info", "Google Cloud Storage"),
            ("AzureStorageAccountName", "Azure Storage"), ("FlickrOAuthInfo", "Flickr"), ("PhotobucketOAuthInfo", "Photobucket"),
        ]
        for (key, name) in services {
            guard let value = root[key], !(value is NSNull) else { continue }
            if let text = value as? String, text.isEmpty { continue }
            skipped.append(Skipped(name: name, reason: notSupported))
        }
        return skipped
    }

    /// A secret as the file has it: in plain text, or encrypted for
    /// Windows (`$DPAPIEncrypted$...`), which only Windows can read.
    static func secret(_ value: Any?) -> (String?, encrypted: Bool) {
        let text = string(value)
        if text.hasPrefix(dpapiPrefix) { return (nil, true) }
        return (text.isEmpty ? nil : text, false)
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func trimmedSlashes(_ value: String) -> String {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// Reads one file out of a ZIP archive in memory: stored or deflated
/// entries, found through the central directory.
enum ZipReader {
    enum Failure: Error { case damaged, unsupported, tooLarge }

    /// The file at the archive's root called `name` (case-insensitive), or
    /// nil when there's none.
    static func file(named name: String, in data: Data, maxBytes: Int) throws -> Data? {
        // Read in place: a backup can be big, and it's mapped, not loaded.
        let bytes = data
        guard let end = endOfCentralDirectory(bytes) else { throw Failure.damaged }
        let count = Int(le16(bytes, end + 10))
        var offset = Int(le32(bytes, end + 16))
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, le32(bytes, offset) == 0x02014B50 else { throw Failure.damaged }
            let method = le16(bytes, offset + 10)
            let compressedSize = Int(le32(bytes, offset + 20))
            let size = Int(le32(bytes, offset + 24))
            let nameLength = Int(le16(bytes, offset + 28))
            let extraLength = Int(le16(bytes, offset + 30))
            let commentLength = Int(le16(bytes, offset + 32))
            let localOffset = Int(le32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw Failure.damaged }
            let entryName = String(decoding: bytes.subdata(in: bytes.startIndex + offset + 46..<bytes.startIndex + offset + 46 + nameLength), as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            guard entryName.lowercased() == name.lowercased() else { continue }
            guard size <= maxBytes else { throw Failure.tooLarge }
            guard localOffset + 30 <= bytes.count, le32(bytes, localOffset) == 0x04034B50 else { throw Failure.damaged }
            let start = localOffset + 30 + Int(le16(bytes, localOffset + 26)) + Int(le16(bytes, localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw Failure.damaged }
            let compressed = [UInt8](bytes.subdata(in: bytes.startIndex + start..<bytes.startIndex + start + compressedSize))
            switch method {
            case 0:
                return Data(compressed)
            case 8:
                return try inflate(compressed, size: size)
            default:
                throw Failure.unsupported
            }
        }
        return nil
    }

    private static func inflate(_ compressed: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: size)
        let written = compressed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, size, source.baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.damaged }
        return Data(output)
    }

    private static func endOfCentralDirectory(_ bytes: Data) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if le32(bytes, index) == 0x06054B50 { return index }
            index -= 1
        }
        return nil
    }

    private static func le16(_ bytes: Data, _ offset: Int) -> UInt16 {
        let at = bytes.startIndex + offset
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: Data, _ offset: Int) -> UInt32 {
        let at = bytes.startIndex + offset
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
