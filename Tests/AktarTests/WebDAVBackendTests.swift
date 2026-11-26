import XCTest

/// WebDAV without a server (docs/storage-backends.md, "WebDAV"): how keys
/// become addresses, the Server URL rule, how statuses map to errors, and
/// reading PROPFIND replies the way different servers write them.
final class WebDAVBackendTests: XCTestCase {
    // MARK: - Addresses

    func testKeysAreEncodedSegmentBySegment() {
        XCTAssertEqual(WebDAVBackend.encodeKey("2026/11/a b.png"), "2026/11/a%20b.png")
        XCTAssertEqual(WebDAVBackend.encodeKey("a+b#c?d%e&f=g.txt"), "a%2Bb%23c%3Fd%25e%26f%3Dg.txt")
        XCTAssertEqual(WebDAVBackend.encodeKey("Ünïcödé/çay.jpg"), "%C3%9Cn%C3%AFc%C3%B6d%C3%A9/%C3%A7ay.jpg")
        // RFC 3986's unreserved characters stay.
        XCTAssertEqual(WebDAVBackend.encodeKey("A-z_0.9~"), "A-z_0.9~")
    }

    func testFileAndFolderAddresses() throws {
        let backend = Self.backend(endpoint: "https://cloud.example.com/remote.php/dav/files/me/aktar/")
        XCTAssertEqual(try backend.fileURL("2026/a b.png").absoluteString, "https://cloud.example.com/remote.php/dav/files/me/aktar/2026/a%20b.png")
        XCTAssertEqual(try backend.folderURL("").absoluteString, "https://cloud.example.com/remote.php/dav/files/me/aktar/")
        XCTAssertEqual(try backend.folderURL("2026/11/").absoluteString, "https://cloud.example.com/remote.php/dav/files/me/aktar/2026/11/")

        // A bare host is https, and a path with a space typed as is works.
        let typed = Self.backend(endpoint: "dav.example.com/My Files")
        XCTAssertEqual(try typed.fileURL("x.txt").absoluteString, "https://dav.example.com/My%20Files/x.txt")

        let root = Self.backend(endpoint: "http://127.0.0.1:8080")
        XCTAssertEqual(try root.fileURL("a/b.txt").absoluteString, "http://127.0.0.1:8080/a/b.txt")
        XCTAssertEqual(try root.folderURL("").absoluteString, "http://127.0.0.1:8080/")
    }

    func testHTTPSIsRequiredExceptOnThisMac() {
        for allowed in ["https://dav.example.com/files", "dav.example.com", "http://localhost:8080/dav", "http://127.0.0.1:1234", "http://[::1]:8080/x", "HTTPS://Dav.Example.com"] {
            XCTAssertNil(WebDAVBackend.problem(withServerURL: allowed), allowed)
        }
        for refused in ["http://dav.example.com/files", "http://192.168.1.10/dav", "ftp://example.com", "", "https://", "https://dav.example.com:99999/", "https://user@dav.example.com/"] {
            XCTAssertNotNil(WebDAVBackend.problem(withServerURL: refused), refused)
        }
        // No request is made to an address that breaks the rule.
        XCTAssertThrowsError(try Self.backend(endpoint: "http://dav.example.com").fileURL("a.txt"))
    }

    func testParentFoldersAndListingFolders() {
        XCTAssertEqual(WebDAVBackend.parentFolders(of: "a/b/c.png"), ["a/", "a/b/"])
        XCTAssertEqual(WebDAVBackend.parentFolders(of: "c.png"), [])
        XCTAssertEqual(WebDAVBackend.parentFolders(of: "a//c.png"), ["a/"])
        XCTAssertEqual(WebDAVBackend.folder(of: ""), "")
        XCTAssertEqual(WebDAVBackend.folder(of: "a/b/"), "a/b/")
        XCTAssertEqual(WebDAVBackend.folder(of: "a/b/fo"), "a/b/")
        XCTAssertEqual(WebDAVBackend.folder(of: "fo"), "")
    }

    func testPublicURLIsThePublicBaseURLAndKey() {
        var config = Self.config(endpoint: "https://dav.example.com/files")
        config.publicBaseURL = "files.example.com/shots"
        let backend = WebDAVBackend(config: config, credentials: Self.credentials)
        XCTAssertEqual(backend.publicURL(for: "2026/a b.png")?.absoluteString, "https://files.example.com/shots/2026/a%20b.png")
    }

    // MARK: - Errors

    func testStatusesMapToErrors() {
        func error(_ status: Int, location: String? = nil, onEndpoint: Bool = false) -> StorageError? {
            WebDAVBackend.error(status: status, location: location, onEndpoint: onEndpoint) as? StorageError
        }
        XCTAssertNil(WebDAVBackend.error(status: 201, location: nil, onEndpoint: false))
        XCTAssertNil(WebDAVBackend.error(status: 207, location: nil, onEndpoint: true))
        guard case .wrongUserNameOrPassword? = error(401) else { return XCTFail("401") }
        guard case .writeNotAllowed? = error(403) else { return XCTFail("403") }
        guard case .folderNotFound? = error(404, onEndpoint: true) else { return XCTFail("404 on the endpoint") }
        guard case .outOfSpace? = error(507) else { return XCTFail("507") }
        // A redirect names where it points.
        XCTAssertTrue(error(301, location: "https://other.example.com/dav/")?.errorDescription?.contains("https://other.example.com/dav/") ?? false)
        // 404 elsewhere, 409 and the like come with their status.
        guard case .unknown(let notFound)? = error(404) else { return XCTFail("404") }
        XCTAssertTrue(notFound.contains("404"))
        guard case .unknown(let conflict)? = error(409) else { return XCTFail("409") }
        XCTAssertTrue(conflict.contains("409"))
        // 5xx and 429 are retried first, so they aren't a StorageError yet.
        for status in [500, 503, 429] {
            XCTAssertNotNil(WebDAVBackend.error(status: status, location: nil, onEndpoint: false))
            XCTAssertNil(error(status))
        }
    }

