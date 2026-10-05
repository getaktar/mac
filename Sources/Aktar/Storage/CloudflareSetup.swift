import CryptoKit
import Foundation

/// "Set Up Cloudflare R2": one API token, made from a link that fills in
/// its permissions, is all it takes. With it Aktar finds the account,
/// creates the bucket, turns on a public link (r2.dev or a domain on
/// Cloudflare) and derives the S3 keys: an R2 token's ID is the access key
/// and the SHA-256 of its value the secret
/// (https://developers.cloudflare.com/r2/api/tokens/). The token itself
/// isn't kept; only the derived keys go to the Keychain.
enum CloudflareSetup {
    enum SetupError: LocalizedError {
        case rejected(String)
        case noResponse(String)
        case inactiveToken

        var errorDescription: String? {
            switch self {
            case .rejected(let message): return message
            case .noResponse(let message): return String(localized: "Cloudflare didn\u{2019}t answer. \(message)")
            case .inactiveToken: return String(localized: "This token isn\u{2019}t active. Create a new one with the button above.")
            }
        }
    }

    struct Account: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Zone: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// The Cloudflare page that creates the token, with R2 (to create the
    /// bucket and upload) and zone read (to list domains for public links)
    /// already chosen.
    static var tokenURL: URL {
        let permissions = #"[{"key":"workers_r2","type":"edit"},{"key":"zone","type":"read"}]"#
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: permissions),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: "Aktar"),
        ]
        return components.url!
    }

    /// The token's ID, which is also its S3 access key ID.
    static func verify(token: String) async throws -> String {
        let result = try await request("user/tokens/verify", token: token)
        guard let object = result as? [String: Any], let id = object["id"] as? String else {
            throw SetupError.rejected(String(localized: "Cloudflare refused the request."))
        }
        guard (object["status"] as? String ?? "active") == "active" else { throw SetupError.inactiveToken }
        return id
    }

    static func accounts(token: String) async throws -> [Account] {
        let result = try await request("accounts?per_page=50", token: token)
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Account(id: id, name: item["name"] as? String ?? id)
        }
    }

    static func buckets(account: String, token: String) async throws -> [String] {
        let result = try await request("accounts/\(account)/r2/buckets?per_page=1000", token: token)
        let list = (result as? [String: Any])?["buckets"] as? [[String: Any]] ?? []
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    static func createBucket(_ name: String, account: String, token: String) async throws {
        _ = try await request("accounts/\(account)/r2/buckets", token: token, method: "POST", body: ["name": name])
    }

    /// Turns on the bucket's r2.dev address and returns it as a base URL.
    static func enablePublicDevURL(bucket: String, account: String, token: String) async throws -> String {
        let result = try await request(
            "accounts/\(account)/r2/buckets/\(bucket)/domains/managed",
            token: token, method: "PUT", body: ["enabled": true]
        )
        guard let domain = (result as? [String: Any])?["domain"] as? String, !domain.isEmpty else {
            throw SetupError.rejected(String(localized: "Cloudflare didn\u{2019}t return the bucket\u{2019}s r2.dev address."))
        }
        return "https://\(domain)"
    }

    /// The account's active domains, for a public link like files.example.com.
    static func zones(account: String, token: String) async throws -> [Zone] {
        let result = try await request("zones?account.id=\(account)&status=active&per_page=50", token: token)
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return Zone(id: id, name: name)
        }
        .sorted { $0.name < $1.name }
    }

    /// The domains already connected to the bucket.
    static func customDomains(bucket: String, account: String, token: String) async throws -> [String] {
        let result = try await request("accounts/\(account)/r2/buckets/\(bucket)/domains/custom", token: token)
        let list = (result as? [String: Any])?["domains"] as? [[String: Any]] ?? []
        return list.compactMap { $0["domain"] as? String }
    }

    /// Connects `domain` (on `zone`) to the bucket. Cloudflare adds the DNS
    /// record and certificate; it takes a few minutes to become active.
    static func attachDomain(_ domain: String, zone: Zone, bucket: String, account: String, token: String) async throws {
        _ = try await request(
            "accounts/\(account)/r2/buckets/\(bucket)/domains/custom",
            token: token, method: "POST",
            body: ["domain": domain, "zoneId": zone.id, "enabled": true, "minTLS": "1.2"]
        )
    }

    /// The S3 keys an R2 token stands for.
    static func credentials(tokenID: String, token: String) -> StorageCredentials {
        let digest = SHA256.hash(data: Data(token.utf8))
        let secret = digest.map { String(format: "%02x", $0) }.joined()
        return StorageCredentials(accessKeyId: tokenID, secretAccessKey: secret, sessionToken: nil)
    }

    /// A bucket name Cloudflare accepts: 3 to 63 lowercase letters, digits
    /// and hyphens, starting and ending with a letter or digit.
    static func isValidBucketName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil
    }

    /// A host name inside `zone`: the zone itself or a subdomain of it.
    static func isValidDomain(_ domain: String, in zone: Zone) -> Bool {
        let host = domain.lowercased()
        guard host == zone.name || host.hasSuffix("." + zone.name) else { return false }
        return host.range(of: "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", options: .regularExpression) != nil
    }

    // MARK: - Requests

    private static let api = URL(string: "https://api.cloudflare.com/client/v4/")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Cloudflare answers `{"success": bool, "errors": [{"message"}], "result": …}`;
    /// this returns `result`.
    private static func request(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        guard let url = URL(string: path, relativeTo: api) else {
            throw SetupError.rejected(String(localized: "Cloudflare refused the request."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do {
            data = try await session.data(for: request).0
        } catch {
            throw SetupError.noResponse(error.localizedDescription)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard object?["success"] as? Bool == true else {
            let errors = object?["errors"] as? [[String: Any]] ?? []
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: " ")
            throw SetupError.rejected(message.isEmpty ? String(localized: "Cloudflare refused the request.") : message)
        }
        return object?["result"]
    }
}
