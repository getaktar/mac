import XCTest

final class DestinationAutomationTests: XCTestCase {
    func testKindListsDontOverlap() {
        var seen = Set<String>()
        for kind in FileRouting.Kind.allCases {
            for ext in FileRouting.extensionsByKind[kind] ?? [] {
                XCTAssertTrue(seen.insert(ext).inserted, "\(ext) is in two kinds")
            }
        }
        XCTAssertEqual(FileRouting.kind(forExtension: "PNG"), .image)
        XCTAssertEqual(FileRouting.kind(forExtension: "mov"), .video)
        XCTAssertEqual(FileRouting.kind(forExtension: "flac"), .audio)
        XCTAssertEqual(FileRouting.kind(forExtension: "key"), .document)
        XCTAssertEqual(FileRouting.kind(forExtension: "dmg"), .archive)
        XCTAssertNil(FileRouting.kind(forExtension: "xyz"))
    }

    func testRoutingPrecedence() {
        let main = Self.destination("Main")
        var shots = Self.destination("Screenshots")
        shots.useFor = FileRouting(kinds: [.image, .video])
        var builds = Self.destination("Builds")
        builds.useFor = FileRouting(kinds: [.archive], extensions: ["png"])
        let all = [main, shots, builds]

        func route(_ name: String, defaultID: UUID? = main.id) -> String? {
            DestinationRouting.destination(forFilename: name, destinations: all, defaultID: defaultID)?.name
        }
        XCTAssertEqual(route("clip.MOV"), "Screenshots")
        XCTAssertEqual(route("app.dmg"), "Builds")
        // An extension beats a kind.
        XCTAssertEqual(route("icon.png"), "Builds")
        XCTAssertEqual(route("notes.txt"), "Main")
        XCTAssertEqual(route("README"), "Main")
        XCTAssertNil(DestinationRouting.destination(forFilename: "a.png", destinations: [], defaultID: nil))
    }

    func testDefaultWinsATieOtherwiseTheFirst() {
        var first = Self.destination("First")
        first.useFor = FileRouting(kinds: [.image])
        var second = Self.destination("Second")
        second.useFor = FileRouting(kinds: [.image])
        let other = Self.destination("Other")
        let all = [other, first, second]
        XCTAssertEqual(DestinationRouting.destination(forFilename: "a.jpg", destinations: all, defaultID: second.id)?.name, "Second")
        XCTAssertEqual(DestinationRouting.destination(forFilename: "a.jpg", destinations: all, defaultID: other.id)?.name, "First")
    }

    func testExtensionValidation() {
        XCTAssertEqual(FileRouting.normalizedExtension(" .DMG "), "dmg")
        XCTAssertEqual(FileRouting.normalizedExtension("..mp4"), "mp4")
        XCTAssertNil(FileRouting.normalizedExtension(""))
        XCTAssertNil(FileRouting.normalizedExtension("tar.gz"))
        XCTAssertNil(FileRouting.normalizedExtension("a b"))
        XCTAssertNil(FileRouting.normalizedExtension(String(repeating: "a", count: 17)))
        let parsed = FileRouting.parseExtensions("dmg, .zip pkg dmg, tar.gz")
        XCTAssertEqual(parsed.extensions, ["dmg", "zip", "pkg"])
        XCTAssertEqual(parsed.invalid, ["tar.gz"])
    }

    func testRoutingDecodesLeniently() throws {
        let json = #"{"kinds": ["video", "spreadsheet", "image"], "extensions": ["DMG", "bad ext", "zip"]}"#
        let routing = try JSONDecoder().decode(FileRouting.self, from: Data(json.utf8))
        XCTAssertEqual(routing.kinds, [.image, .video])
        XCTAssertEqual(routing.extensions, ["dmg", "zip"])
    }

    func testDestinationHookPayload() throws {
        let payload = WatchHookPayload(
            event: "upload.replaced",
            destination: .init(id: "D", name: "Builds"),
            file: .init(path: "/tmp/a.png", name: "a.png", size: 3),
            upload: .init(key: "a.png", url: "https://x/a.png", destinationID: "D", reused: false)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.json()) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "upload.replaced")
        XCTAssertNil(object["folder"])
        XCTAssertEqual((object["destination"] as? [String: Any])?["name"] as? String, "Builds")
        // No short link: null, written out.
        let upload = try XCTUnwrap(object["upload"] as? [String: Any])
        XCTAssertTrue(upload["shortUrl"] is NSNull)

        let shortened = WatchHookPayload(
            event: "upload.succeeded",
            destination: .init(id: "D", name: "Builds"),
            file: .init(path: "/tmp/a.png", name: "a.png", size: 3),
            upload: .init(key: "a.png", url: "https://x/a.png", destinationID: "D", reused: false, shortUrl: "https://s.example.com/A1")
        )
        let shortObject = try XCTUnwrap(JSONSerialization.jsonObject(with: shortened.json()) as? [String: Any])
        XCTAssertEqual((shortObject["upload"] as? [String: Any])?["shortUrl"] as? String, "https://s.example.com/A1")
        XCTAssertEqual((shortObject["upload"] as? [String: Any])?["url"] as? String, "https://x/a.png")
    }

    private static func destination(_ name: String) -> DestinationConfig {
        DestinationConfig(
            name: name, preset: .customS3, accountID: nil, endpoint: "https://s3.example.com", region: "auto",
            bucket: name.lowercased(), publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}",
            forcePathStyle: true, isDefault: false
        )
    }
}
