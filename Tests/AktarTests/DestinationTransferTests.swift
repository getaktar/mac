import XCTest

/// The shared test vectors (made with Node's WebCrypto) that the Windows
/// and mobile apps check too, so all of them read each other's links.
final class DestinationTransferTests: XCTestCase {
    private let code = "K7P2-QX9M-4TRW"
    private let fullURL = "aktar://import#AQABAgMEBQYHCAkKCwwNDg-goaKjpKWmp6ipqqtb3kuNh7HmTZAAsoxnF4uSJvWbwAcgdjc8HykCZWgeykwGbFBmIzNl1Q3viSEVqd1NN5aRoH7z0vbPMhXSMtczXgNXHOZ76srLl2yVJFMp5QJQGdIkCtC5G7UPaOVIAKIqQ5npKkPWys4iGdM3lyb5puIHiV-LTGQlCm02n9N14hgmLpJGW1m2lVFisMr3qI03gEcxYSQ4ESH5OuyV2nHLx-IyxauI9iUhCEHUMZSXsJwsf3cNt8WzDgjVuNJOUmdKqD5I9k2Tw5hpHzqzxwxGJARrI0R9T8ZqSRkWWVl7LOY0tVK17CRjT_uU_c4gYZ6UVxxmYMDdVQSv5d4dFz2Otic8pfGW0jNiGSwCMTR5h8rHCn07FCNKpK_mziP0-CfUSrsdobas_LGisvfm69M3loMmmX6USbCzjLm0S0ua9AmKSank57zEvmRk2p-3BWG3LT6W0gOCa6_1MqQfwBKYMhqK2E3r-3BSV5LwjcznsOPY42_8BkPDfsacI-06LYa7ecKWkPdlIEwx7WE-HnS2TA-tfNSvxevlf6vPOA_YRECyQ1A2OHoQHj7vTAhCtsBt9QhzKCytGb3qV7uZZH1OxSwXBEeu03_MlEjbexFL_2ebcnhlgT7fu_iIpjkWchk35aNl9VjtW8wd3b9i75x-SHhX7C-_lGqjuulZFMVfLXxcFyrL2hKvag5O8kvtJ1xANK22lAK1uoFYIswA5JxXXyIppkcQo5l2PdKJCrzYToVbBRXH6FHYzVWPc3txe3wv9-2fZxZ23LRtzoUTgwoM-sdCxR2xuO-qXyREli016h8jeZMg7dGGjIV3LhSA2q1a1042lrGK25LKBuypulofHAD_3M9pqeL3yBxd9-7HvoC4qeFMbnuX_kDEQ96vnfD7YfR8fakpFLrB_5rKwvUwqXDjk-4dGN_YnFtWVmmKnDpnYrmD3SMLEwCvjun68bE6xlWak2TOWYEoAKeKxBy2PJjUrbL8cqnYpw12"
    private let minimalURL = "aktar://import#AQABAgMEBQYHCAkKCwwNDg-goaKjpKWmp6ipqqtb3kuNh7HmTZAAsoxnF4uSJvWbwAcgdjc8HykCY2sexEkIGCNmWERsoA2f-1YQqaZAM-KR1X_z2vLMQxulRNBFXgNXHOZ76srLl3KfOH8DqV0aBtQyW5nvSf1IdulSa9cqDNfjMUPAycY-CKM_l2Kvs_FeyQXUAR9PGWEsgdNp4BwpIZVOUhr41EdisZOp9Jw5lwR1dHg4ADawbqib1DHbyu0n3uDcoHJrRkbBIZfGppFzOiRT7ZLEWUyI1OFgEzkNpnoNtESI2Z9nFS3jk1cMcEx0YUxqHJo1EwgAWVdoLeZi9gK76SsoT-CpvpZqR56eTh9pNp_dDlOg_4lYUSLVrikhpa6O3GJsGSoSdkg6g9f2Em00M2ADtYjB5y3stTrUTr4a1vbn__r09ean6d4l2d9olT2WQbjB0vS4TFKM_hO9Cuf3kb_GvGVk2tivHSupPTjVjFzcZaP2NaQOnwfbdxLPnkOq7XBsVpun04vHtvTX4h2nQ1a8KNyCI6tlJZO-a8vJkKJrdl0n-kkiCVrxD2SkP5zmzO38eOaCfgfJWgvsGGcyIntXUEy8A09FoOZ441goeDiIHrruFOXHOyNclHP2dLtVPlMGzKCIDra0JXr1"
    private let newerVersionURL = "aktar://import#AgABAgMEBQYHCAkKCwwNDg-goaKjpKWmp6ipqqtb3kuNh7HmTZAAsoxnF4uSJvWbwAcgdjc8HykCZWgeykwGbFBmIzNl1Q3viSEVqd1NN5aRoH7z0vbPMhXSMtczXgNXHOZ76srLl2yVJFMp5QJQGdIkCtC5G7UPaOVIAKIqQ5npKkPWys4iGdM3lyb5puIHiV-LTGQlCm02n9N14hgmLpJGW1m2lVFisMr3qI03gEcxYSQ4ESH5OuyV2nHLx-IyxauI9iUhCEHUMZSXsJwsf3cNt8WzDgjVuNJOUmdKqD5I9k2Tw5hpHzqzxwxGJARrI0R9T8ZqSRkWWVl7LOY0tVK17CRjT_uU_c4gYZ6UVxxmYMDdVQSv5d4dFz2Otic8pfGW0jNiGSwCMTR5h8rHCn07FCNKpK_mziP0-CfUSrsdobas_LGisvfm69M3loMmmX6USbCzjLm0S0ua9AmKSank57zEvmRk2p-3BWG3LT6W0gOCa6_1MqQfwBKYMhqK2E3r-3BSV5LwjcznsOPY42_8BkPDfsacI-06LYa7ecKWkPdlIEwx7WE-HnS2TA-tfNSvxevlf6vPOA_YRECyQ1A2OHoQHj7vTAhCtsBt9QhzKCytGb3qV7uZZH1OxSwXBEeu03_MlEjbexFL_2ebcnhlgT7fu_iIpjkWchk35aNl9VjtW8wd3b9i75x-SHhX7C-_lGqjuulZFMVfLXxcFyrL2hKvag5O8kvtJ1xANK22lAK1uoFYIswA5JxXXyIppkcQo5l2PdKJCrzYToVbBRXH6FHYzVWPc3txe3wv9-2fZxZ23LRtzoUTgwoM-sdCxR2xuO-qXyREli016h8jeZMg7dGGjIV3LhSA2q1a1042lrGK25LKBuypulofHAD_3M9pqeL3yBxd9-7HvoC4qeFMbnuX_kDEQ96vnfD7YfR8fakpFLrB_5rKwvUwqXDjk-4dGN_YnFtWVmmKnDpnYrmD3SMLEwCvjun68bE6xlWak2TOWYEoAKeKxBy2PJjUrbL8cqnYpw12"
    private let newerPayloadURL = "aktar://import#AQABAgMEBQYHCAkKCwwNDg-goaKjpKWmp6ipqqtb3kuNh7LmTZAAsoxnF4uSJvWbwAcgdjc8HykCZWgeykwGbFBmIzNl1Q3viSEVqd1NN5aRoH7z0vbPMhXSMtczXgNXHOZ76srLl2yVJFMp5QJQGdIkCtC5G7UPaOVIAKIqQ5npKkPWys4iGdM3lyb5puIHiV-LTGQlCm02n9N14hgmLpJGW1m2lVFisMr3qI03gEcxYSQ4ESH5OuyV2nHLx-IyxauI9iUhCEHUMZSXsJwsf3cNt8WzDgjVuNJOUmdKqD5I9k2Tw5hpHzqzxwxGJARrI0R9T8ZqSRkWWVl7LOY0tVK17CRjT_uU_c4gYZ6UVxxmYMDdVQSv5d4dFz2Otic8pfGW0jNiGSwCMTR5h8rHCn07FCNKpK_mziP0-CfUSrsdobas_LGisvfm69M3loMmmX6USbCzjLm0S0ua9AmKSank57zEvmRk2p-3BWG3LT6W0gOCa6_1MqQfwBKYMhqK2E3r-3BSV5LwjcznsOPY42_8BkPDfsacI-06LYa7ecKWkPdlIEwx7WE-HnS2TA-tfNSvxevlf6vPOA_YRECyQ1A2OHoQHj7vTAhCtsBt9QhzKCytGb3qV7uZZH1OxSwXBEeu03_MlEjbexFL_2ebcnhlgT7fu_iIpjkWchk35aNl9VjtW8wd3b9i75x-SHhX7C-_lGqjuulZFMVfLXxcFyrL2hKvag5O8kvtJ1xANK22lAK1uoFYIswA5JxXXyIppkcQo5l2PdKJCrzYToVbBRXH6FHYzVWPc3txe3wv9-2fZxZ23LRtzoUTgwoM-sdCxR2xuO-qXyREli016h8jeZMg7dGGjIV3LhSA2q1a1042lrGK25LKBuypulofHAD_3M9pqeL3yBxd9-7HvoC4qeFMbnuX_kDEQ96vnfD7YfR8fakpFLrB_5rKwvUwqXDjk-4dGN_YnFtWVmmKnDpnYrmD3SMLEwCvjun68bE6xlWak2TOWYEoAKfyYzVVEwpjS1uRXX1MUQGF"

