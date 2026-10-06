import Foundation

/// A link shortener described as HTTP configuration, not code: the built-in
/// ones come from `short-link-providers.json` (docs/short-link-providers.json,
/// bundled as is), a custom one is made in the destination form. The schema
/// is deliberately narrow; see docs/short-links.md.
struct ShortLinkDefinition: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case selfHosted, hosted, custom
    }

    var id: String
    var name: String
    var kind: Kind
    /// Nil: requests go to the destination's endpoint.
    var baseUrl: String?
    var needsDomain: Bool
    /// Nil for a custom definition, whose templates use `{token}` wherever
    /// the service wants it.
    var auth: ShortLinkAuth?
    var create: ShortLinkRequest
    var delete: ShortLinkRequest?
    var update: ShortLinkRequest?
    var stats: ShortLinkRequest?
    /// Authenticated and read-only. A custom definition has none: its test
    /// shortens a link.
    var test: ShortLinkRequest?
    var capabilities: ShortLinkCapabilities

    var isHosted: Bool { kind == .hosted }
    var usesEndpoint: Bool { baseUrl == nil }
}

struct ShortLinkAuth: Codable, Hashable, Sendable {
    enum AuthType: String, Codable, Sendable {
        /// The token as the value of the header `name`.
        case header
        /// `Authorization: Bearer <token>`.
        case bearer
        /// The token as the query parameter `name`.
        case query
        /// The token is "user:password", sent as HTTP basic auth.
        case basic
    }

    var type: AuthType
    var name: String?
}

/// One request of a definition. Values are templates with the placeholders
/// of `ShortLinkPlaceholder`. The extra paths only mean something on the
/// request they belong to: `shortUrlPath`/`idPath` on create,
/// `clicksPath`/`lastClickPath` on stats.
struct ShortLinkRequest: Codable, Hashable, Sendable {
    enum BodyType: String, Codable, Sendable {
        case json, form
    }

    var method: String
    /// Relative to the base URL, or a whole URL (Short.io's statistics are
    /// on another host). May carry a query string.
    var path: String
    var query: [String: String]?
    var headers: [String: String]?
    var body: JSONValue?
    var bodyType: BodyType?
    /// Where the provider's own error message is in an error response.
    var errorPath: String?
    /// Statuses outside 200-299 that still mean success, such as YOURLS's
    /// 409 for a URL it has already shortened, which comes with that link.
    var successStatuses: [Int]?
    var shortUrlPath: String?
    var idPath: String?
    var clicksPath: String?
    var lastClickPath: String?

    init(method: String, path: String, query: [String: String]? = nil, headers: [String: String]? = nil, body: JSONValue? = nil, bodyType: BodyType? = nil, errorPath: String? = nil, successStatuses: [Int]? = nil, shortUrlPath: String? = nil, idPath: String? = nil, clicksPath: String? = nil, lastClickPath: String? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.bodyType = bodyType
        self.errorPath = errorPath
        self.successStatuses = successStatuses
        self.shortUrlPath = shortUrlPath
        self.idPath = idPath
        self.clicksPath = clicksPath
        self.lastClickPath = lastClickPath
    }
}

struct ShortLinkCapabilities: Codable, Hashable, Sendable {
    /// `false` in the JSON is `.none`.
    enum Expiration: Hashable, Sendable {
        case absolute, relative, none
    }

    struct Stats: Codable, Hashable, Sendable {
        var clicks: Bool
        var lastClick: Bool
    }

    var delete: Bool
    var updateDestination: Bool
    var expiration: Expiration
    var customCode: Bool
    var customDomain: Bool
    var stats: Stats

    var supportsExpiration: Bool { expiration != .none }
    var hasStats: Bool { stats.clicks || stats.lastClick }

    private enum CodingKeys: String, CodingKey {
        case delete, updateDestination, expiration, customCode, customDomain, stats
    }

    init(delete: Bool, updateDestination: Bool, expiration: Expiration, customCode: Bool, customDomain: Bool, stats: Stats) {
        self.delete = delete
        self.updateDestination = updateDestination
        self.expiration = expiration
        self.customCode = customCode
        self.customDomain = customDomain
        self.stats = stats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        delete = try container.decode(Bool.self, forKey: .delete)
        updateDestination = try container.decode(Bool.self, forKey: .updateDestination)
        customCode = try container.decodeIfPresent(Bool.self, forKey: .customCode) ?? false
        customDomain = try container.decodeIfPresent(Bool.self, forKey: .customDomain) ?? false
        stats = try container.decodeIfPresent(Stats.self, forKey: .stats) ?? Stats(clicks: false, lastClick: false)
        if let kind = try? container.decode(String.self, forKey: .expiration) {
            switch kind {
            case "absolute": expiration = .absolute
            case "relative": expiration = .relative
            default: expiration = .none
            }
        } else {
            expiration = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(delete, forKey: .delete)
        try container.encode(updateDestination, forKey: .updateDestination)
        switch expiration {
        case .absolute: try container.encode("absolute", forKey: .expiration)
        case .relative: try container.encode("relative", forKey: .expiration)
        case .none: try container.encode(false, forKey: .expiration)
        }
        try container.encode(customCode, forKey: .customCode)
        try container.encode(customDomain, forKey: .customDomain)
        try container.encode(stats, forKey: .stats)
    }
}

/// Any JSON value, for request body templates.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// As `JSONSerialization` objects; whole numbers stay integers.
    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.foundationObject)
        case .array(let value): return value.map(\.foundationObject)
        case .null: return NSNull()
        }
    }
}

