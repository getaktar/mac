import Foundation

/// Where a watched folder's webhook may post: anywhere over https, and
/// over plain http only to this Mac or the local network, where there's
/// no one in between to read the upload's details.
enum WatchHookAddress {
    enum Verdict: Equatable {
        case allowed
        /// Not an http or https URL with a host.
        case invalid
        /// http:// to an address outside this Mac and the local network.
        case insecure
    }

    static func check(_ target: String) -> Verdict {
        guard let url = URL(string: target.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return .invalid }
        if scheme == "https" { return .allowed }
        return isLocal(host) ? .allowed : .insecure
    }

    /// Loopback, private (RFC 1918), link-local and unique local
    /// addresses, "localhost" and mDNS ".local" names.
    static func isLocal(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if let v4 = ipv4(host) {
            switch (v4[0], v4[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if host.contains(":") {
            if host == "::1" { return true }
            guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
                  let value = UInt16(first, radix: 16) else { return false }
            // fc00::/7 (unique local) and fe80::/10 (link-local).
            return value & 0xFE00 == 0xFC00 || value & 0xFFC0 == 0xFE80
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return numbers.count == 4 ? numbers : nil
    }

    /// Whether a redirect from `original` to `target` may be followed: only
    /// to the same host (and port), and never down to an http address the
    /// hook couldn't have been set to.
    static func mayFollowRedirect(from original: URL, to target: URL) -> Bool {
        guard let from = original.host?.lowercased(), let to = target.host?.lowercased(), from == to,
              original.port == target.port else { return false }
        return check(target.absoluteString) == .allowed
    }
}
