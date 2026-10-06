import SwiftData
import XCTest

final class ShortLinkTests: XCTestCase {
    // MARK: - Definitions

    func testBundledDefinitionsAreTheDocsFile() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/short-link-providers.json")
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "short-link-providers", withExtension: "json"))
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: docs))
        XCTAssertEqual(ShortLinkProviders.builtIn.map(\.id), ["shlink", "yourls", "kutt", "dub", "shortio"])
    }

    func testCapabilitiesDecode() throws {
        let shlink = try Self.definition("shlink")
        XCTAssertEqual(shlink.capabilities.expiration, .absolute)
        XCTAssertTrue(shlink.capabilities.updateDestination)
        XCTAssertEqual(try Self.definition("kutt").capabilities.expiration, .relative)
        let yourls = try Self.definition("yourls")
        XCTAssertEqual(yourls.capabilities.expiration, .none)
        XCTAssertFalse(yourls.capabilities.delete)
        XCTAssertNil(yourls.delete)
        XCTAssertEqual(yourls.create.successStatuses, [409])
        XCTAssertTrue(try Self.definition("shortio").needsDomain)
        XCTAssertTrue(try Self.definition("dub").isHosted)
    }

    func testSettingsRoundTripAndDefaults() throws {
        var settings = ShortLinkSettings(providerId: "custom", endpoint: "https://s.example.com", custom: ShortLinkProviders.customTemplate, onlyLongerThan: 40, shortenTemporaryLinks: true)
        settings.allowInsecureHTTP = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ShortLinkSettings.self, from: data), settings)
        let minimal = try JSONDecoder().decode(ShortLinkSettings.self, from: Data(#"{"providerId":"shlink"}"#.utf8))
        XCTAssertEqual(minimal.onlyLongerThan, 0)
        XCTAssertFalse(minimal.shortenTemporaryLinks)
        XCTAssertFalse(minimal.allowInsecureHTTP)
        XCTAssertEqual(minimal.definition?.name, "Shlink")
    }

    // MARK: - Requests

    func testShlinkRequests() throws {
        let shlink = try Self.definition("shlink")
        let settings = ShortLinkSettings(providerId: "shlink", endpoint: "s.example.com/")
        let create = try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: settings, values: [.url: "https://files.example.com/a/b.png"], token: "key")
        XCTAssertEqual(create.url?.absoluteString, "https://s.example.com/rest/v3/short-urls")
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.value(forHTTPHeaderField: "X-Api-Key"), "key")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // No expiry and no domain: those keys aren't sent at all.
        XCTAssertEqual(try Self.json(create), ["longUrl": "https://files.example.com/a/b.png", "findIfExists": false] as NSDictionary)

        let expiry = Date(timeIntervalSince1970: 1_791_892_800)
        var values = ShortLinkPlaceholder.expiryValues(expiry, now: expiry.addingTimeInterval(-7 * 86_400))
        values[.url] = "https://files.example.com/a/b.png"
        let expiring = try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "https://s.example.com", domain: "go.example.com"), values: values, token: "key")
        let body = try Self.json(expiring)
        XCTAssertEqual(body["validUntil"] as? String, "2026-10-13T12:00:00+00:00")
        XCTAssertEqual(body["domain"] as? String, "go.example.com")

        // Shlink reads "?domain=" as the domain "", so it's left out.
        let delete = try ShortLinkRequestBuilder.build(shlink.delete!, definition: shlink, settings: settings, values: [.id: "12C18"], token: "key")
        XCTAssertEqual(delete.url?.absoluteString, "https://s.example.com/rest/v3/short-urls/12C18")
        XCTAssertEqual(delete.httpMethod, "DELETE")
        XCTAssertNil(delete.httpBody)
        let withDomain = try ShortLinkRequestBuilder.build(shlink.delete!, definition: shlink, settings: settings, values: [.id: "12C18", .domain: "go.example.com"], token: "key")
        XCTAssertEqual(withDomain.url?.absoluteString, "https://s.example.com/rest/v3/short-urls/12C18?domain=go.example.com")

        let stats = try ShortLinkRequestBuilder.build(shlink.stats!, definition: shlink, settings: settings, values: [.id: "12C18"], token: "key")
        XCTAssertEqual(stats.url?.absoluteString, "https://s.example.com/rest/v3/short-urls/12C18/visits?itemsPerPage=1")
        let update = try ShortLinkRequestBuilder.build(shlink.update!, definition: shlink, settings: settings, values: [.id: "12C18", .url: "https://files.example.com/new.png"], token: "key")
        XCTAssertEqual(update.httpMethod, "PATCH")
        XCTAssertEqual(try Self.json(update), ["longUrl": "https://files.example.com/new.png"] as NSDictionary)
    }

    func testYourlsRequests() throws {
        let yourls = try Self.definition("yourls")
        let settings = ShortLinkSettings(providerId: "yourls", endpoint: "https://sho.rt")
        let create = try ShortLinkRequestBuilder.build(yourls.create, definition: yourls, settings: settings, values: [.url: "https://files.example.com/a b+c.png?x=1&y=2"], token: "sig")
        XCTAssertEqual(create.url?.absoluteString, "https://sho.rt/yourls-api.php?action=shorturl&format=json&signature=sig")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        // A + or & in the link survives the form body.
        XCTAssertEqual(String(decoding: create.httpBody ?? Data(), as: UTF8.self), "url=https%3A%2F%2Ffiles.example.com%2Fa%20b%2Bc.png%3Fx%3D1%26y%3D2")
        let stats = try ShortLinkRequestBuilder.build(yourls.stats!, definition: yourls, settings: settings, values: [.id: "3x"], token: "sig")
        XCTAssertEqual(stats.url?.absoluteString, "https://sho.rt/yourls-api.php?action=url-stats&format=json&shorturl=3x&signature=sig")
    }

    func testKuttRequests() throws {
        let kutt = try Self.definition("kutt")
        let settings = ShortLinkSettings(providerId: "kutt", endpoint: "https://kutt.example.com")
        let plain = try ShortLinkRequestBuilder.build(kutt.create, definition: kutt, settings: settings, values: [.url: "https://f.example.com/x.png"], token: "k")
        XCTAssertEqual(plain.value(forHTTPHeaderField: "X-API-KEY"), "k")
        // " minutes" alone would fail validation, so expire_in is left out.
        XCTAssertEqual(try Self.json(plain), ["target": "https://f.example.com/x.png", "reuse": false] as NSDictionary)

        let now = Date()
        var values = ShortLinkPlaceholder.expiryValues(now.addingTimeInterval(7 * 86_400), now: now)
        values[.url] = "https://f.example.com/x.png"
        let expiring = try ShortLinkRequestBuilder.build(kutt.create, definition: kutt, settings: settings, values: values, token: "k")
        XCTAssertEqual(try Self.json(expiring)["expire_in"] as? String, "10080 minutes")
        let stats = try ShortLinkRequestBuilder.build(kutt.stats!, definition: kutt, settings: settings, values: [.id: "6a7b"], token: "k")
        XCTAssertEqual(stats.url?.absoluteString, "https://kutt.example.com/api/v2/links/6a7b/stats")
    }

    func testDubAndShortIORequests() throws {
        let dub = try Self.definition("dub")
        // Hosted: the endpoint is ignored.
        let dubSettings = ShortLinkSettings(providerId: "dub", endpoint: "https://ignored.example.com")
        let create = try ShortLinkRequestBuilder.build(dub.create, definition: dub, settings: dubSettings, values: [.url: "https://f.example.com/x.png"], token: "dub_x")
        XCTAssertEqual(create.url?.absoluteString, "https://api.dub.co/links")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Authorization"), "Bearer dub_x")
        XCTAssertEqual(try Self.json(create), ["url": "https://f.example.com/x.png"] as NSDictionary)
        let stats = try ShortLinkRequestBuilder.build(dub.stats!, definition: dub, settings: dubSettings, values: [.id: "link_1"], token: "dub_x")
        XCTAssertEqual(stats.url?.absoluteString, "https://api.dub.co/links/info?linkId=link_1")

        let shortio = try Self.definition("shortio")
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shortio.create, definition: shortio, settings: ShortLinkSettings(providerId: "shortio"), values: [.url: "https://f.example.com"], token: "sk")) {
            XCTAssertEqual($0 as? ShortLinkError, .missingDomain)
        }
        let settings = ShortLinkSettings(providerId: "shortio", domain: "short.gy")
        let shortCreate = try ShortLinkRequestBuilder.build(shortio.create, definition: shortio, settings: settings, values: [.url: "https://f.example.com/x.png"], token: "sk")
        XCTAssertEqual(shortCreate.value(forHTTPHeaderField: "Authorization"), "sk")
        XCTAssertEqual(try Self.json(shortCreate), ["domain": "short.gy", "originalURL": "https://f.example.com/x.png", "allowDuplicates": true] as NSDictionary)
        let shortStats = try ShortLinkRequestBuilder.build(shortio.stats!, definition: shortio, settings: settings, values: [.id: "lnk_1"], token: "sk")
        XCTAssertEqual(shortStats.url?.absoluteString, "https://statistics.short.io/statistics/link/lnk_1?period=total")
    }

    func testEndpointAndTokenChecks() throws {
        let shlink = try Self.definition("shlink")
        let values: [ShortLinkPlaceholder: String] = [.url: "https://f.example.com"]
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "http://localhost:8081"), values: values, token: "k")) {
            XCTAssertEqual($0 as? ShortLinkError, .insecureEndpoint)
        }
        XCTAssertNoThrow(try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "http://localhost:8081", allowInsecureHTTP: true), values: values, token: "k"))
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink"), values: values, token: "k")) {
            XCTAssertEqual($0 as? ShortLinkError, .missingEndpoint)
        }
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "ftp://x"), values: values, token: "k")) {
            XCTAssertEqual($0 as? ShortLinkError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shlink.create, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "https://s.example.com"), values: values, token: " ")) {
            XCTAssertEqual($0 as? ShortLinkError, .missingToken)
        }
        // A path needs its value.
        XCTAssertThrowsError(try ShortLinkRequestBuilder.build(shlink.delete!, definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "https://s.example.com"), values: [:], token: "k")) {
            XCTAssertEqual($0 as? ShortLinkError, .missingValue("id"))
        }
    }

    func testCustomDefinitionRequest() throws {
        var custom = ShortLinkProviders.customTemplate
        custom.create.path = "https://api.example.com/v1/shorten?key={token}&long={url}"
        custom.create.headers = ["Authorization": "Bearer {token}", "X-Optional": "{domain}"]
        let settings = ShortLinkSettings(providerId: "custom", custom: custom)
        let request = try ShortLinkRequestBuilder.build(custom.create, definition: custom, settings: settings, values: [.url: "https://f.example.com/a.png"], token: "t0k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/shorten?key=t0k&long=https%3A%2F%2Ff.example.com%2Fa.png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Optional"))
        XCTAssertEqual(try Self.json(request), ["url": "https://f.example.com/a.png"] as NSDictionary)
    }

    func testExpiryValues() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let values = ShortLinkPlaceholder.expiryValues(now.addingTimeInterval(299.9), now: now)
        XCTAssertEqual(values[.expiresInSeconds], "299")
        // Rounded down, so the short link never outlives its target.
        XCTAssertEqual(values[.expiresInMinutes], "4")
        XCTAssertEqual(values[.expiresAtUnix], "1000299")
        XCTAssertTrue(ShortLinkPlaceholder.expiryValues(now.addingTimeInterval(59), now: now).isEmpty)
        XCTAssertTrue(ShortLinkPlaceholder.expiryValues(nil, now: now).isEmpty)
    }

    // MARK: - Responses

    func testResponseExtraction() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"""
        {"visits":{"data":[{"date":"2026-10-06T12:30:00+00:00"},{"date":"2026-10-05T08:00:00+00:00"}],"pagination":{"totalItems":12}},
         "link":{"clicks":"7"},"error":{"message":"Nope"},"ms":1791892800000,"empty":null}
        """#.utf8))
        XCTAssertEqual(ShortLinkResponse.int(at: "visits.pagination.totalItems", in: json), 12)
        XCTAssertEqual(ShortLinkResponse.date(at: "visits.data.0.date", in: json), Date(timeIntervalSince1970: 1_791_289_800))
        XCTAssertEqual(ShortLinkResponse.int(at: "link.clicks", in: json), 7)
        XCTAssertEqual(ShortLinkResponse.string(at: "error.message", in: json), "Nope")
        XCTAssertEqual(ShortLinkResponse.date(at: "ms", in: json), Date(timeIntervalSince1970: 1_791_892_800))
        XCTAssertNil(ShortLinkResponse.value(at: "visits.data.5.date", in: json))
        XCTAssertNil(ShortLinkResponse.value(at: "empty", in: json))
        XCTAssertNil(ShortLinkResponse.value(at: "", in: json))
        XCTAssertEqual(ShortLinkResponse.parseDate("2026-10-06T12:00:00.000Z"), Date(timeIntervalSince1970: 1_791_288_000))
        XCTAssertEqual(ShortLinkResponse.parseDate("2026-10-06 12:00:00"), Date(timeIntervalSince1970: 1_791_288_000))
    }

    func testEngineCreateAndErrors() async throws {
        let transport = FakeTransport()
        let shlink = try Self.definition("shlink")
        let engine = ShortLinkEngine(definition: shlink, settings: ShortLinkSettings(providerId: "shlink", endpoint: "https://s.example.com"), token: "secret-key", transport: transport)

        transport.respond(200, #"{"shortCode":"12C18","shortUrl":"https://s.example.com/12C18"}"#)
        let created = try await engine.create(url: "https://f.example.com/a.png", expiresAt: nil)
        XCTAssertEqual(created, CreatedShortLink(shortUrl: "https://s.example.com/12C18", providerId: "12C18"))

        transport.respond(422, #"{"type":"invalid-short-url-deletion","detail":"Cannot delete, threshold secret-key reached"}"#)
        do {
            try await engine.delete(ShortLinkTarget(providerId: "12C18"))
            XCTFail("Expected an error")
        } catch let error as ShortLinkError {
            guard case .rejected(422, let message) = error else { return XCTFail("\(error)") }
            // The token never shows up in a message.
            XCTAssertEqual(message, "Cannot delete, threshold \u{2022}\u{2022}\u{2022} reached")
        }

        transport.respond(200, #"{"nothing":"here"}"#)
        do {
            _ = try await engine.create(url: "https://f.example.com/a.png", expiresAt: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ShortLinkError, .noShortLink(path: "shortUrl"))
        }

        transport.fail(URLError(.timedOut))
        do {
            _ = try await engine.create(url: "https://f.example.com/a.png", expiresAt: nil)
            XCTFail("Expected an error")
        } catch {
            guard case .network = error as? ShortLinkError else { return XCTFail("\(error)") }
        }
    }

    func testYourlsExistingURLCountsAsSuccess() async throws {
        let transport = FakeTransport()
        let engine = ShortLinkEngine(definition: try Self.definition("yourls"), settings: ShortLinkSettings(providerId: "yourls", endpoint: "https://sho.rt"), token: "sig", transport: transport)
        transport.respond(409, #"{"status":"fail","code":"error:url","message":"https://f.example.com/a.png already exists in database","shorturl":"https://sho.rt/3x","url":{"keyword":"3x"},"statusCode":"409"}"#)
        let created = try await engine.create(url: "https://f.example.com/a.png", expiresAt: Date().addingTimeInterval(86_400))
        XCTAssertEqual(created, CreatedShortLink(shortUrl: "https://sho.rt/3x", providerId: "3x"))
        // YOURLS can't expire links, so nothing about expiry is sent.
        XCTAssertFalse(String(decoding: transport.requests.last?.httpBody ?? Data(), as: UTF8.self).contains("expire"))

        transport.respond(403, #"{"message":"Please log in","errorCode":"403"}"#)
        do {
            _ = try await engine.create(url: "https://f.example.com/a.png", expiresAt: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ShortLinkError, .rejected(status: 403, message: "Please log in"))
        }
    }

    func testSuccessPathFailsA200() async throws {
        let shortio = try Self.definition("shortio")
        XCTAssertEqual(shortio.delete?.successPath, "success")
        XCTAssertEqual(shortio.delete?.successValue, .bool(true))
        let transport = FakeTransport()
        let engine = ShortLinkEngine(definition: shortio, settings: ShortLinkSettings(providerId: "shortio", domain: "short.gy"), token: "sk", transport: transport)
        transport.respond(200, #"{"success":false,"error":"Link not found"}"#)
        do {
            try await engine.delete(ShortLinkTarget(providerId: "lnk_1"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ShortLinkError, .rejected(status: 200, message: "Link not found"))
        }
        // Lifecycle: the cleanup failed, so the link may still exist.
        let link = Self.snapshot(provider: "shortio")
        let statuses = await ShortLinkLifecycle.deleteAll([link], operations: engine)
        XCTAssertEqual(statuses[link.id], .orphaned)
        transport.respond(200, #"{"success":true,"idString":"lnk_1"}"#)
        try await engine.delete(ShortLinkTarget(providerId: "lnk_1"))
        // A 200 without the field fails too.
        transport.respond(200, "")
        await XCTAssertThrowsErrorAsync(try await engine.delete(ShortLinkTarget(providerId: "lnk_1")))

        XCTAssertTrue(JSONValue.bool(true).matches(NSNumber(value: true)))
        XCTAssertFalse(JSONValue.bool(true).matches(NSNumber(value: 1)))
        XCTAssertTrue(JSONValue.string("ok").matches("ok"))
        XCTAssertTrue(JSONValue.number(1).matches(NSNumber(value: 1)))
    }

    func testCustomTestDeletesItsLink() async throws {
        var custom = ShortLinkProviders.customTemplate
        custom.create.path = "https://api.example.com/shorten"
        custom.create.idPath = "id"
        custom.delete = ShortLinkRequest(method: "DELETE", path: "/links/{id}", headers: ["Authorization": "Bearer {token}"])
        custom.capabilities = ShortLinkProviders.customCapabilities(canDelete: true)
        let transport = FakeTransport()
        let engine = ShortLinkEngine(definition: custom, settings: ShortLinkSettings(providerId: "custom", endpoint: "https://api.example.com", custom: custom), token: "t0k", transport: transport)
        transport.respond(200, #"{"shortUrl":"https://s.example.com/x1","id":"x1"}"#)
        let result = try await engine.test()
        XCTAssertEqual(result.created?.shortUrl, "https://s.example.com/x1")
        XCTAssertEqual(result.cleanup, .deleted)
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.last?.url?.absoluteString, "https://api.example.com/links/x1")

        // Without a delete request nothing more is sent.
        let plain = ShortLinkEngine(definition: ShortLinkProviders.customTemplate, settings: ShortLinkSettings(providerId: "custom", endpoint: "https://api.example.com"), token: "t0k", transport: transport)
        transport.respond(200, #"{"shortUrl":"https://s.example.com/x2"}"#)
        let count = transport.requests.count
        let plainResult = try await plain.test()
        XCTAssertEqual(plainResult.cleanup, .none)
        XCTAssertEqual(transport.requests.count, count + 1)
    }

    func testEngineStats() async throws {
        let transport = FakeTransport()
        let engine = ShortLinkEngine(definition: try Self.definition("yourls"), settings: ShortLinkSettings(providerId: "yourls", endpoint: "https://sho.rt"), token: "sig", transport: transport)
        transport.respond(200, #"{"statusCode":200,"link":{"shorturl":"https://sho.rt/3x","clicks":"12"}}"#)
        let stats = try await engine.stats(ShortLinkTarget(providerId: "3x"))
        XCTAssertEqual(stats, ShortLinkStats(clicks: 12, lastClickAt: nil))
    }

    // MARK: - Rules

    func testDecideRules() throws {
        let shlink = try Self.definition("shlink").capabilities
        let yourls = try Self.definition("yourls").capabilities
        let now = Date(timeIntervalSince1970: 1_000_000)
        let link = "https://files.example.com/2026/10/A7kdP2x.png"
        var settings = ShortLinkSettings(providerId: "shlink", endpoint: "https://s.example.com")

        XCTAssertEqual(ShortLinkRules.decide(settings: nil, capabilities: shlink, link: link, now: now), .skip)
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, now: now), .create(expiresAt: nil))

        // Only links longer than the limit, unless asked for by hand.
        settings.onlyLongerThan = link.count
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, now: now), .skip)
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, explicit: true, now: now), .create(expiresAt: nil))
        settings.onlyLongerThan = link.count - 1
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, now: now), .create(expiresAt: nil))
        settings.onlyLongerThan = 0

        // The upload's expiry goes along when the provider can expire links.
        let in7Days = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, uploadExpiresAt: in7Days, now: now), .create(expiresAt: in7Days))
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: yourls, link: link, uploadExpiresAt: in7Days, now: now), .create(expiresAt: nil))

        // Temporary links: only with the toggle and expiration support,
        // and never outliving the temporary link.
        let inAnHour = now.addingTimeInterval(3600)
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, temporaryExpiresAt: inAnHour, now: now), .skip)
        settings.shortenTemporaryLinks = true
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, temporaryExpiresAt: inAnHour, uploadExpiresAt: in7Days, now: now), .create(expiresAt: inAnHour))
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: yourls, link: link, temporaryExpiresAt: inAnHour, now: now), .skip)
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, temporaryExpiresAt: now.addingTimeInterval(30), now: now), .skip)
        XCTAssertFalse(ShortLinkRules.canShortenTemporaryLinks(yourls))
        XCTAssertTrue(ShortLinkRules.canShortenTemporaryLinks(shlink))

        // One file of a folder uploaded with its structure.
        XCTAssertEqual(ShortLinkRules.decide(settings: settings, capabilities: shlink, link: link, isFolderFile: true, now: now), .skip)
    }

    func testActiveLink() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = Self.snapshot(createdAt: now.addingTimeInterval(-300))
        let newer = Self.snapshot(createdAt: now.addingTimeInterval(-100))
        let newestExpired = Self.snapshot(createdAt: now.addingTimeInterval(-50), expiresAt: now.addingTimeInterval(-1))
        let orphaned = Self.snapshot(status: .orphaned, createdAt: now)
        XCTAssertEqual(ShortLinkRules.active([old, newer, newestExpired, orphaned], now: now)?.id, newer.id)
        XCTAssertNil(ShortLinkRules.active([orphaned, newestExpired], now: now))
    }

    func testDeleteTransitions() async throws {
        let fake = FakeOperations(provider: "shlink", capabilities: try Self.definition("shlink").capabilities)
        let active = Self.snapshot()
        let failing = Self.snapshot(providerId: "fail")
        let expired = Self.snapshot(status: .expired, providerId: "fail")
        let otherProvider = Self.snapshot(provider: "kutt")
        let alreadyDeleted = Self.snapshot(status: .deleted)
        let noID = Self.snapshot(providerId: nil)
        let statuses = await ShortLinkLifecycle.deleteAll([active, failing, expired, otherProvider, alreadyDeleted, noID], operations: fake)
        XCTAssertEqual(statuses[active.id], .deleted)
        XCTAssertEqual(statuses[failing.id], .orphaned)
        XCTAssertEqual(statuses[expired.id], .expired)
        XCTAssertEqual(statuses[otherProvider.id], .orphaned)
        XCTAssertEqual(statuses[noID.id], .orphaned)
        XCTAssertNil(statuses[alreadyDeleted.id])
        XCTAssertEqual(fake.deleted, ["code", "fail", "fail"])

        // A provider without delete: the link may still exist.
        let yourls = FakeOperations(provider: "shlink", capabilities: try Self.definition("yourls").capabilities)
        let noDelete = await ShortLinkLifecycle.deleteAll([active], operations: yourls)
        XCTAssertEqual(noDelete[active.id], .orphaned)
        XCTAssertTrue(yourls.deleted.isEmpty)
        // No shortener set up any more.
        let none = await ShortLinkLifecycle.deleteAll([active], operations: nil)
        XCTAssertEqual(none[active.id], .orphaned)

        let single = try await ShortLinkLifecycle.delete(active, operations: fake)
        XCTAssertEqual(single, .deleted)
        do {
            _ = try await ShortLinkLifecycle.delete(active, operations: yourls)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ShortLinkError, .unsupported)
        }
    }

    func testMoveTransitions() async throws {
        let shlink = FakeOperations(provider: "shlink", capabilities: try Self.definition("shlink").capabilities)
        let yourls = FakeOperations(provider: "yourls", capabilities: try Self.definition("yourls").capabilities)
        let active = Self.snapshot()
        let failing = Self.snapshot(providerId: "fail")

        XCTAssertEqual(ShortLinkRules.movePlan([], operations: shlink), .nothing)
        XCTAssertEqual(ShortLinkRules.movePlan([Self.snapshot(status: .orphaned)], operations: shlink), .nothing)
        XCTAssertEqual(ShortLinkRules.movePlan([active], operations: shlink), .update)
        XCTAssertEqual(ShortLinkRules.movePlan([Self.snapshot(provider: "yourls")], operations: yourls), .warn)
        XCTAssertEqual(ShortLinkRules.movePlan([active], operations: nil), .warn)
        // Made with a provider that isn't set up any more.
        XCTAssertEqual(ShortLinkRules.movePlan([Self.snapshot(provider: "kutt")], operations: shlink), .warn)

        let updated = await ShortLinkLifecycle.updateAll([active], to: "https://f.example.com/new.png", operations: shlink)
        XCTAssertTrue(updated.allUpdated)
        XCTAssertEqual(updated.statuses[active.id], .active)
        XCTAssertEqual(shlink.updated.first?.url, "https://f.example.com/new.png")

        // An update that fails: the old object stays, the link is unknown.
        let partly = await ShortLinkLifecycle.updateAll([active, failing], to: "https://f.example.com/new.png", operations: shlink)
        XCTAssertFalse(partly.allUpdated)
        XCTAssertEqual(partly.statuses[failing.id], .unknown)
        XCTAssertEqual(partly.statuses[active.id], .active)

        // Moved anyway without update support.
        XCTAssertEqual(ShortLinkLifecycle.orphanAll([active, Self.snapshot(status: .expired)]), [active.id: .orphaned])
    }

    func testExpiryTransitions() {
        let active = Self.snapshot()
        let unknown = Self.snapshot(status: .unknown)
        let deleted = Self.snapshot(status: .deleted)
        XCTAssertEqual(ShortLinkLifecycle.expireAll([active, unknown, deleted]), [active.id: .expired, unknown.id: .expired])
    }

    // MARK: - Output

    func testOutputUsesTheShortLink() {
        let long = URL(string: "https://files.example.com/2026/10/A7kdP2x.png")!
        let short = URL(string: "https://s.example.com/12C18")!
        XCTAssertEqual(OutputFormatter.format(publicURL: long, shortURL: short, mode: .url, filename: "a.png"), "https://s.example.com/12C18")
        XCTAssertEqual(OutputFormatter.format(publicURL: long, shortURL: short, mode: .markdown, filename: "a.png"), "![](https://s.example.com/12C18)")
        XCTAssertEqual(OutputFormatter.format(publicURL: long, shortURL: short, mode: .html, filename: "a.pdf"), "<a href=\"https://s.example.com/12C18\">a.pdf</a>")
        XCTAssertEqual(
            OutputFormatter.format(publicURL: long, shortURL: short, mode: .custom, filename: "a.png", customTemplate: "{url} {shortUrl} {longUrl}"),
            "https://s.example.com/12C18 https://s.example.com/12C18 https://files.example.com/2026/10/A7kdP2x.png"
        )
        XCTAssertEqual(
            OutputFormatter.format(publicURL: long, mode: .custom, filename: "a.png", customTemplate: "{shortUrl} {longUrl}"),
            "https://files.example.com/2026/10/A7kdP2x.png https://files.example.com/2026/10/A7kdP2x.png"
        )
    }

    // MARK: - History

    /// Adding the ShortLink model to an existing history store keeps what's
    /// in it.
    @MainActor
    func testAddingShortLinksKeepsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("default.store")
        let recordID = UUID()
        do {
            let schema = Schema([UploadRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            container.mainContext.insert(UploadRecord(id: recordID, localFilename: "a.png", objectKey: "a.png", publicURLString: "https://f.example.com/a.png", destinationID: UUID(), destinationName: "Main", mimeType: "image/png", byteSize: 1))
            try container.mainContext.save()
        }
        let schema = Schema([UploadRecord.self, ShortLink.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<UploadRecord>()).map(\.id), [recordID])
        context.insert(ShortLink(uploadID: recordID, provider: "shlink", providerName: "Shlink", providerId: "12C18", domain: nil, shortUrl: "https://s.example.com/12C18", targetUrl: "https://f.example.com/a.png"))
        try context.save()
        let links = try context.fetch(FetchDescriptor<ShortLink>(predicate: #Predicate { $0.uploadID == recordID }))
        XCTAssertEqual(links.first?.status, .active)
    }

    // MARK: - A real Shlink

    /// Runs only with AKTAR_TEST_SHLINK_URL and AKTAR_TEST_SHLINK_KEY set
    /// (TEST_RUNNER_ prefixed for xcodebuild), against a Shlink instance.
    func testRealShlink() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["AKTAR_TEST_SHLINK_URL"], let key = environment["AKTAR_TEST_SHLINK_KEY"] else {
            throw XCTSkip("AKTAR_TEST_SHLINK_URL and AKTAR_TEST_SHLINK_KEY aren't set")
        }
        let engine = ShortLinkEngine(
            definition: try Self.definition("shlink"),
            settings: ShortLinkSettings(providerId: "shlink", endpoint: endpoint, allowInsecureHTTP: true),
            token: key
        )
        let tested = try await engine.test()
        XCTAssertNil(tested.created)
        let target = "https://getaktar.com/?aktar-test=\(UUID().uuidString)"
        let created = try await engine.create(url: target, expiresAt: Date().addingTimeInterval(7 * 86_400))
        let id = try XCTUnwrap(created.providerId)
        XCTAssertTrue(created.shortUrl.hasSuffix("/" + id))

        // A visit, then the stats.
        var visit = URLRequest(url: try XCTUnwrap(URL(string: created.shortUrl)))
        visit.setValue("Mozilla/5.0 (Macintosh) AktarTest", forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil).data(for: visit)
        var stats = ShortLinkStats(clicks: nil, lastClickAt: nil)
        for _ in 0..<10 {
            stats = try await engine.stats(ShortLinkTarget(providerId: id))
            if (stats.clicks ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(stats.clicks, 1)
        XCTAssertNotNil(stats.lastClickAt)

        try await engine.update(ShortLinkTarget(providerId: id), url: target + "&moved=1")
        try await engine.delete(ShortLinkTarget(providerId: id))
        do {
            _ = try await engine.stats(ShortLinkTarget(providerId: id))
            XCTFail("The link should be gone")
        } catch {
            guard case .rejected(404, _) = error as? ShortLinkError else { return XCTFail("\(error)") }
        }

        // A wrong key is refused, with Shlink's own message.
        let wrong = ShortLinkEngine(definition: engine.definition, settings: engine.settings, token: "wrong-key")
        do {
            _ = try await wrong.test()
            XCTFail("Expected an error")
        } catch {
            guard case .rejected(401, let message) = error as? ShortLinkError else { return XCTFail("\(error)") }
            XCTAssertNotNil(message)
        }
    }

    // MARK: - Helpers

    private static func definition(_ id: String) throws -> ShortLinkDefinition {
        try XCTUnwrap(ShortLinkProviders.definition(id: id), "No \(id) definition")
    }

    private static func json(_ request: URLRequest) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? NSDictionary)
    }

    private static func snapshot(provider: String = "shlink", status: ShortLinkStatus = .active, providerId: String? = "code", createdAt: Date = Date(), expiresAt: Date? = nil) -> ShortLinkSnapshot {
        ShortLinkSnapshot(id: UUID(), provider: provider, providerId: providerId, domain: nil, status: status, createdAt: createdAt, expiresAt: expiresAt)
    }
}

/// Answers each request with the last response set.
private final class FakeTransport: ShortLinkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var response: Result<(Int, Data), Error> = .success((200, Data()))
    private(set) var requests: [URLRequest] = []

    func respond(_ status: Int, _ body: String) {
        lock.withLock { response = .success((status, Data(body.utf8))) }
    }

    func fail(_ error: Error) {
        lock.withLock { response = .failure(error) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = lock.withLock {
            requests.append(request)
            return self.response
        }
        let (status, data) = try response.get()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Deletes and updates succeed, except for the id "fail".
private final class FakeOperations: ShortLinkOperations, @unchecked Sendable {
    let provider: String
    let capabilities: ShortLinkCapabilities
    private let lock = NSLock()
    private(set) var deleted: [String] = []
    private(set) var updated: [(id: String, url: String)] = []

    init(provider: String, capabilities: ShortLinkCapabilities) {
        self.provider = provider
        self.capabilities = capabilities
    }

    func create(url: String, expiresAt: Date?) async throws -> CreatedShortLink {
        CreatedShortLink(shortUrl: "https://s.example.com/new", providerId: "new")
    }

    func delete(_ target: ShortLinkTarget) async throws {
        lock.withLock { deleted.append(target.providerId) }
        if target.providerId == "fail" { throw ShortLinkError.rejected(status: 422, message: nil) }
    }

    func update(_ target: ShortLinkTarget, url: String) async throws {
        lock.withLock { updated.append((target.providerId, url)) }
        if target.providerId == "fail" { throw ShortLinkError.rejected(status: 500, message: nil) }
    }

    func stats(_ target: ShortLinkTarget) async throws -> ShortLinkStats {
        ShortLinkStats(clicks: 1, lastClickAt: nil)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
