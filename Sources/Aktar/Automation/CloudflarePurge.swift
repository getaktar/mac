import Foundation

/// Clears a replaced file from Cloudflare's cache, so its link shows the new
/// version right away. Optional per destination: a zone ID and an API token
/// that only needs Zone > Cache Purge.
enum CloudflarePurge {
    enum PurgeError: LocalizedError {
        case rejected(String)
        case noResponse(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message): return message
            case .noResponse(let message): return String(localized: "Cloudflare didn\u{2019}t answer. \(message)")
            }
        }
    }

    private static let api = URL(string: "https://api.cloudflare.com/client/v4/")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Whether `destination` clears Cloudflare's cache: a zone ID and a token.
    static func isSetUp(_ destination: DestinationConfig, credentials: StorageCredentials?) -> Bool {
        !(destination.cloudflareZoneId ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(credentials?.cloudflareToken ?? "").isEmpty
    }

    static func purge(urls: [URL], zoneID: String, token: String) async throws {
        guard !urls.isEmpty else { return }
        let zone = zoneID.trimmingCharacters(in: .whitespaces)
        guard let endpoint = URL(string: "zones/\(zone)/purge_cache", relativeTo: api),
              zone.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw PurgeError.rejected(String(localized: "The Cloudflare zone ID isn\u{2019}t valid."))
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["files": urls.map(\.absoluteString)])
        try await send(request)
    }

    /// Check in the destination form: whether Cloudflare accepts the token.
    static func verify(token: String) async throws {
        var request = URLRequest(url: URL(string: "user/tokens/verify", relativeTo: api)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try await send(request)
    }

    /// Cloudflare answers `{"success": bool, "errors": [{"message"}]}`.
    private static func send(_ request: URLRequest) async throws {
        let data: Data
        do {
            data = try await session.data(for: request).0
        } catch {
            throw PurgeError.noResponse(error.localizedDescription)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard object?["success"] as? Bool == true else {
            let errors = object?["errors"] as? [[String: Any]] ?? []
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: " ")
            throw PurgeError.rejected(message.isEmpty ? String(localized: "Cloudflare refused the request.") : message)
        }
    }
}
