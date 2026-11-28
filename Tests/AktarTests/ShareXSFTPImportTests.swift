import XCTest

/// ShareX's SFTP accounts and its ownCloud / Nextcloud uploader in the
/// ShareX import (docs/sharex-import.md, field names from ShareX's
/// FTPAccount.cs and UploadersConfig.cs).
final class ShareXSFTPImportTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> ShareXConfigImport.Result {
        try ShareXConfigImport.parse(JSONSerialization.data(withJSONObject: object))
    }

    func testSFTPAccountWithPassword() throws {
        let result = try parse(["FTPAccountList": [[
            "Name": "VPS",
            "Protocol": "SFTP",
            "Host": "files.example.com",
            "Port": 22,
            "Username": "deploy",
            "Password": "hunter2",
            "SubFolderPath": "shots/%y/%mo",
            "BrowserProtocol": "https",
            "HttpHomePath": "img.example.com",
            "HttpHomePathAutoAddSubFolderPath": true,
            "Keypath": "",
        ]]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.kind, .sftp)
        XCTAssertEqual(destination.preset, .sftp)
        XCTAssertEqual(destination.name, String(localized: "ShareX: VPS"))
        XCTAssertEqual(destination.endpoint, "files.example.com")
        XCTAssertEqual(destination.bucket, "shots", "the sub folder's fixed part is the Folder")
        XCTAssertEqual(destination.objectPathTemplate, "{year}/{month}/{filename}.{ext}")
        XCTAssertEqual(destination.publicBaseURL, "https://img.example.com/shots")
        XCTAssertEqual(destination.accessKeyID, "deploy")
        XCTAssertEqual(destination.secretKey, "hunter2")
        XCTAssertNil(destination.keyFile)
        XCTAssertTrue(result.skipped.isEmpty)

        let config = destination.config()
        XCTAssertEqual(config.kind, .sftp)
        XCTAssertEqual(config.bucket, "shots")
        XCTAssertEqual(config.region, "")
        XCTAssertNil(config.sshHostKey, "trusted on first use")
        // ShareX's link and Aktar's agree: home + sub folder + file name.
        XCTAssertEqual(PublicURLResolver.resolve(baseURL: config.publicBaseURL, objectKey: "2026/11/a.png")?.absoluteString, "https://img.example.com/shots/2026/11/a.png")
    }

    func testSFTPAccountWithKeyFileAndPort() throws {
        let result = try parse(["FTPAccountList": [[
            "Name": "New account",
            "Protocol": "SFTP",
            "Host": "storage.example.net",
            "Port": 23,
            "Username": "u123",
            "Password": "$DPAPIEncrypted$AQAAAA==",
            "SubFolderPath": "/home/u123/www",
            "BrowserProtocol": "http",
            "HttpHomePath": "",
            "HttpHomePathAutoAddSubFolderPath": false,
            "Keypath": "C:\\Users\\me\\.ssh\\id_ed25519",
            "Passphrase": "$DPAPIEncrypted$AQAAAA==",
        ]]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.name, String(localized: "ShareX: storage.example.net"), "the default name gives way to the host")
        XCTAssertEqual(destination.endpoint, "storage.example.net:23")
        XCTAssertEqual(destination.bucket, "/home/u123/www")
        XCTAssertEqual(destination.objectPathTemplate, "{filename}.{ext}")
        XCTAssertEqual(destination.publicBaseURL, "http://storage.example.net", "the host, as ShareX falls back to")
        XCTAssertEqual(destination.keyFile, "C:\\Users\\me\\.ssh\\id_ed25519")
        XCTAssertNil(destination.secretKey, "the key itself is chosen in the review")
        XCTAssertFalse(destination.secretIsEncrypted)
        XCTAssertNil(destination.keyPassphrase)
        XCTAssertTrue(destination.passphraseIsEncrypted)
        XCTAssertTrue(destination.notes.contains { $0.contains("id_ed25519") })
    }

    func testSFTPHomePathWithShareXSyntaxAndNumericProtocol() throws {
        let result = try parse(["FTPAccountList": [[
            "Name": "Old",
            "Protocol": 2,
            "Host": "ftp.example.org",
            "Port": 2222,
            "Username": "me",
            "Password": "pw",
            "SubFolderPath": "",
            "BrowserProtocol": 1,
            "HttpHomePath": "$prompt$.example.org",
        ]]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.endpoint, "ftp.example.org:2222")
        XCTAssertEqual(destination.bucket, "", "the login folder")
        XCTAssertEqual(destination.objectPathTemplate, "{filename}.{ext}")
        XCTAssertEqual(destination.publicBaseURL, "", "left for the review")
        XCTAssertFalse(destination.notes.isEmpty)

        // No home path: the host without "ftp.", as ShareX does.
        let plain = try parse(["FTPAccountList": [["Name": "x", "Protocol": "SFTP", "Host": "ftp.example.org", "BrowserProtocol": "https"]]])
        XCTAssertEqual(plain.destinations.first?.publicBaseURL, "https://example.org")
    }

    func testDatedFoldersLeftOutOfTheLink() throws {
        let result = try parse(["FTPAccountList": [[
            "Name": "x", "Protocol": "SFTP", "Host": "h.example.com", "Port": 22, "Username": "u", "Password": "p",
            "SubFolderPath": "up/%y", "HttpHomePath": "cdn.example.com/up", "HttpHomePathAutoAddSubFolderPath": false, "BrowserProtocol": "https",
        ]]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.bucket, "up")
        XCTAssertEqual(destination.objectPathTemplate, "{filename}.{ext}")
        XCTAssertEqual(destination.publicBaseURL, "https://cdn.example.com/up")
        XCTAssertFalse(destination.notes.isEmpty, "the dropped dated folders are mentioned")
    }

    func testFTPAndFTPSAreSkipped() throws {
        let result = try parse(["FTPAccountList": [
            ["Name": "Plain", "Protocol": "FTP", "Host": "ftp.example.com"],
            ["Name": "Secure", "Protocol": "FTPS", "Host": "ftps.example.com"],
            ["Name": "Numbered", "Protocol": 0, "Host": "x.example.com"],
        ]])
        XCTAssertTrue(result.destinations.isEmpty)
        XCTAssertEqual(result.skipped.map(\.name), ["Plain", "Secure", "Numbered"].map { String(localized: "FTP account \($0)") })
    }

    func testNextcloudBecomesWebDAV() throws {
        let result = try parse([
            "OwnCloudHost": "cloud.example.com/",
            "OwnCloudUsername": "me",
            "OwnCloudPassword": "app-password",
            "OwnCloudPath": "ShareX/",
        ])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.kind, .webdav)
        XCTAssertEqual(destination.preset, .webdav)
        XCTAssertEqual(destination.endpoint, "https://cloud.example.com/remote.php/webdav/ShareX")
        XCTAssertNil(WebDAVBackend.problem(withServerURL: destination.endpoint))
        XCTAssertEqual(destination.accessKeyID, "me")
        XCTAssertEqual(destination.secretKey, "app-password")
        XCTAssertEqual(destination.publicBaseURL, "", "ShareX's share links aren't a folder address")
        XCTAssertEqual(destination.notes.count, 1)
        XCTAssertEqual(destination.config().bucket, "")

        // The default settings (empty host) bring nothing.
        let empty = try parse(["OwnCloudHost": "", "OwnCloudUsername": "", "OwnCloudPath": "/", "AmazonS3Settings": [:]])
        XCTAssertTrue(empty.destinations.isEmpty)

        let encrypted = try parse(["OwnCloudHost": "http://nas.local", "OwnCloudUsername": "me", "OwnCloudPassword": "$DPAPIEncrypted$AQ=="])
        let nas = try XCTUnwrap(encrypted.destinations.first)
        XCTAssertNil(nas.secretKey)
        XCTAssertTrue(nas.secretIsEncrypted)
        XCTAssertEqual(nas.endpoint, "http://nas.local/remote.php/webdav")
        XCTAssertNotNil(WebDAVBackend.problem(withServerURL: nas.endpoint), "http:// isn't allowed off this Mac; the review says so")
    }
}
