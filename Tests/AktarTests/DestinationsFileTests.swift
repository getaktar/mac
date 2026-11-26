import XCTest

final class DestinationsFileTests: XCTestCase {
    private static let known = """
    {"id":"6F1B2C3D-0000-4000-8000-000000000001","name":"Main","preset":"minIO","endpoint":"e","region":"r",\
    "bucket":"b","publicBaseURL":"p","objectPathTemplate":"{uuid}.{ext}","forcePathStyle":true,"isDefault":true,\
    "folderUpload":"someNewMode","outputMode":"someNewOutput","expiryDays":7}
    """
    /// A kind of storage a newer version added.
    private static let newer = #"{"id":"6F1B2C3D-0000-4000-8000-000000000002","name":"Server","kind":"sftp","host":"example.com"}"#

    func testKeepsDestinationsItCantRead() throws {
        let file = #"{"destinations":[\#(Self.known),\#(Self.newer)],"defaultID":"6F1B2C3D-0000-4000-8000-000000000001"}"#
        var contents = try XCTUnwrap(DestinationsFile.decode(Data(file.utf8)))
        XCTAssertEqual(contents.destinations.map(\.name), ["Main"])
        XCTAssertEqual(contents.unreadable.count, 1)
        XCTAssertEqual(contents.defaultID?.uuidString, "6F1B2C3D-0000-4000-8000-000000000001")

        // Settings this version doesn't know are off; the rest stays.
        let main = contents.destinations[0]
        XCTAssertNil(main.folderUpload)
        XCTAssertNil(main.outputMode)
        XCTAssertEqual(main.expiryDays, 7)
        XCTAssertTrue(main.isDefault)

        // Saving writes the one it couldn't read back as it was.
        contents.destinations[0].name = "Renamed"
        let saved = try XCTUnwrap(DestinationsFile.encode(contents))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let entries = try XCTUnwrap(root["destinations"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["name"] as? String, "Renamed")
        let newer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.newer.utf8)) as? NSDictionary)
        XCTAssertEqual(entries[1] as NSDictionary, newer)

        let again = try XCTUnwrap(DestinationsFile.decode(saved))
        XCTAssertEqual(again.destinations.map(\.name), ["Renamed"])
        XCTAssertEqual(again.unreadable.count, 1)
    }

    func testRoundTripsAKnownDestination() throws {
        let decoded = try JSONDecoder().decode(DestinationConfig.self, from: Data(#"{"id":"6F1B2C3D-0000-4000-8000-000000000003","name":"N","preset":"cloudflareR2","endpoint":"e","region":"auto","bucket":"b","publicBaseURL":"p","objectPathTemplate":"{short}.{ext}","forcePathStyle":false,"isDefault":false,"sharePage":true,"encryption":"link","expiryDays":30}"#.utf8))
        let again = try JSONDecoder().decode(DestinationConfig.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
        XCTAssertEqual(again.sharePage, true)
        XCTAssertEqual(again.expiryDays, 30)
    }

    func testRejectsWhatIsntADestinationsFile() {
        XCTAssertNil(DestinationsFile.decode(Data("{not json".utf8)))
        XCTAssertNil(DestinationsFile.decode(Data("[1,2]".utf8)))
        XCTAssertEqual(DestinationsFile.decode(Data("{}".utf8))?.destinations.count, 0)
    }
}
