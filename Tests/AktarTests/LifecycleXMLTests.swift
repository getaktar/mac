import XCTest

/// The bucket lifecycle configuration Aktar reads and writes for expiring
/// uploads. A PUT replaces the bucket's whole configuration, so the rules
/// that aren't Aktar's must come back exactly as they were, and anything
/// that can't be read completely must stop the write.
final class LifecycleXMLTests: XCTestCase {
    private static let ns = #"xmlns="http://s3.amazonaws.com/doc/2006-03-01/""#

    /// R2's default rule: no `Filter`, which a typed decoder rejects.
    private static let r2AbortRule = """
    <Rule><ID>Default Multipart Abort Rule</ID><Status>Enabled</Status>\
    <AbortIncompleteMultipartUpload><DaysAfterInitiation>7</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule>
    """

    private static func configuration(_ rules: String...) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?>"# + "<LifecycleConfiguration \(ns)>" + rules.joined() + "</LifecycleConfiguration>"
    }

    private static func aktarRule(days: Int, status: String = "Enabled") -> String {
        "<Rule><ID>aktar-expire-\(days)d</ID><Filter><Prefix>tmp/\(days)d/</Prefix></Filter>"
            + "<Status>\(status)</Status><Expiration><Days>\(days)</Days></Expiration></Rule>"
    }

    private static var allAktarRules: [String] { UploadExpiry.options.map { aktarRule(days: $0) } }

    // MARK: - Reading

    func testReadsRulesWithAndWithoutFilter() throws {
        let xml = Self.configuration(
            Self.r2AbortRule,
            "<Rule><ID>logs</ID><Prefix>logs/</Prefix><Status>Disabled</Status><Expiration><Days>90</Days></Expiration></Rule>",
            Self.aktarRule(days: 7)
        )
        let rules = try XCTUnwrap(LifecycleXML.configurationRules(in: xml))
        XCTAssertEqual(rules.count, 3)

        XCTAssertEqual(rules[0].id, "Default Multipart Abort Rule")
        XCTAssertNil(rules[0].prefix)
        XCTAssertNil(rules[0].expirationDays)

        // The legacy top-level Prefix.
        XCTAssertEqual(rules[1].prefix, "logs/")
        XCTAssertEqual(rules[1].status, "Disabled")
        XCTAssertEqual(rules[1].expirationDays, 90)

        XCTAssertEqual(rules[2], LifecycleXML.Rule(
            id: "aktar-expire-7d", prefix: "tmp/7d/", status: "Enabled", expirationDays: 7,
            raw: String(Self.aktarRule(days: 7).dropFirst("<Rule>".count).dropLast("</Rule>".count))
        ))
    }

    func testEmptyFilterAndEscapedValues() throws {
        let xml = Self.configuration(
            "<Rule><ID>a &amp; b</ID><Filter/><Status> Enabled </Status></Rule>",
            "<Rule><ID>tagged</ID><Filter><And><Prefix>x/</Prefix><Tag><Key>k</Key><Value>v</Value></Tag></And></Filter><Status>Enabled</Status></Rule>"
        )
        let rules = try XCTUnwrap(LifecycleXML.configurationRules(in: xml))
        XCTAssertEqual(rules.map(\.id), ["a & b", "tagged"])
        // An empty filter covers the whole bucket.
        XCTAssertNil(rules[0].prefix)
        // Values are trimmed.
        XCTAssertEqual(rules[0].status, "Enabled")
        XCTAssertEqual(rules[1].prefix, "x/")
    }

    func testAnEmptyConfigurationHasNoRules() {
        XCTAssertEqual(LifecycleXML.configurationRules(in: Self.configuration()), [])
    }

    func testAnythingButACompleteConfigurationIsRefused() {
        // A proxy's page, another document, an error.
        XCTAssertNil(LifecycleXML.configurationRules(in: "<html><body>Rule</body></html>"))
        XCTAssertNil(LifecycleXML.configurationRules(in: "<Error><Code>AccessDenied</Code></Error>"))
        XCTAssertNil(LifecycleXML.configurationRules(in: ""))
        // A rule that never closes.
        XCTAssertNil(LifecycleXML.configurationRules(in: Self.configuration("<Rule><ID>broken</ID>")))
        // Namespace prefixes aren't followed.
        let prefixed = "<s3:LifecycleConfiguration><s3:Rule><s3:ID>x</s3:ID></s3:Rule></s3:LifecycleConfiguration>"
        XCTAssertNil(LifecycleXML.configurationRules(in: prefixed))
        // Two configurations in one reply.
        XCTAssertNil(LifecycleXML.configurationRules(in: Self.configuration() + Self.configuration()))
    }

    func testRulesIsntRule() throws {
        let xml = Self.configuration("<Rule><ID>a</ID><Rules>not a rule</Rules><Status>Enabled</Status></Rule>")
        XCTAssertEqual(try XCTUnwrap(LifecycleXML.configurationRules(in: xml)).map(\.id), ["a"])
    }

    // MARK: - Writing

    func testMergeKeepsOtherRulesExactlyAndAddsAllOfAktars() throws {
        let existing = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(Self.r2AbortRule)))
        XCTAssertFalse(LifecycleXML.isInPlace(existing))
        XCTAssertEqual(LifecycleXML.missingDurations(existing), UploadExpiry.options)

        let merged = try XCTUnwrap(LifecycleXML.merged(existing))
        XCTAssertTrue(merged.contains(Self.r2AbortRule), "the bucket's own rule must be sent back untouched")
        for days in UploadExpiry.options {
            XCTAssertTrue(merged.contains(Self.aktarRule(days: days)))
        }

        let reread = try XCTUnwrap(LifecycleXML.configurationRules(in: merged))
        XCTAssertTrue(LifecycleXML.isInPlace(reread))
        XCTAssertEqual(reread.count, 1 + UploadExpiry.options.count)
    }

    func testMergeReplacesOutdatedAktarRules() throws {
        // One disabled, one with the wrong number of days, the rest missing.
        let existing = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(
            Self.aktarRule(days: 1, status: "Disabled"),
            "<Rule><ID>aktar-expire-7d</ID><Filter><Prefix>tmp/7d/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>3</Days></Expiration></Rule>"
        )))
        XCTAssertEqual(LifecycleXML.missingDurations(existing), UploadExpiry.options)

        let merged = try XCTUnwrap(LifecycleXML.merged(existing))
        let reread = try XCTUnwrap(LifecycleXML.configurationRules(in: merged))
        XCTAssertEqual(reread.count, UploadExpiry.options.count, "older versions are replaced, not kept beside the new ones")
        XCTAssertTrue(LifecycleXML.isInPlace(reread))
    }

    func testNothingIsWrittenWhenTheRulesAreInPlace() throws {
        let existing = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(
            Self.r2AbortRule, Self.allAktarRules.joined()
        )))
        XCTAssertTrue(LifecycleXML.isInPlace(existing))
        XCTAssertEqual(LifecycleXML.missingDurations(existing), [])
        XCTAssertNil(LifecycleXML.merged(existing))
    }

    func testRemovingLeavesOtherRules() throws {
        let existing = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(
            Self.r2AbortRule, Self.allAktarRules.joined()
        )))
        let xml = try XCTUnwrap(LifecycleXML.removingAktarRules(existing))
        XCTAssertTrue(xml.contains(Self.r2AbortRule))
        XCTAssertEqual(try XCTUnwrap(LifecycleXML.configurationRules(in: xml)).map(\.id), ["Default Multipart Abort Rule"])
    }

    func testRemovingOnlyAktarsRulesDeletesTheConfiguration() throws {
        let onlyOurs = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(Self.allAktarRules.joined())))
        // An empty string means DELETE: S3 doesn't take an empty configuration.
        XCTAssertEqual(LifecycleXML.removingAktarRules(onlyOurs), "")

        let none = try XCTUnwrap(LifecycleXML.configurationRules(in: Self.configuration(Self.r2AbortRule)))
        XCTAssertNil(LifecycleXML.removingAktarRules(none), "nothing to remove, nothing to write")
        XCTAssertNil(LifecycleXML.removingAktarRules([]))
    }

    // MARK: - Errors

    func testErrorCodeAndMessage() {
        let body = "<?xml version=\"1.0\"?><Error><Code>NoSuchLifecycleConfiguration</Code><Message>The lifecycle configuration does not exist</Message></Error>"
        let error = LifecycleXML.error(in: body)
        XCTAssertEqual(error.code, "NoSuchLifecycleConfiguration")
        XCTAssertEqual(error.message, "The lifecycle configuration does not exist")

        let empty = LifecycleXML.error(in: "")
        XCTAssertNil(empty.code)
        XCTAssertNil(empty.message)
    }
}
