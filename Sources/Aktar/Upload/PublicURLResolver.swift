import Foundation

/// Separated from uploading: publicURL = publicBaseURL + objectKey.
/// The S3 upload endpoint and the public serving URL are never assumed to be the same host.
enum PublicURLResolver {
    /// Nil when `baseURL` isn't a usable http(s) address (see
    /// `isValidBaseURL`), which the destination form and the transfer
    /// import turn away, so this only happens to one saved before that.
    static func resolve(baseURL: String, objectKey: String) -> URL? {
        guard isValidBaseURL(baseURL) else { return nil }
        var base = normalizedBase(baseURL)
        if base.hasSuffix("/") { base.removeLast() }

        let encodedKey = objectKey
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        return URL(string: "\(base)/\(encodedKey)") ?? URL(string: base)
    }

    /// Whether `raw` (a bare domain counts, as https) is an http or https
    /// address with a host and, if it has one, a port from 1 to 65535.
    static func isValidBaseURL(_ raw: String) -> Bool {
        let normalized = normalizedBase(raw)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: normalized),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return false }
        // A port that isn't a number doesn't parse at all.
        if let port = components.port, !(1...65_535).contains(port) { return false }
        return true
    }

    /// The host of `baseURL` when it's a domain of the user's own, not one
    /// the provider made: the endpoint's host (or a bucket under it),
    /// r2.dev, or an S3, Backblaze or DigitalOcean bucket host. Nil
    /// otherwise.
    static func ownDomainHost(baseURL: String, endpoint: String) -> String? {
        guard isValidBaseURL(baseURL),
              let host = URLComponents(string: normalizedBase(baseURL))?.host?.lowercased() else { return nil }
        let providerDomains = ["r2.dev", "amazonaws.com", "backblazeb2.com", "digitaloceanspaces.com"]
        var providerHosts = providerDomains
        if let endpointHost = URLComponents(string: normalizedBase(endpoint))?.host?.lowercased(), !endpointHost.isEmpty {
            providerHosts.append(endpointHost)
        }
        if providerHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        return host
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
