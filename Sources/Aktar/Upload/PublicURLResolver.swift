import Foundation

/// Separated from uploading: publicURL = publicBaseURL + objectKey.
/// The S3 upload endpoint and the public serving URL are never assumed to be the same host.
enum PublicURLResolver {
    static func resolve(baseURL: String, objectKey: String) -> URL {
        var base = normalizedBase(baseURL)
        if base.hasSuffix("/") { base.removeLast() }

        let encodedKey = objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        return URL(string: "\(base)/\(encodedKey)") ?? URL(string: base)!
    }

    /// Users commonly enter a bare domain (e.g. "img.example.com") in
    /// Settings without a scheme. Assume HTTPS in that case, since a
    /// schemeless URL can't actually be loaded by URLSession or opened by
    /// NSWorkspace.
    private static func normalizedBase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "https://\(trimmed)"
    }
}
