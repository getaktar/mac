import Network
import XCTest

/// The local API's hello check and limits, Shortcuts file names, active
/// content, the Raycast handler check and the import review.
final class SecurityAuditTests: XCTestCase {
    // MARK: - /v1/hello

    func testHelloProofIsHMACOfTheNonce() {
        // hmac.new(b"test-token", b"aktar-hello-v1:abcdefghijklmnop", sha256)
        XCTAssertEqual(
            LocalHTTPServer.helloProof(nonce: "abcdefghijklmnop", token: "test-token"),
            "a6cf07a5a1eb5e4aec5d5cc95d8dd5cc639e20e0351976e0d9bfa2a92c69a9e0"
        )
    }

    func testHelloNonceRules() {
        XCTAssertTrue(LocalHTTPServer.isValidHelloNonce(String(repeating: "a", count: 16)))
        XCTAssertTrue(LocalHTTPServer.isValidHelloNonce(String(repeating: "Z", count: 128)))
        XCTAssertTrue(LocalHTTPServer.isValidHelloNonce("AZaz09-_AZaz09-_"))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce(String(repeating: "a", count: 15)))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce(String(repeating: "a", count: 129)))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce("abcdefghijklmno="))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce("abcdefghijklmno/"))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce("abcdefghijklmnoé"))
        XCTAssertFalse(LocalHTTPServer.isValidHelloNonce(""))
    }

    func testServerAnswersHelloWithoutTheToken() async throws {
        let token = "secret-token-for-tests"
        let (server, port) = try await startServer(token: token)
        defer { server.stop() }
        let nonce = "n0nce_for-the-hello-check"

        let hello = try await send("GET /v1/hello?nonce=\(nonce) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
        XCTAssertTrue(hello.hasPrefix("HTTP/1.1 200 "), hello)
        let body = try XCTUnwrap(hello.components(separatedBy: "\r\n\r\n").last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        XCTAssertEqual(json, ["app": "Aktar", "proof": LocalHTTPServer.helloProof(nonce: nonce, token: token)])
        XCTAssertFalse(hello.contains(token))

        let missing = try await send("GET /v1/hello HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n", port: port)
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 400 "), missing)
        let short = try await send("GET /v1/hello?nonce=short HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
        XCTAssertTrue(short.hasPrefix("HTTP/1.1 400 "), short)
        let post = try await send("POST /v1/hello?nonce=\(nonce) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n", port: port)
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405 "), post)

        // The usual checks still come first.
        let browser = try await send("GET /v1/hello?nonce=\(nonce) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: https://evil.example\r\n\r\n", port: port)
        XCTAssertTrue(browser.hasPrefix("HTTP/1.1 403 "), browser)
        let rebinding = try await send("GET /v1/hello?nonce=\(nonce) HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n", port: port)
        XCTAssertTrue(rebinding.hasPrefix("HTTP/1.1 403 "), rebinding)

        // Everything else still needs the token.
        let other = try await send("GET /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n", port: port)
        XCTAssertTrue(other.hasPrefix("HTTP/1.1 401 "), other)
        let authorized = try await send("GET /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n\r\n", port: port)
        XCTAssertTrue(authorized.hasPrefix("HTTP/1.1 200 "), authorized)
    }

    func testOversizedBodiesAreRefusedBeforeReading() async throws {
        let token = "secret-token-for-tests"
        let (server, port) = try await startServer(token: token)
        defer { server.stop() }
        let tooLarge = LocalHTTPServer.maxBodySize + 1
        let response = try await send("PUT /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(tooLarge)\r\n\r\n", port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 "), response)
        // More than the disk has free (no Mac has an exabyte).
        let noRoom = try await send("PUT /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(LocalHTTPServer.maxBodySize)\r\n\r\n", port: port)
        XCTAssertTrue(noRoom.hasPrefix("HTTP/1.1 413 "), noRoom)
        // Without the token it's still a 401, not a hint about sizes.
        let anonymous = try await send("PUT /v1/uploads HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(tooLarge)\r\n\r\n", port: port)
        XCTAssertTrue(anonymous.hasPrefix("HTTP/1.1 401 "), anonymous)
    }

    private func startServer(token: String) async throws -> (LocalHTTPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 49152...64000)
            let server = LocalHTTPServer(port: port, token: token) { _ in .json(200, ["ok": true]) }
            let ready = ReadyFlag()
            try server.start { state in ready.set(state) }
            for _ in 0..<100 where ready.state == nil || ready.state == .starting {
                try await Task.sleep(for: .milliseconds(20))
            }
            if ready.state == .ready { return (server, port) }
            server.stop()
        }
        throw XCTSkip("No free port for the local API server.")
    }

    /// Sends `request` as is and returns everything the server answers
    /// before it closes the connection.
    private func send(_ request: String, port: UInt16) async throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "SecurityAuditTests.client")
        connection.start(queue: queue)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        var received = Data()
        while true {
            let (data, done) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error, data == nil { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { received.append(data) }
            if done || data == nil { break }
        }
        return String(decoding: received, as: UTF8.self)
    }

    // MARK: - Shortcuts file names

    func testIntentFileNamesStayInTheStagingFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AktarIntentTests-\(UUID().uuidString)", isDirectory: true)
        let named = { (name: String) in TempFiles.fileURL(named: name, in: folder)?.lastPathComponent }
        XCTAssertEqual(named("photo.png"), "photo.png")
        XCTAssertEqual(named("../../../Library/Application Support/destinations.json"), "destinations.json")
        XCTAssertEqual(named("a/.."), "file")
        XCTAssertEqual(named(".."), "file")
        XCTAssertEqual(named("."), "file")
        XCTAssertEqual(named(""), "file")
        XCTAssertEqual(named("..\\..\\x.txt"), "....x.txt")
        XCTAssertEqual(named("a\u{0}b.txt"), "ab.txt")
        for name in ["../x", "/etc/passwd", "a/../../b", ".."] {
            let url = try XCTUnwrap(TempFiles.fileURL(named: name, in: folder))
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path, name)
        }
    }

    // MARK: - Active content

    func testStylesheetsAndWebArchivesAreDownloaded() {
        for ext in ["xsl", "xslt", "shtml", "mht", "mhtml", "XSL"] {
            XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["f." + ext], contentType: "application/octet-stream"), "attachment", ext)
        }
        for type in ["text/xsl", "application/xslt+xml", "multipart/related", "application/x-mimearchive"] {
            XCTAssertEqual(ContentTypeResolver.contentDisposition(names: ["noext"], contentType: type), "attachment", type)
        }
        XCTAssertNil(ContentTypeResolver.contentDisposition(names: ["sheet.xlsx"], contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
    }

    // MARK: - Raycast pairing

    func testOnlyRaycastCountsAsRaycast() throws {
        XCTAssertFalse(RaycastApp.isRaycast(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertFalse(RaycastApp.isRaycast(URL(fileURLWithPath: "/nonexistent/Raycast.app")))
        let raycast = URL(fileURLWithPath: "/Applications/Raycast.app")
        guard FileManager.default.fileExists(atPath: raycast.path) else {
            throw XCTSkip("Raycast isn't installed on this Mac.")
        }
        XCTAssertTrue(RaycastApp.isRaycast(raycast))
        let callback = try XCTUnwrap(URL(string: "raycast://extensions/merttopuz/aktar/upload-file"))
        XCTAssertEqual(RaycastApp.handler(opening: callback)?.standardizedFileURL, raycast.standardizedFileURL)
    }

    // MARK: - Import review

    private func importedPayload() throws -> DestinationTransfer.Payload {
        let json: [String: Any] = [
            "v": 1,
            "destination": [
                "id": UUID().uuidString,
                "name": "Team",
                "preset": "customS3",
                "endpoint": "https://s3.attacker.example",
                "bucket": "shared",
                "publicBaseURL": "https://files.attacker.example/pub",
                "useFor": ["kinds": ["image"], "extensions": ["pdf"]],
                "hooks": [
                    ["kind": "webhook", "target": "https://hooks.attacker.example/collect"],
                    ["kind": "script", "target": "post.sh", "enabled": true],
                    ["kind": "webhook", "target": "https://other.example/x", "enabled": false],
                ],
                "shortLinks": ["providerId": "shlink", "endpoint": "https://s.attacker.example", "onlyLongerThan": 0, "shortenTemporaryLinks": false, "allowInsecureHTTP": false],
            ],
            "credentials": ["accessKeyId": "AKIA", "secretAccessKey": "secret", "shortLinkToken": "t"],
            "customTemplate": "<img src=\"https://track.attacker.example/{url}\">",
        ]
        return try DestinationTransfer.decodePayload(JSONSerialization.data(withJSONObject: json))
    }

    func testReviewListsWhereThingsGo() throws {
        let payload = try importedPayload()
        XCTAssertEqual(payload.endpointHost, "s3.attacker.example")
        XCTAssertEqual(payload.publicHost, "files.attacker.example")
        XCTAssertEqual(payload.shortLinkHost, "s.attacker.example")
        XCTAssertEqual(payload.webhookHosts, ["hooks.attacker.example", "other.example"])
        XCTAssertEqual(payload.scriptNames, ["post.sh"])
    }

    func testHooksRoutingAndTemplateAreOffUnlessKept() throws {
        let payload = try importedPayload()
        let declined = payload.reviewed(keepHooks: false, keepUseFor: false, keepTemplate: false)
        XCTAssertEqual(declined.destination.hooks?.count, 3)
        XCTAssertEqual(declined.destination.hooks?.contains { $0.enabled }, false)
        XCTAssertNil(declined.destination.useFor)
        XCTAssertNil(declined.customTemplate)
        // What isn't reviewed comes as it was.
        XCTAssertEqual(declined.destination.endpoint, payload.destination.endpoint)
        XCTAssertEqual(declined.destination.shortLinks, payload.destination.shortLinks)

        let kept = payload.reviewed(keepHooks: true, keepUseFor: true, keepTemplate: true)
        XCTAssertEqual(kept.destination.hooks?.map(\.enabled), [true, true, false])
        XCTAssertEqual(kept.destination.useFor, FileRouting(kinds: [.image], extensions: ["pdf"]))
        XCTAssertEqual(kept.customTemplate, payload.customTemplate)
    }

    func testUpdatingKeepsTheExistingHooksAndRoutingUnlessKept() throws {
        let payload = try importedPayload()
        var existing = payload.destination
        existing.hooks = [payload.destination.hooks![0]]
        existing.useFor = FileRouting(kinds: [.video], extensions: [])
        let declined = payload.reviewed(keepHooks: false, keepUseFor: false, keepTemplate: false, updating: existing)
        XCTAssertEqual(declined.destination.hooks, existing.hooks)
        XCTAssertEqual(declined.destination.useFor, existing.useFor)

        let kept = payload.reviewed(keepHooks: true, keepUseFor: true, keepTemplate: false, updating: existing)
        XCTAssertEqual(kept.destination.hooks, payload.destination.hooks)
        XCTAssertEqual(kept.destination.useFor, payload.destination.useFor)
    }
}

private final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalHTTPServer.State?

    var state: LocalHTTPServer.State? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ state: LocalHTTPServer.State) {
        lock.lock()
        value = state
        lock.unlock()
    }
}