    // MARK: - PROPFIND replies

    /// Nextcloud: absolute paths, the `d:` prefix, encoded names, a 404
    /// propstat for what a folder doesn't have.
    func testNextcloudReply() throws {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
         <d:response>
          <d:href>/remote.php/dav/files/me/aktar/2026/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Wed, 25 Nov 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>/remote.php/dav/files/me/aktar/2026/My%20Shot%20%2B1.png</d:href>
          <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12345</d:getcontentlength><d:getlastmodified>Thu, 26 Nov 2026 08:30:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
         <d:response>
          <d:href>/remote.php/dav/files/me/aktar/2026/%c3%a7ay/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
         </d:response>
        </d:multistatus>
        """
        let entries = try XCTUnwrap(WebDAVListing.entries(in: Data(xml.utf8), endpointPath: "/remote.php/dav/files/me/aktar", folder: "2026/"))
        XCTAssertEqual(entries.map(\.key), ["2026/My Shot +1.png", "2026/çay/"])
        XCTAssertEqual(entries[0].size, 12345)
        XCTAssertFalse(entries[0].isFolder)
        XCTAssertEqual(entries[0].lastModified, Date(timeIntervalSince1970: 1_795_681_800))
        XCTAssertTrue(entries[1].isFolder)
    }

    /// Absolute URLs, the `D:` prefix of Apache's mod_dav and its `lp1:`
    /// properties in the same namespace, at the endpoint's root.
    func testApacheReplyWithAbsoluteURLs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
        <D:response xmlns:lp1="DAV:">
        <D:href>https://dav.example.com/files/</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>https://dav.example.com/files/notes.txt</D:href>
        <D:propstat><D:prop><lp1:resourcetype/><lp1:getcontentlength>5</lp1:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        <D:response xmlns:lp1="DAV:">
        <D:href>https://dav.example.com/files/sub</D:href>
        <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
        </D:response>
        </D:multistatus>
        """
        let entries = try XCTUnwrap(WebDAVListing.entries(in: Data(xml.utf8), endpointPath: "/files", folder: ""))
        XCTAssertEqual(entries, [
            WebDAVListing.Entry(key: "notes.txt", isFolder: false, size: 5, lastModified: nil),
            // A collection without a trailing slash is still a folder.
            WebDAVListing.Entry(key: "sub/", isFolder: true, size: 0, lastModified: nil),
        ])
    }

    /// No prefix at all (a default namespace), names not encoded, and an
    /// endpoint path that is encoded where the reply's isn't.
    func testUnprefixedReplyWithUnencodedNames() throws {
        let xml = """
        <multistatus xmlns="DAV:">
          <response><href>/My Files/</href><propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response>
          <response><href>/My Files/a b.txt</href><propstat><prop><getcontentlength>3</getcontentlength></prop></propstat></response>
        </multistatus>
        """
        let entries = try XCTUnwrap(WebDAVListing.entries(in: Data(xml.utf8), endpointPath: "/My%20Files", folder: ""))
        XCTAssertEqual(entries.map(\.key), ["a b.txt"])
        XCTAssertEqual(entries.first?.size, 3)
    }

    /// A server behind a proxy that answers with paths under another root:
    /// the folder's own entry says where its children start.
    func testReplyUnderAnotherRoot() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/internal/dav/2026/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/internal/dav/2026/x.png</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try XCTUnwrap(WebDAVListing.entries(in: Data(xml.utf8), endpointPath: "/public/aktar", folder: "2026/"))
        XCTAssertEqual(entries.map(\.key), ["2026/x.png"])
    }

    func testPropertiesOutsideDAVAreIgnored() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:" xmlns:x="urn:other">
          <d:response><d:href>/f/a.txt</d:href><d:propstat><d:prop><x:getcontentlength>999</x:getcontentlength><d:getcontentlength>7</d:getcontentlength><x:collection/></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try XCTUnwrap(WebDAVListing.entries(in: Data(xml.utf8), endpointPath: "/f", folder: ""))
        XCTAssertEqual(entries, [WebDAVListing.Entry(key: "a.txt", isFolder: false, size: 7, lastModified: nil)])
    }

    func testNotAMultistatus() {
        XCTAssertNil(WebDAVListing.entries(in: Data("<html><body>Login</body></html>".utf8), endpointPath: "/", folder: ""))
        XCTAssertNil(WebDAVListing.entries(in: Data("not xml".utf8), endpointPath: "/", folder: ""))
    }

    func testDates() {
        XCTAssertEqual(WebDAVListing.date("Thu, 26 Nov 2026 08:30:00 GMT"), Date(timeIntervalSince1970: 1_795_681_800))
        XCTAssertEqual(WebDAVListing.date("2026-11-26T08:30:00Z"), Date(timeIntervalSince1970: 1_795_681_800))
        XCTAssertNil(WebDAVListing.date("yesterday"))
    }

    // MARK: - Helpers

    private static let credentials = StorageCredentials(accessKeyId: "me", secretAccessKey: "secret", sessionToken: nil)

    private static func config(endpoint: String) -> DestinationConfig {
        DestinationConfig(
            name: "DAV", preset: .webdav, accountID: nil, endpoint: endpoint, region: "", bucket: "",
            publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}.{ext}", forcePathStyle: false, isDefault: false
        )
    }

    private static func backend(endpoint: String) -> WebDAVBackend {
        WebDAVBackend(config: config(endpoint: endpoint), credentials: credentials)
    }
}
