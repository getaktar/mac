import XCTest

/// ShareX custom uploaders (.sxcu) in Tests/Fixtures/sxcu.
final class ShareXImportTests: XCTestCase {
    func testShortenerWithHeaderSecret() throws {
        let imported = try Self.parse("shlink")
        XCTAssertEqual(imported.name, "Shlink (s.example.com)")
        XCTAssertEqual(imported.host, "s.example.com")
        XCTAssertEqual(imported.method, "POST")
        XCTAssertEqual(imported.endpoint, "https://s.example.com/rest/v3/short-urls")
        XCTAssertEqual(imported.token, "c0ffee-1234-secret")
        XCTAssertEqual(imported.secretLocations, [.header("X-Api-Key")])
        XCTAssertFalse(imported.usesHTTP)
        XCTAssertFalse(imported.deletionSkipped)

        let create = imported.definition.create
        XCTAssertEqual(create.path, "https://s.example.com/rest/v3/short-urls")
        XCTAssertEqual(create.headers, ["X-Api-Key": "{token}"])
        XCTAssertEqual(create.bodyType, .json)
        XCTAssertEqual(create.body, .object(["longUrl": .string("{url}"), "findIfExists": .bool(true)]))
        XCTAssertEqual(create.shortUrlPath, "shortUrl")
        XCTAssertEqual(create.idPath, "shortCode")
        XCTAssertEqual(create.errorPath, "detail")
        // The deletion URL is opened, as ShareX does, without the headers.
        let delete = try XCTUnwrap(imported.definition.delete)
        XCTAssertEqual(delete.method, "GET")
        XCTAssertEqual(delete.path, "https://s.example.com/admin/delete/{id}")
        XCTAssertNil(delete.headers)
        XCTAssertTrue(imported.definition.capabilities.delete)

        // The secret is nowhere in the definition that gets saved.
        let saved = String(decoding: try JSONEncoder().encode(imported.definition), as: UTF8.self)
        XCTAssertFalse(saved.contains("c0ffee"))

        // And the request it makes puts the token back where it was.
        let settings = ShortLinkSettings(providerId: "custom", custom: imported.definition)
        let request = try ShortLinkRequestBuilder.build(create, definition: imported.definition, settings: settings, values: [.url: "https://f.example.com/a.png"], token: imported.token)
        XCTAssertEqual(request.url?.absoluteString, "https://s.example.com/rest/v3/short-urls")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "c0ffee-1234-secret")
    }

    func testLegacySyntaxAndQuerySecret() throws {
        let imported = try Self.parse("yourls-legacy")
        XCTAssertEqual(imported.method, "GET")
        XCTAssertEqual(imported.token, "5f3c2a1b9e")
        XCTAssertEqual(imported.secretLocations, [.query("signature")])
        let create = imported.definition.create
        XCTAssertNil(create.bodyType)
        XCTAssertEqual(create.query, ["signature": "{token}", "action": "shorturl", "format": "json", "url": "{url}"])
        XCTAssertEqual(create.shortUrlPath, "shorturl")
        XCTAssertEqual(imported.endpoint, "https://sho.rt/yourls-api.php?action=shorturl&format=json&signature={token}&url={url}")
        XCTAssertNil(imported.definition.delete)
    }

    func testBearerFormAndJSONPath() throws {
        let imported = try Self.parse("bearer-form")
        // The same secret in two places is one token.
        XCTAssertEqual(imported.token, "abc.def.ghi")
        XCTAssertEqual(Set(imported.secretLocations), [.header("Authorization"), .body("api_key")])
        let create = imported.definition.create
        XCTAssertEqual(create.headers, ["Authorization": "Bearer {token}", "Accept": "application/json"])
        XCTAssertEqual(create.query, ["client": "sharex"])
        XCTAssertEqual(create.bodyType, .form)
        XCTAssertEqual(create.body, .object(["link": .string("{url}"), "api_key": .string("{token}")]))
        XCTAssertEqual(create.shortUrlPath, "data.0.short_link")
        // A deletion URL that comes whole from the answer can't be stored.
        XCTAssertTrue(imported.deletionSkipped)
        XCTAssertNil(imported.definition.delete)
        XCTAssertFalse(imported.definition.capabilities.delete)
    }

    func testHTTPNeedsTheToggle() throws {
        XCTAssertThrowsError(try Self.parse("insecure")) {
            XCTAssertEqual($0 as? ShareXImportError, .insecure)
        }
        let imported = try Self.parse("insecure", allowInsecureHTTP: true)
        XCTAssertTrue(imported.usesHTTP)
        XCTAssertEqual(imported.host, "localhost")
        XCTAssertEqual(imported.token, "kutt-local-key")
        XCTAssertEqual(imported.definition.delete?.path, "http://localhost:8082/api/v2/links/{id}")
        XCTAssertEqual(imported.definition.create.idPath, "id")
    }

    func testUnsupportedFeaturesAreRefused() {
        XCTAssertThrowsError(try Self.parse("regex")) {
            guard case .unsupported = $0 as? ShareXImportError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Self.parse("response-transform")) {
            XCTAssertEqual($0 as? ShareXImportError, .unsupported("{response}"))
        }
        XCTAssertThrowsError(try Self.parse("prompt")) {
            XCTAssertEqual($0 as? ShareXImportError, .unsupported("{prompt:Slug}"))
        }
        XCTAssertThrowsError(try Self.parse("file-uploader")) {
            XCTAssertEqual($0 as? ShareXImportError, .notShortener)
        }
        XCTAssertThrowsError(try Self.parse("two-secrets")) {
            XCTAssertEqual($0 as? ShareXImportError, .multipleSecrets)
        }
        XCTAssertThrowsError(try ShareXImport.parse(Data("not json".utf8), allowInsecureHTTP: false)) {
            XCTAssertEqual($0 as? ShareXImportError, .invalid)
        }
        // The messages say what's wrong without any secret.
        XCTAssertEqual(
            ShareXImportError.unsupported("{select:a|b}").errorDescription,
            "Aktar can\u{2019}t import this configuration: it uses {select:a|b}."
        )
    }

    func testSyntaxHelpers() throws {
        XCTAssertEqual(try ShareXImport.map("u={input}&x=$input$"), "u={url}&x={url}")
        // Braces and dollars that aren't ShareX functions are just text.
        XCTAssertEqual(try ShareXImport.map("pa$word$x {abc}"), "pa$word$x {abc}")
        XCTAssertThrowsError(try ShareXImport.map("{filename}"))
        XCTAssertThrowsError(try ShareXImport.map("{random:a|b}"))
        XCTAssertEqual(try ShareXImport.responsePath("$json:data.link$"), "data.link")
        XCTAssertEqual(try ShareXImport.responsePath("{json:$.items[2].url}"), "items.2.url")
        XCTAssertNil(try ShareXImport.responsePath(nil))
        XCTAssertThrowsError(try ShareXImport.responsePath("https://x.example/{json:code}"))
        XCTAssertNil(ShareXImport.dotPath("a..b"))
        XCTAssertNil(ShareXImport.dotPath("items[*].url"))
        XCTAssertTrue(SecretExtractor.isSecretName("X-Api-Key"))
        XCTAssertTrue(SecretExtractor.isSecretName("access_token"))
        XCTAssertFalse(SecretExtractor.isSecretName("keyword"))
        XCTAssertFalse(SecretExtractor.isSecretName("format"))
    }

    /// Runs only with AKTAR_TEST_SHLINK_URL and AKTAR_TEST_SHLINK_KEY set
    /// (TEST_RUNNER_ prefixed for xcodebuild): a ShareX configuration for
    /// Shlink, imported and used against the real thing.
    func testRealShlinkFromShareX() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["AKTAR_TEST_SHLINK_URL"], let key = environment["AKTAR_TEST_SHLINK_KEY"] else {
            throw XCTSkip("AKTAR_TEST_SHLINK_URL and AKTAR_TEST_SHLINK_KEY aren't set")
        }
        let sxcu: [String: Any] = [
            "Version": "16.1.0",
            "DestinationType": "URLShortener",
            "RequestMethod": "POST",
            "RequestURL": endpoint + "/rest/v3/short-urls",
            "Headers": ["X-Api-Key": key],
            "Body": "JSON",
            "Data": #"{"longUrl":"{input}","findIfExists":false}"#,
            "URL": "{json:shortUrl}",
            "ErrorMessage": "{json:detail}",
        ]
        let imported = try ShareXImport.parse(JSONSerialization.data(withJSONObject: sxcu), allowInsecureHTTP: endpoint.hasPrefix("http://"))
        XCTAssertEqual(imported.token, key)
        let settings = ShortLinkSettings(providerId: "custom", custom: imported.definition, allowInsecureHTTP: imported.usesHTTP)
        let engine = ShortLinkEngine(definition: imported.definition, settings: settings, token: imported.token)
        let created = try await engine.create(url: "https://getaktar.com/?aktar-sxcu=\(UUID().uuidString)", expiresAt: nil)
        XCTAssertTrue(created.shortUrl.hasPrefix("http"))

        // Cleaned up with the built-in definition.
        let shlink = ShortLinkEngine(
            definition: try XCTUnwrap(ShortLinkProviders.definition(id: "shlink")),
            settings: ShortLinkSettings(providerId: "shlink", endpoint: endpoint, allowInsecureHTTP: true),
            token: key
        )
        try await shlink.delete(ShortLinkTarget(providerId: String(created.shortUrl.split(separator: "/").last ?? "")))

        // A wrong token: Shlink's own message, and not the token.
        let wrong = ShortLinkEngine(definition: imported.definition, settings: settings, token: "wrong-token-123")
        do {
            _ = try await wrong.create(url: "https://getaktar.com/", expiresAt: nil)
            XCTFail("Expected an error")
        } catch {
            guard case .rejected(401, let message) = error as? ShortLinkError else { return XCTFail("\(error)") }
            XCTAssertFalse(message?.contains("wrong-token-123") ?? false)
        }
    }

    // MARK: - Helpers

    private static func parse(_ name: String, allowInsecureHTTP: Bool = false) throws -> ShareXImport {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sxcu/\(name).sxcu")
        return try ShareXImport.parse(try Data(contentsOf: url), allowInsecureHTTP: allowInsecureHTTP)
    }
}
