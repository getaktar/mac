import XCTest

/// Reading ShareX's UploadersConfig.json and .sxb backups
/// (docs/sharex-import.md).
final class ShareXConfigImportTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> ShareXConfigImport.Result {
        try ShareXConfigImport.parse(JSONSerialization.data(withJSONObject: object))
    }

    func testAmazonS3Uploader() throws {
        let result = try parse(["AmazonS3Settings": [
            "AccessKeyID": "AKIAEXAMPLE",
            "SecretAccessKey": "plain-secret",
            "Endpoint": "s3.eu-west-1.amazonaws.com",
            "Region": "",
            "UsePathStyle": false,
            "Bucket": "shots",
            "ObjectPrefix": "ShareX/%y/%mo",
            "UseCustomCNAME": false,
            "RemoveExtensionImage": true,
        ]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.kind, .s3)
        XCTAssertEqual(destination.name, String(localized: "ShareX: shots"))
        XCTAssertEqual(destination.preset, .amazonS3)
        XCTAssertEqual(destination.endpoint, "https://s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(destination.region, "eu-west-1")
        XCTAssertEqual(destination.publicBaseURL, "https://s3.eu-west-1.amazonaws.com/shots", "path style, as ShareX does")
        XCTAssertEqual(destination.objectPathTemplate, "ShareX/{year}/{month}/{filename}.{ext}")
        XCTAssertEqual(destination.accessKeyID, "AKIAEXAMPLE")
        XCTAssertEqual(destination.secretKey, "plain-secret")
        XCTAssertFalse(destination.secretIsEncrypted)
        XCTAssertEqual(destination.notes.count, 1, "removed extensions are mentioned")
        let config = destination.config()
        XCTAssertEqual(config.bucket, "shots")
        XCTAssertFalse(config.isDefault)
    }

    func testRegionsAsShareXReadsThem() {
        XCTAssertEqual(ShareXConfigImport.region(fromEndpointHost: "s3.amazonaws.com", preset: .amazonS3), "us-east-1")
        XCTAssertEqual(ShareXConfigImport.region(fromEndpointHost: "s3-ap-south-1.amazonaws.com", preset: .amazonS3), "ap-south-1")
        XCTAssertEqual(ShareXConfigImport.region(fromEndpointHost: "s3.us-west-004.backblazeb2.com", preset: .backblazeB2), "us-west-004")
        XCTAssertEqual(ShareXConfigImport.region(fromEndpointHost: "nyc3.digitaloceanspaces.com", preset: .digitalOceanSpaces), "nyc3")
        XCTAssertEqual(ShareXConfigImport.region(fromEndpointHost: "minio.example.com", preset: .customS3), "us-east-1")
    }

    func testR2EndpointCustomDomainAndEncryptedSecret() throws {
        let result = try parse(["AmazonS3Settings": [
            "AccessKeyID": "r2key",
            "SecretAccessKey": "$DPAPIEncrypted$AQAAANCMnd8BFdERjHoAwE/Cl+s=",
            "Endpoint": "https://0123456789abcdef.r2.cloudflarestorage.com/",
            "Bucket": "files",
            "UseCustomCNAME": true,
            "CustomDomain": "cdn.example.com/",
        ]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.preset, .cloudflareR2)
        XCTAssertEqual(destination.accountID, "0123456789abcdef")
        XCTAssertEqual(destination.region, "auto")
        XCTAssertEqual(destination.endpoint, "https://0123456789abcdef.r2.cloudflarestorage.com")
        XCTAssertEqual(destination.publicBaseURL, "https://cdn.example.com")
        XCTAssertEqual(destination.objectPathTemplate, "ShareX/{year}/{month}/{filename}.{ext}", "ShareX's default prefix when none is saved")
        XCTAssertNil(destination.secretKey, "DPAPI can't be read on a Mac")
        XCTAssertTrue(destination.secretIsEncrypted)
    }

    func testCustomDomainWithShareXSyntaxIsLeftEmpty() throws {
        let result = try parse(["AmazonS3Settings": [
            "AccessKeyID": "k", "Endpoint": "minio.example.com:9000", "Bucket": "b",
            "UseCustomCNAME": true, "CustomDomain": "$prompt$.example.com", "UsePathStyle": true,
        ]])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.publicBaseURL, "")
        XCTAssertTrue(destination.forcePathStyle)
        XCTAssertEqual(destination.preset, .customS3)
        XCTAssertFalse(destination.notes.isEmpty)
    }

    func testIncompleteS3UploaderIsNotImported() throws {
        let result = try parse(["AmazonS3Settings": ["AccessKeyID": "", "Endpoint": "s3.amazonaws.com", "Bucket": ""]])
        XCTAssertTrue(result.destinations.isEmpty)
    }

    func testBackblazeB2Uploader() throws {
        let result = try parse([
            "B2ApplicationKeyId": "0040000000000000000000001",
            "B2ApplicationKey": "$DPAPIEncrypted$AAAA",
            "B2BucketName": "my-bucket",
            "B2UploadPath": "ShareX/%y/",
            "B2UseCustomUrl": false,
        ])
        let destination = try XCTUnwrap(result.destinations.first)
        XCTAssertEqual(destination.kind, .b2)
        XCTAssertEqual(destination.name, String(localized: "ShareX: my-bucket (B2)"))
        XCTAssertEqual(destination.preset, .backblazeB2)
        XCTAssertEqual(destination.endpoint, "", "asked for with the key")
        XCTAssertEqual(destination.objectPathTemplate, "ShareX/{year}/{filename}.{ext}")
        XCTAssertTrue(destination.secretIsEncrypted)

        let response = #"{"accountId":"x","apiInfo":{"storageApi":{"s3ApiUrl":"https://s3.us-west-004.backblazeb2.com","downloadUrl":"https://f004.backblazeb2.com"}}}"#
        let account = try XCTUnwrap(ShareXConfigImport.b2Account(fromAuthorizeResponse: Data(response.utf8), bucket: "my-bucket"))
        XCTAssertEqual(account, .init(endpoint: "https://s3.us-west-004.backblazeb2.com", region: "us-west-004", downloadBaseURL: "https://f004.backblazeb2.com/file/my-bucket"))
        XCTAssertNil(ShareXConfigImport.b2Account(fromAuthorizeResponse: Data("{}".utf8), bucket: "b"))

        let custom = try parse(["B2ApplicationKeyId": "k", "B2BucketName": "b", "B2UseCustomUrl": true, "B2CustomUrl": "files.example.com", "B2ApplicationKey": "plain"])
        XCTAssertEqual(custom.destinations.first?.publicBaseURL, "https://files.example.com")
        XCTAssertEqual(custom.destinations.first?.secretKey, "plain")
    }

    func testPathTemplateMapping() {
        XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "").template, "{filename}.{ext}")
        XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "/").template, "{filename}.{ext}")
        XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "/img/%y-%mo-%d/").template, "img/{year}-{month}-{day}/{filename}.{ext}")
        XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "%guid").template, "{uuid}/{filename}.{ext}")
        for random in ["%ra{10}", "%ra", "%rna{4}", "%rx{8}", "%rn"] {
            XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "a/" + random).template, "a/{random}/{filename}.{ext}", random)
        }
        // %mon is a month name, not %mo followed by "n".
        let month = ShareXConfigImport.pathTemplate(fromPrefix: "ShareX/%y/%mon")
        XCTAssertEqual(month.template, DestinationConfig.defaultObjectPathTemplate)
        XCTAssertEqual(month.notes.count, 1)
        XCTAssertTrue(month.notes[0].contains("%mon"))
        for token in ["%h", "%mi", "%s", "%pn", "%t", "%i", "%un", "%cn", "%yy", "%w", "%unix", "%zz"] {
            let mapped = ShareXConfigImport.pathTemplate(fromPrefix: "x/" + token)
            XCTAssertEqual(mapped.template, DestinationConfig.defaultObjectPathTemplate, token)
            XCTAssertTrue(mapped.notes.first?.contains(token) == true, token)
        }
        XCTAssertEqual(ShareXConfigImport.pathTemplate(fromPrefix: "a b").template, DestinationConfig.defaultObjectPathTemplate, "a space isn't kept")
    }

    func testCustomUploadersAndOthers() throws {
        let shortener: [String: Any] = [
            "Name": "My Shlink", "DestinationType": "URLShortener", "RequestMethod": "POST",
            "RequestURL": "https://s.example.com/rest/v3/short-urls", "Headers": ["X-Api-Key": "secret123"],
            "Body": "JSON", "Data": #"{"longUrl":"{input}"}"#, "URL": "{json:shortUrl}",
        ]
        let uploader: [String: Any] = ["Name": "My Host", "DestinationType": "ImageUploader, FileUploader", "RequestURL": "https://up.example.com", "FileFormName": "file"]
        let result = try parse([
            "CustomUploadersList": [shortener, uploader],
            "FTPAccountList": [["Name": "ftp"]],
            "ImgurOAuth2Info": ["access_token": "x"],
            "GoogleDriveOAuth2Info": NSNull(),
        ])
        XCTAssertEqual(result.shorteners.count, 1)
        XCTAssertEqual(result.shorteners[0].name, "My Shlink")
        XCTAssertEqual(result.shorteners[0].imported.host, "s.example.com")
        XCTAssertEqual(result.shorteners[0].imported.token, "secret123")
        XCTAssertEqual(Set(result.skipped.map(\.name)), ["My Host", String(localized: "FTP account ftp"), "Imgur"], "an FTP account is listed by its name")
    }

    func testNotShareX() {
        XCTAssertThrowsError(try ShareXConfigImport.parse(Data("[]".utf8))) { XCTAssertEqual($0 as? ShareXConfigImport.Failure, .notShareX) }
        XCTAssertThrowsError(try ShareXConfigImport.parse(Data(#"{"foo":1}"#.utf8))) { XCTAssertEqual($0 as? ShareXConfigImport.Failure, .notShareX) }
        // A byte order mark, as Windows tools write it, is fine.
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data(#"{"AmazonS3Settings":{}}"#.utf8))
        XCTAssertNoThrow(try ShareXConfigImport.parse(bom))
    }

    func testBackupZip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShareXBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("History"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config: [String: Any] = ["AmazonS3Settings": ["AccessKeyID": "k", "SecretAccessKey": "s", "Endpoint": "s3.amazonaws.com", "Bucket": "zipped", "ObjectPrefix": String(repeating: "a", count: 2000)]]
        try JSONSerialization.data(withJSONObject: config).write(to: folder.appendingPathComponent("UploadersConfig.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("ApplicationConfig.json"))
        try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent("History/History.db"))

        for (name, flags) in [("deflated.sxb", ["-r", "-q"]), ("stored.sxb", ["-r", "-q", "-0"])] {
            let archive = folder.appendingPathComponent(name)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = folder
            zip.arguments = flags + [archive.path, "UploadersConfig.json", "ApplicationConfig.json", "History"]
            try zip.run()
            zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)
            let result = try ShareXConfigImport.read(fileAt: archive)
            XCTAssertEqual(result.destinations.first?.bucket, "zipped", name)
        }

        let withoutSettings = folder.appendingPathComponent("empty.sxb")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", withoutSettings.path, "ApplicationConfig.json"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertThrowsError(try ShareXConfigImport.read(fileAt: withoutSettings)) {
            XCTAssertEqual($0 as? ShareXConfigImport.Failure, .backupWithoutSettings)
        }

        let json = folder.appendingPathComponent("UploadersConfig.json")
        XCTAssertEqual(try ShareXConfigImport.read(fileAt: json).destinations.first?.bucket, "zipped", "the JSON itself")
    }
}
