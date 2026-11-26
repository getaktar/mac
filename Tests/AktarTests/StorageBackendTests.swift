import XCTest

/// The storage backend layer (docs/storage-backends.md): every preset's
/// kind and capabilities, and the factory that makes its backend. Until
/// other kinds land, every preset is S3 and nothing may change for it.
final class StorageBackendTests: XCTestCase {
    func testEveryPresetIsS3() {
        for preset in ProviderPreset.allCases {
            XCTAssertEqual(preset.kind, .s3, preset.rawValue)
            XCTAssertEqual(Self.destination(preset).kind, .s3, preset.rawValue)
        }
    }

    func testS3PresetsCanDoEverythingTheyDidBefore() {
        for preset in ProviderPreset.allCases {
            let capabilities = Self.destination(preset).capabilities
            XCTAssertTrue(capabilities.list, preset.rawValue)
            XCTAssertTrue(capabilities.copy, preset.rawValue)
            XCTAssertTrue(capabilities.multipart, preset.rawValue)
            XCTAssertTrue(capabilities.temporaryLinks, preset.rawValue)
            XCTAssertTrue(capabilities.expiryRules, preset.rawValue)
            XCTAssertTrue(capabilities.fileRequests, preset.rawValue)
            XCTAssertTrue(capabilities.bucketThumbnails, preset.rawValue)
            XCTAssertTrue(capabilities.sharePages, preset.rawValue)
        }
    }

    func testConditionalWritesOnlyOnR2AndAmazonS3() {
        let conditional = ProviderPreset.allCases.filter { StorageCapabilities(preset: $0).conditionalWrites }
        XCTAssertEqual(Set(conditional), [.cloudflareR2, .amazonS3])
    }

    func testCloudflareSetupOnlyOnR2() {
        let setUp = ProviderPreset.allCases.filter { StorageCapabilities(preset: $0).cloudflareSetup }
        XCTAssertEqual(setUp, [.cloudflareR2])
    }

    func testOtherKindsHaveNoS3OnlyCapabilities() {
        for kind in [StorageKind.webdav, .sftp] {
            let capabilities = StorageCapabilities(kind: kind, preset: .customS3)
            XCTAssertTrue(capabilities.list)
            XCTAssertTrue(capabilities.copy)
            XCTAssertTrue(capabilities.bucketThumbnails)
            XCTAssertTrue(capabilities.sharePages)
            XCTAssertFalse(capabilities.conditionalWrites)
            XCTAssertFalse(capabilities.multipart)
            XCTAssertFalse(capabilities.temporaryLinks)
            XCTAssertFalse(capabilities.expiryRules)
            XCTAssertFalse(capabilities.fileRequests)
            XCTAssertFalse(capabilities.cloudflareSetup)
        }
    }

    func testFactoryMakesAnS3BackendForEveryPreset() {
        for preset in ProviderPreset.allCases {
            let config = Self.destination(preset)
            let backend = StorageBackends.make(config: config, credentials: Self.credentials)
            XCTAssertTrue(backend is S3Provider, preset.rawValue)
            XCTAssertEqual(backend.config, config, preset.rawValue)
            XCTAssertNotNil(backend.s3(for: \.temporaryLinks), preset.rawValue)
            XCTAssertNotNil(StorageBackends.s3(config: config, credentials: Self.credentials, for: \.expiryRules), preset.rawValue)
            XCTAssertEqual(backend.s3(for: \.cloudflareSetup) != nil, preset == .cloudflareR2, preset.rawValue)
        }
    }

    func testPublicURLGoesUnderThePublicBaseURL() {
        let backend = StorageBackends.make(config: Self.destination(.minIO), credentials: Self.credentials)
        XCTAssertEqual(backend.publicURL(for: "2026/11/a b.png")?.absoluteString, "https://files.example.com/2026/11/a%20b.png")
    }

    private static let credentials = StorageCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: nil)

    private static func destination(_ preset: ProviderPreset) -> DestinationConfig {
        DestinationConfig(
            name: "Test", preset: preset, accountID: nil, endpoint: "https://s3.example.com", region: preset.defaultRegion,
            bucket: "bucket", publicBaseURL: "https://files.example.com", objectPathTemplate: "{filename}.{ext}",
            forcePathStyle: preset.defaultForcePathStyle, isDefault: false
        )
    }
}