/// `DestinationConfig.shortLinks`: a destination's shortener; nil is off.
/// The token is in the Keychain with the destination's keys
/// (`StorageCredentials.shortLinkToken`), never here.
struct ShortLinkSettings: Codable, Hashable, Sendable {
    /// A built-in definition's id, or `ShortLinkProviders.customID`.
    var providerId: String
    /// The base URL of a self-hosted or custom shortener; ignored for
    /// hosted ones.
    var endpoint: String?
    /// The short domain; required for Short.io, optional elsewhere.
    var domain: String?
    /// The definition when `providerId` is custom.
    var custom: ShortLinkDefinition?
    /// Shorten only links longer than this many characters; 0 always.
    var onlyLongerThan: Int
    /// Temporary links are shortened too (only with providers that can
    /// expire a link), and the short link expires with them.
    var shortenTemporaryLinks: Bool
    /// The user chose to send requests to an http:// endpoint.
    var allowInsecureHTTP: Bool

    init(providerId: String, endpoint: String? = nil, domain: String? = nil, custom: ShortLinkDefinition? = nil, onlyLongerThan: Int = 0, shortenTemporaryLinks: Bool = false, allowInsecureHTTP: Bool = false) {
        self.providerId = providerId
        self.endpoint = endpoint
        self.domain = domain
        self.custom = custom
        self.onlyLongerThan = onlyLongerThan
        self.shortenTemporaryLinks = shortenTemporaryLinks
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    private enum CodingKeys: String, CodingKey {
        case providerId, endpoint, domain, custom, onlyLongerThan, shortenTemporaryLinks, allowInsecureHTTP
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        custom = try container.decodeIfPresent(ShortLinkDefinition.self, forKey: .custom)
        onlyLongerThan = max(0, try container.decodeIfPresent(Int.self, forKey: .onlyLongerThan) ?? 0)
        shortenTemporaryLinks = try container.decodeIfPresent(Bool.self, forKey: .shortenTemporaryLinks) ?? false
        allowInsecureHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
    }

    /// The definition these settings use, nil for an unknown provider.
    var definition: ShortLinkDefinition? {
        providerId == ShortLinkProviders.customID ? custom : ShortLinkProviders.definition(id: providerId)
    }

    var trimmedDomain: String? {
        let domain = (domain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty ? nil : domain
    }
}

/// The built-in definitions, read once from the bundled
/// `short-link-providers.json`.
enum ShortLinkProviders {
    static let customID = "custom"

    private struct File: Decodable {
        let schemaVersion: Int
        let providers: [ShortLinkDefinition]
    }

    private final class BundleToken {}

    /// In the order the destination form lists them.
    static let builtIn: [ShortLinkDefinition] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "short-link-providers", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }()

    static func decode(_ data: Data) throws -> [ShortLinkDefinition] {
        try JSONDecoder().decode(File.self, from: data).providers
    }

    static func definition(id: String) -> ShortLinkDefinition? {
        builtIn.first { $0.id == id }
    }

    /// What a new custom definition starts as: a JSON POST with the link and
    /// a bearer token.
    static var customTemplate: ShortLinkDefinition {
        ShortLinkDefinition(
            id: customID,
            name: String(localized: "Custom HTTP"),
            kind: .custom,
            baseUrl: nil,
            needsDomain: false,
            auth: nil,
            create: ShortLinkRequest(
                method: "POST",
                path: "/api/shorten",
                headers: ["Authorization": "Bearer {token}"],
                body: .object(["url": .string("{url}")]),
                bodyType: .json,
                shortUrlPath: "shortUrl"
            ),
            capabilities: customCapabilities(canDelete: false)
        )
    }

    static func customCapabilities(canDelete: Bool) -> ShortLinkCapabilities {
        ShortLinkCapabilities(
            delete: canDelete,
            updateDestination: false,
            expiration: .none,
            customCode: false,
            customDomain: false,
            stats: .init(clicks: false, lastClick: false)
        )
    }
}
