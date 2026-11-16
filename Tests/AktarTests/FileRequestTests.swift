import XCTest

/// File requests (docs/share-pages.md, part 4): keys, sender names,
/// pairing a slot's file with its metadata, and the bucket's CORS rule.
final class FileRequestTests: XCTestCase {
    func testKeysAndIDs() {
        XCTAssertEqual(FileRequests.prefix(id: "AbC123xyz0"), ".aktar/requests/AbC123xyz0/")
        XCTAssertEqual(FileRequests.pageKey(id: "AbC123xyz0"), ".aktar/requests/AbC123xyz0/index.html")
        XCTAssertEqual(FileRequests.fileKey(id: "a", slot: 3), ".aktar/requests/a/3")
        XCTAssertEqual(FileRequests.metadataKey(id: "a", slot: 3), ".aktar/requests/a/3.json")
        let id = FileRequests.newID()
        XCTAssertEqual(id.count, 10)
        XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(id, FileRequests.newID())
    }

    func testSenderNamesAreSanitized() {
        XCTAssertEqual(FileRequests.sanitizedName("report.pdf", slot: 1), "report.pdf")
        XCTAssertEqual(FileRequests.sanitizedName("../../etc/passwd", slot: 1), "passwd")
        XCTAssertEqual(FileRequests.sanitizedName(#"C:\Users\me\shot.png"#, slot: 1), "shot.png")
        XCTAssertEqual(FileRequests.sanitizedName("a:b\u{0}c\u{1B}d\n.txt", slot: 1), "abcd.txt")
        XCTAssertEqual(FileRequests.sanitizedName("  spaced.txt  ", slot: 1), "spaced.txt")
        XCTAssertEqual(FileRequests.sanitizedName("", slot: 4), "upload-4")
        XCTAssertEqual(FileRequests.sanitizedName(nil, slot: 2), "upload-2")
        XCTAssertEqual(FileRequests.sanitizedName("..", slot: 2), "upload-2")
        XCTAssertEqual(FileRequests.sanitizedName("dir/", slot: 7), "upload-7")
        XCTAssertEqual(FileRequests.sanitizedName("\u{7}:/", slot: 5), "upload-5")
        let long = FileRequests.sanitizedName(String(repeating: "x", count: 300) + ".png", slot: 1)
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix(".png"), "a short extension stays")
        XCTAssertEqual(FileRequests.sanitizedName(String(repeating: "é", count: 250), slot: 1).count, 200)
    }

    func testMetadataIsReadWithLimits() {
        XCTAssertEqual(FileRequests.metadataName(Data(#"{"v":1,"name":"a.png","type":"text/html","size":3,"sent":"2026-11-09T12:00:00Z"}"#.utf8)), "a.png")
        XCTAssertNil(FileRequests.metadataName(Data("not json".utf8)))
        XCTAssertNil(FileRequests.metadataName(Data(#"{"name":5}"#.utf8)))
        var big = #"{"name":"a","pad":""#
        big += String(repeating: "x", count: 5000) + #""}"#
        XCTAssertNil(FileRequests.metadataName(Data(big.utf8)), "over 4 KB")
    }

    func testSlotPairing() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let prefix = FileRequests.prefix(id: "r")
        func object(_ name: String, age: TimeInterval) -> BucketObject {
            BucketObject(key: prefix + name, size: 10, lastModified: now.addingTimeInterval(-age))
        }
        let objects = [
            object("index.html", age: 9999),
            object("1", age: 30), object("1.json", age: 29),       // both: ready
            object("2", age: 30),                                   // waiting for its metadata
            object("3", age: 700),                                  // 10 minutes without: ready, unnamed
            object("4.json", age: 5),                               // metadata alone: nothing to do
            object("05", age: 900),                                 // not a slot name
            object("6", age: 900), object("6.json", age: 900),      // past the slot count
            BucketObject(key: ".aktar/requests/other/1", size: 1, lastModified: now),
        ]
        let ready = FileRequests.readySlots(in: objects, id: "r", slotCount: 5, now: now)
        XCTAssertEqual(ready.map(\.slot), [1, 3])
        XCTAssertEqual(ready[0].metadata?.key, prefix + "1.json")
        XCTAssertNil(ready[1].metadata)
        XCTAssertEqual(FileRequests.readySlots(in: objects, id: "r", slotCount: 6, now: now).map(\.slot), [1, 3, 6])
        XCTAssertEqual(FileRequests.readySlots(in: objects, id: "r", slotCount: 5, now: now.addingTimeInterval(600)).map(\.slot), [1, 2, 3])
    }

    func testRequestLifetime() {
        let created = Date(timeIntervalSince1970: 1_000)
        let request = FileRequest(id: "r", destinationId: UUID(), title: "", note: "", createdAt: created, expiresAt: created.addingTimeInterval(3600), slotCount: 1, maxBytes: 1, link: "", received: 0, closedAt: nil)
        XCTAssertFalse(request.isExpired(now: created.addingTimeInterval(3599)))
        XCTAssertTrue(request.isExpired(now: created.addingTimeInterval(3600)))
        XCTAssertFalse(request.isDueToClose(now: created.addingTimeInterval(7199)), "checked for an hour after it expires")
        XCTAssertTrue(request.isDueToClose(now: created.addingTimeInterval(7200)))
        XCTAssertEqual(request.sourceLabel, String(localized: "Request"))
    }

    func testRequestsAreSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = FileRequest(id: "r1", destinationId: UUID(), title: "Logs", note: "n", createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: Date(timeIntervalSince1970: 5_000), slotCount: 5, maxBytes: 100, link: "https://x/y", received: 0, closedAt: nil)
        try MainActor.assumeIsolated {
            let store = FileRequestStore(directory: folder)
            store.add(request)
            var updated = request
            updated.received = 2
            store.update(updated)
            let reloaded = FileRequestStore(directory: folder)
            XCTAssertEqual(reloaded.requests, [updated])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("requests.json"))) as? [[String: Any]])
            XCTAssertEqual(Set(object[0].keys), ["id", "destinationId", "title", "note", "createdAt", "expiresAt", "slotCount", "maxBytes", "link", "received"])
        }
    }

    // MARK: - CORS

    private let origin = "https://cdn.example.com"

    func testCORSRuleIsAddedNextToTheBucketsOwn() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <CORSRule><ID>site</ID><AllowedOrigin>https://example.com</AllowedOrigin><AllowedMethod>GET</AllowedMethod><MaxAgeSeconds>60</MaxAgeSeconds></CORSRule>
        </CORSConfiguration>
        """
        let rules = try XCTUnwrap(CORSXML.configurationRules(in: xml))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].origins, ["https://example.com"])
        let merged = try XCTUnwrap(CORSXML.merged(rules, origin: origin))
        XCTAssertTrue(merged.contains("<CORSRule><ID>site</ID><AllowedOrigin>https://example.com</AllowedOrigin><AllowedMethod>GET</AllowedMethod><MaxAgeSeconds>60</MaxAgeSeconds></CORSRule>"), "kept exactly")
        XCTAssertTrue(merged.contains("<CORSRule>" + CORSXML.ruleXML(origin: origin) + "</CORSRule>"))
        XCTAssertEqual(CORSXML.ruleXML(origin: origin), "<ID>aktar-file-requests</ID><AllowedOrigin>https://cdn.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod><AllowedHeader>content-type</AllowedHeader><AllowedHeader>if-none-match</AllowedHeader><ExposeHeader>etag</ExposeHeader><MaxAgeSeconds>3600</MaxAgeSeconds>")

        // Once it's there, nothing is written.
        let again = try XCTUnwrap(CORSXML.configurationRules(in: merged))
        XCTAssertNil(CORSXML.merged(again, origin: origin))
    }

    func testCORSRuleIsReplacedByIDOrByOriginAndPut() throws {
        let byID = try XCTUnwrap(CORSXML.configurationRules(in: CORSXML.document(["<ID>aktar-file-requests</ID><AllowedOrigin>https://old.example.com</AllowedOrigin><AllowedMethod>PUT</AllowedMethod>"])))
        let merged = try XCTUnwrap(CORSXML.merged(byID, origin: origin))
        XCTAssertFalse(merged.contains("old.example.com"))
        XCTAssertEqual(merged.components(separatedBy: "<CORSRule>").count - 1, 1)

        // A provider that drops IDs: matched by the origin with PUT.
        let noID = try XCTUnwrap(CORSXML.configurationRules(in: CORSXML.document([
            "<AllowedOrigin>https://cdn.example.com</AllowedOrigin><AllowedMethod>put</AllowedMethod><AllowedHeader>content-type</AllowedHeader>",
            "<AllowedOrigin>https://cdn.example.com</AllowedOrigin><AllowedMethod>GET</AllowedMethod>",
        ])))
        let replaced = try XCTUnwrap(CORSXML.merged(noID, origin: origin))
        XCTAssertEqual(replaced.components(separatedBy: "<CORSRule>").count - 1, 2)
        XCTAssertTrue(replaced.contains("<AllowedMethod>GET</AllowedMethod>"))
        XCTAssertTrue(replaced.contains("aktar-file-requests"))
    }

    // MARK: - Preflight (a key that can't touch CORS)

    func testPreflightAllowsTheRuleAsAddedInADashboard() {
        let r2 = [
            "Access-Control-Allow-Origin": "https://cdn.example.com",
            "Access-Control-Allow-Methods": "PUT",
            "Access-Control-Allow-Headers": "content-type,if-none-match",
        ]
        let both = CORSPreflight.requestHeaders(conditional: true)
        XCTAssertEqual(both, ["content-type", "if-none-match"])
        XCTAssertTrue(CORSPreflight.allows(status: 204, headers: r2, origin: origin, requestHeaders: both))
        // Header names and values in any case, lists with spaces.
        XCTAssertTrue(CORSPreflight.allows(status: 200, headers: [
            "access-control-allow-origin": "https://cdn.example.com",
            "ACCESS-CONTROL-ALLOW-METHODS": "GET, put",
            "Access-Control-Allow-Headers": "Content-Type, If-None-Match",
        ], origin: origin, requestHeaders: both))
        // Wildcards.
        XCTAssertTrue(CORSPreflight.allows(status: 204, headers: [
            "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "*", "Access-Control-Allow-Headers": "*",
        ], origin: origin, requestHeaders: both))
        // Without conditional writes the page sends Content-Type only.
        let contentTypeOnly = r2.merging(["Access-Control-Allow-Headers": "content-type"]) { $1 }
        XCTAssertTrue(CORSPreflight.allows(status: 204, headers: contentTypeOnly, origin: origin, requestHeaders: CORSPreflight.requestHeaders(conditional: false)))
        XCTAssertFalse(CORSPreflight.allows(status: 204, headers: contentTypeOnly, origin: origin, requestHeaders: both))
    }

    func testPreflightRefusals() {
        let both = CORSPreflight.requestHeaders(conditional: true)
        let good = [
            "Access-Control-Allow-Origin": "https://cdn.example.com",
            "Access-Control-Allow-Methods": "PUT",
            "Access-Control-Allow-Headers": "content-type,if-none-match",
        ]
        XCTAssertFalse(CORSPreflight.allows(status: 400, headers: [:], origin: origin, requestHeaders: both), "R2 without a rule")
        XCTAssertFalse(CORSPreflight.allows(status: 403, headers: good, origin: origin, requestHeaders: both))
        XCTAssertFalse(CORSPreflight.allows(status: 204, headers: good.merging(["Access-Control-Allow-Origin": "https://other.example.com"]) { $1 }, origin: origin, requestHeaders: both))
        XCTAssertFalse(CORSPreflight.allows(status: 204, headers: good.merging(["Access-Control-Allow-Methods": "GET"]) { $1 }, origin: origin, requestHeaders: both))
        XCTAssertFalse(CORSPreflight.allows(status: 204, headers: good.filter { $0.key != "Access-Control-Allow-Origin" }, origin: origin, requestHeaders: both))
        XCTAssertFalse(CORSPreflight.allows(status: 204, headers: good.filter { $0.key != "Access-Control-Allow-Headers" }, origin: origin, requestHeaders: both))
    }

    func testCORSHintOnlyForAKeyWithoutThePermission() {
        let r2 = DestinationConfig(
            name: "R2", preset: .cloudflareR2, accountID: "acc", endpoint: "https://acc.r2.cloudflarestorage.com", region: "auto",
            bucket: "my-bucket", publicBaseURL: "https://cdn.example.com", objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: false, isDefault: false
        )
        var s3 = r2
        s3.preset = .customS3
        let r2Hint = CORSPreflight.hint(for: StorageError.lifecycleNotAllowed, destination: r2)
        XCTAssertTrue(r2Hint?.contains("R2 > my-bucket > Settings > CORS Policy") == true, r2Hint ?? "nil")
        let s3Hint = CORSPreflight.hint(for: StorageError.accessDenied, destination: s3)
        XCTAssertNotNil(s3Hint)
        XCTAssertFalse(s3Hint?.contains("Cloudflare") == true)
        XCTAssertNil(CORSPreflight.hint(for: StorageError.unknown("NotImplemented"), destination: r2), "MinIO: no bucket CORS at all")

    }

    func testUnreadableCORSIsNotOverwritten() {
        XCTAssertNil(CORSXML.configurationRules(in: "<html>proxy error</html>"))
        XCTAssertNil(CORSXML.configurationRules(in: "<CORSConfiguration><CORSRule><ID>x</ID></CORSConfiguration>"), "a rule that doesn't close")
        XCTAssertEqual(CORSXML.configurationRules(in: "<CORSConfiguration></CORSConfiguration>"), [])
    }

    func testCORSRuleJSONForTheDashboard() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(CORSXML.ruleJSON(origin: origin).utf8)) as? [[String: Any]])
        XCTAssertEqual(json[0]["AllowedOrigins"] as? [String], [origin])
        XCTAssertEqual(json[0]["AllowedMethods"] as? [String], ["PUT"])
        XCTAssertEqual(json[0]["AllowedHeaders"] as? [String], ["content-type", "if-none-match"])
        XCTAssertEqual(json[0]["MaxAgeSeconds"] as? Int, 3600)
    }
}