    func testFullVector() throws {
        let payload = try DestinationTransfer.open(fullURL, code: code)
        let destination = payload.destination
        XCTAssertEqual(destination.id, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(destination.name, "Screenshots")
        XCTAssertEqual(destination.preset, .cloudflareR2)
        XCTAssertEqual(destination.accountID, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(destination.endpoint, "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
        XCTAssertEqual(destination.region, "auto")
        XCTAssertEqual(destination.bucket, "shots")
        XCTAssertEqual(destination.publicBaseURL, "https://files.example.com")
        XCTAssertEqual(destination.objectPathTemplate, "{year}/{month}/{uuid}.{ext}")
        XCTAssertFalse(destination.forcePathStyle)
        XCTAssertFalse(destination.isDefault)
        XCTAssertEqual(destination.outputMode, .markdown)
        XCTAssertEqual(destination.expiryDays, 30)
        XCTAssertEqual(destination.temporaryLink, .hour)
        XCTAssertEqual(destination.imageMetadata, .removeAll)
        XCTAssertEqual(destination.folderUpload, .keepStructure)
        XCTAssertEqual(destination.imageProcessing, ImageProcessing(format: .webp, quality: 80, maxLongEdge: 2560))
        XCTAssertEqual(payload.credentials.accessKeyId, "EXAMPLEACCESSKEYID000")
        XCTAssertEqual(payload.credentials.secretAccessKey, "example-secret-not-real-0000000000000000")
        XCTAssertNil(payload.credentials.sessionToken)
        XCTAssertEqual(payload.customTemplate, "![{filename}]({url})")
    }

    func testMinimalVectorIsReadLeniently() throws {
        let payload = try DestinationTransfer.open(minimalURL, code: "k7p2 qx9m 4trw")
        let destination = payload.destination
        XCTAssertEqual(destination.id, UUID(uuidString: "0E984725-C51C-4BF4-9960-E1C80E27ABA0"))
        XCTAssertEqual(destination.name, "MinIO")
        XCTAssertEqual(destination.preset, .minIO)
        XCTAssertNil(destination.accountID)
        XCTAssertEqual(destination.endpoint, "http://192.168.1.10:9000")
        XCTAssertEqual(destination.region, "us-east-1")
        XCTAssertEqual(destination.publicBaseURL, "http://192.168.1.10:9000/uploads")
        XCTAssertEqual(destination.objectPathTemplate, "{uuid}.{ext}")
        XCTAssertTrue(destination.forcePathStyle)
        // "bogus" isn't an output mode, and "heic" isn't a format, which
        // drops the whole image processing setting.
        XCTAssertNil(destination.outputMode)
        XCTAssertNil(destination.imageProcessing)
        XCTAssertNil(destination.expiryDays)
        XCTAssertNil(destination.temporaryLink)
        XCTAssertNil(destination.imageMetadata)
        XCTAssertNil(destination.folderUpload)
        XCTAssertEqual(payload.credentials.accessKeyId, "minioadmin")
        XCTAssertEqual(payload.credentials.secretAccessKey, "minioadmin")
        XCTAssertNil(payload.customTemplate)
    }

    func testWrongCode() {
        XCTAssertThrowsError(try DestinationTransfer.open(fullURL, code: "K7P2QX9M4TRX")) { error in
            XCTAssertEqual(error as? DestinationTransferError, .wrongCode)
        }
        // Not a code at all: not even tried.
        XCTAssertThrowsError(try DestinationTransfer.open(fullURL, code: "K7P2-QX9M")) { error in
            XCTAssertEqual(error as? DestinationTransferError, .wrongCode)
        }
    }

    func testNewerVersion() {
        for url in [newerVersionURL, newerPayloadURL] {
            XCTAssertThrowsError(try DestinationTransfer.open(url, code: code)) { error in
                XCTAssertEqual(error as? DestinationTransferError, .newerVersion)
            }
        }
        // Turned away before a code is asked for.
        XCTAssertThrowsError(try DestinationTransfer.envelope(from: newerVersionURL)) { error in
            XCTAssertEqual(error as? DestinationTransferError, .newerVersion)
        }
    }

    func testNotAktarTransfer() {
        var inputs = ["https://example.com", "aktar://import#", "aktar://import#AAAA", "hello"]
        // A version byte of 0, at full length.
        inputs.append(DestinationTransfer.linkPrefix + DestinationTransfer.base64URLEncoded(Data(count: 64)))
        for input in inputs {
            XCTAssertThrowsError(try DestinationTransfer.envelope(from: input), input) { error in
                XCTAssertEqual(error as? DestinationTransferError, .notAktarTransfer, input)
            }
        }
    }

    func testAcceptedLinkForms() throws {
        let encoded = String(fullURL.dropFirst(DestinationTransfer.linkPrefix.count))
        for input in ["  \(fullURL)\n", "AKTAR://Import#\(encoded)", encoded] {
            XCTAssertNoThrow(try DestinationTransfer.envelope(from: input), input)
        }
        XCTAssertEqual(try DestinationTransfer.open(encoded, code: code).destination.name, "Screenshots")
    }

    func testCodeNormalization() {
        let cases: [String: String?] = [
            "k7p2 qx9m 4trw": "K7P2QX9M4TRW",
            "K7P2-QX9M-4TRW": "K7P2QX9M4TRW",
            "OIL0-0111-11AB": "0110011111AB",
            "K7P2-QX9M": nil,
            "K7P2-QX9M-4TRWX": nil,
            "K7P2-QX9M-4TRU": nil,
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DestinationTransfer.normalizeCode(input), expected, input)
        }
    }

    func testGeneratedCodes() {
        for _ in 0..<50 {
            let code = DestinationTransfer.generateCode()
            XCTAssertEqual(code.count, 12)
            XCTAssertEqual(DestinationTransfer.normalizeCode(code), code)
            XCTAssertEqual(DestinationTransfer.displayCode(code).count, 14)
        }
        XCTAssertEqual(DestinationTransfer.displayCode("K7P2QX9M4TRW"), "K7P2-QX9M-4TRW")
    }

    func testUploadsToSamePlace() throws {
        let existing = try DestinationTransfer.open(fullURL, code: code).destination
        var imported = existing
        imported.endpoint = "  0123456789ABCDEF0123456789abcdef.R2.cloudflarestorage.com/ "
        imported.bucket = " shots\n"
        imported.name = "Renamed"
        XCTAssertTrue(DestinationTransfer.uploadsToSamePlace(imported, as: existing))

        imported.bucket = "other"
        XCTAssertFalse(DestinationTransfer.uploadsToSamePlace(imported, as: existing))
        imported.bucket = "Shots"
        XCTAssertFalse(DestinationTransfer.uploadsToSamePlace(imported, as: existing))
        imported = existing
        imported.endpoint = "https://attacker.example.com"
        XCTAssertFalse(DestinationTransfer.uploadsToSamePlace(imported, as: existing))
        imported.endpoint = "http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
        XCTAssertFalse(DestinationTransfer.uploadsToSamePlace(imported, as: existing))
    }

    func testRoundTrip() throws {
        let destination = DestinationConfig(
            id: UUID(),
            name: "Builds",
            preset: .amazonS3,
            accountID: nil,
            endpoint: "https://s3.eu-west-1.amazonaws.com",
            region: "eu-west-1",
            bucket: "builds",
            publicBaseURL: "https://builds.example.com",
            objectPathTemplate: "{filename}",
            forcePathStyle: true,
            isDefault: true,
            outputMode: .custom,
            expiryDays: 7,
            temporaryLink: .day,
            imageMetadata: .keepAll,
            folderUpload: .zip,
            imageProcessing: ImageProcessing(format: .avif, quality: nil, maxLongEdge: 1280)
        )
        let credentials = StorageCredentials(accessKeyId: "id", secretAccessKey: "secret", sessionToken: "session")
        let code = DestinationTransfer.generateCode()
        let link = try DestinationTransfer.seal(.init(destination: destination, credentials: credentials, customTemplate: "<{url}>"), code: code)
        XCTAssertTrue(link.hasPrefix(DestinationTransfer.linkPrefix))
        XCTAssertFalse(link.contains(code))

        let payload = try DestinationTransfer.open(link, code: DestinationTransfer.displayCode(code).lowercased())
        var expected = destination
        // Never sent: the receiving device has its own default.
        expected.isDefault = false
        XCTAssertEqual(payload.destination, expected)
        XCTAssertEqual(payload.credentials.accessKeyId, "id")
        XCTAssertEqual(payload.credentials.secretAccessKey, "secret")
        XCTAssertEqual(payload.credentials.sessionToken, "session")
        XCTAssertEqual(payload.customTemplate, "<{url}>")

        // Every share is encrypted afresh.
        let again = try DestinationTransfer.seal(.init(destination: destination, credentials: credentials, customTemplate: nil), code: code)
        XCTAssertNotEqual(again, link)
    }

    func testCustomTemplateOnlySentForCustomOutput() throws {
        let destination = try DestinationTransfer.open(fullURL, code: code).destination
        let credentials = StorageCredentials(accessKeyId: "id", secretAccessKey: "secret", sessionToken: nil)
        let data = try DestinationTransfer.encodePayload(.init(destination: destination, credentials: credentials, customTemplate: "x"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["customTemplate"])
        let sent = try XCTUnwrap(json["destination"] as? [String: Any])
        XCTAssertNil(sent["isDefault"])
        XCTAssertNil((json["credentials"] as? [String: Any])?["sessionToken"])
    }

    func testMissingRequiredFields() {
        let valid: [String: Any] = [
            "v": 1,
            "destination": ["id": "0e984725-c51c-4bf4-9960-e1c80e27aba0", "name": "A", "preset": "customS3", "endpoint": "e", "bucket": "b", "publicBaseURL": "p"],
            "credentials": ["accessKeyId": "a", "secretAccessKey": "s"],
        ]
        func decode(_ object: [String: Any]) throws -> DestinationTransfer.Payload {
            try DestinationTransfer.decodePayload(JSONSerialization.data(withJSONObject: object))
        }
        let payload = try? decode(valid)
        XCTAssertEqual(payload?.destination.id.uuidString, "0E984725-C51C-4BF4-9960-E1C80E27ABA0")
        XCTAssertEqual(payload?.destination.region, ProviderPreset.customS3.defaultRegion)
        XCTAssertEqual(payload?.destination.objectPathTemplate, "{year}/{month}/{uuid}.{ext}")
        XCTAssertEqual(payload?.destination.forcePathStyle, false)

        for key in ["id", "name", "preset", "endpoint", "bucket", "publicBaseURL"] {
            var destination = valid["destination"] as! [String: Any]
            destination[key] = nil
            var broken = valid
            broken["destination"] = destination
            XCTAssertThrowsError(try decode(broken), key)
            destination[key] = key == "id" ? "not-a-uuid" : ""
            broken["destination"] = destination
            XCTAssertThrowsError(try decode(broken), key)
        }
        var noSecret = valid
        noSecret["credentials"] = ["accessKeyId": "a"]
        XCTAssertThrowsError(try decode(noSecret))

        var wrongTypes = valid
        var destination = valid["destination"] as! [String: Any]
        destination["temporaryLink"] = 1234
        destination["expiryDays"] = 3
        destination["forcePathStyle"] = 1
        destination["imageProcessing"] = ["format": "webp", "quality": "80", "maxLongEdge": 999]
        wrongTypes["destination"] = destination
        let lenient = try? decode(wrongTypes)
        XCTAssertNotNil(lenient)
        XCTAssertNil(lenient?.destination.temporaryLink)
        XCTAssertNil(lenient?.destination.expiryDays)
        XCTAssertEqual(lenient?.destination.forcePathStyle, false)
        XCTAssertEqual(lenient?.destination.imageProcessing, ImageProcessing(format: .webp))
    }
}
