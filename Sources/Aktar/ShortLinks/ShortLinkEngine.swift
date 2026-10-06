import Foundation

/// What a definition's templates can use. A query parameter, body value or
/// header that uses one with no value is left out entirely rather than sent
/// empty; a path that does can't be built.
enum ShortLinkPlaceholder: String, CaseIterable, Sendable {
    case url, id, domain, expiresAt, expiresAtUnix, expiresInSeconds, expiresInMinutes, token

    var token: String { "{\(rawValue)}" }

    /// The expiry placeholders for `expiresAt`; none without one, or once
    /// it's less than a minute away (the shortest a relative expiry can
    /// be). Relative values are rounded down, so the short link never
    /// outlives what it points at.
    static func expiryValues(_ expiresAt: Date?, now: Date = .now) -> [ShortLinkPlaceholder: String] {
        guard let expiresAt else { return [:] }
        let seconds = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        guard seconds >= 60 else { return [:] }
        return [
            .expiresAt: iso8601(expiresAt),
            .expiresAtUnix: String(Int(expiresAt.timeIntervalSince1970.rounded(.down))),
            .expiresInSeconds: String(seconds),
            .expiresInMinutes: String(seconds / 60),
        ]
    }

    /// "2026-10-13T12:00:00+00:00": the form Shlink validates (ATOM), and
    /// ISO 8601 for everyone else.
    static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }
}

enum ShortLinkError: LocalizedError, Equatable {
    case notConfigured
    case missingEndpoint
    case invalidEndpoint
    case insecureEndpoint
    case missingDomain
    case missingToken
    case missingValue(String)
    case unsupported
    case network(String)
    case rejected(status: Int, message: String?)
    case noShortLink(path: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "This destination has no link shortener set up.")
        case .missingEndpoint:
            return String(localized: "Enter the address of your link shortener.")
        case .invalidEndpoint:
            return String(localized: "The link shortener\u{2019}s address isn\u{2019}t valid.")
        case .insecureEndpoint:
            return String(localized: "The link shortener\u{2019}s address uses http://. Turn on \u{201C}Allow insecure HTTP\u{201D} to use it anyway.")
        case .missingDomain:
            return String(localized: "Enter the short domain.")
        case .missingToken:
            return String(localized: "Enter the API key.")
        case .missingValue(let name):
            return String(localized: "The request needs a value for {\(name)}.")
        case .unsupported:
            return String(localized: "This link shortener can\u{2019}t do that.")
        case .network(let message):
            return String(localized: "The link shortener didn\u{2019}t answer. \(message)")
        case .rejected(let status, let message):
            if let message, !message.isEmpty {
                return String(localized: "The link shortener refused the request (HTTP \(status)): \(message)")
            }
            return String(localized: "The link shortener refused the request (HTTP \(status)).")
        case .noShortLink(let path):
            return String(localized: "The link shortener\u{2019}s answer has no short link at \u{201C}\(path)\u{201D}.")
        }
    }
}

/// Builds the HTTP requests of a definition and reads their answers. No
/// provider has code of its own: everything comes from the definition.
enum ShortLinkRequestBuilder {
    /// The request `request` describes, with `values` filled in. `token`
    /// goes where the definition's auth says, and wherever a template uses
    /// `{token}`.
    static func build(
        _ request: ShortLinkRequest,
        definition: ShortLinkDefinition,
        settings: ShortLinkSettings,
        values: [ShortLinkPlaceholder: String],
        token: String?
    ) throws -> URLRequest {
        var values = values.filter { !$0.value.isEmpty }
        let token = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { values[.token] = token }
        if let domain = settings.trimmedDomain, values[.domain] == nil { values[.domain] = domain }
        if definition.needsDomain, values[.domain] == nil { throw ShortLinkError.missingDomain }
        if definition.auth != nil, token.isEmpty { throw ShortLinkError.missingToken }

        // The path, with any query string it carries split off as templates.
        var pathTemplate = request.path
        var queryTemplates = request.query ?? [:]
        if let mark = pathTemplate.firstIndex(of: "?") {
            for pair in pathTemplate[pathTemplate.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                queryTemplates[name] = parts.count > 1 ? parts[1] : ""
            }
            pathTemplate = String(pathTemplate[..<mark])
        }
        let path = try fillPath(pathTemplate, values: values)

        let base: String
        let isAbsolute = path.lowercased().hasPrefix("https://") || path.lowercased().hasPrefix("http://")
        if isAbsolute {
            base = path
        } else {
            guard let root = try baseURL(definition: definition, settings: settings) else { throw ShortLinkError.missingEndpoint }
            let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
            base = trimmedRoot + (path.hasPrefix("/") || path.isEmpty ? path : "/" + path)
        }
        try checkScheme(base, settings: settings)

        var query: [(String, String)] = queryTemplates.keys.sorted().compactMap { name in
            fill(queryTemplates[name] ?? "", values: values).map { (name, $0) }
        }
        if let auth = definition.auth, auth.type == .query {
            query.append((auth.name ?? "token", token))
        }
        var urlString = base
        if !query.isEmpty {
            urlString += (base.contains("?") ? "&" : "?") + query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString), url.host != nil else { throw ShortLinkError.invalidEndpoint }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.uppercased()
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = definition.auth {
            switch auth.type {
            case .header: urlRequest.setValue(token, forHTTPHeaderField: auth.name ?? "Authorization")
            case .bearer: urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: auth.name ?? "Authorization")
            case .basic: urlRequest.setValue("Basic \(Data(token.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            case .query: break
            }
        }
        for (name, template) in request.headers ?? [:] {
            if let value = fill(template, values: values) { urlRequest.setValue(value, forHTTPHeaderField: name) }
        }

        if let body = request.body, let type = request.bodyType {
            let filled = fill(body, values: values) ?? .object([:])
            switch type {
            case .json:
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: filled.foundationObject, options: [.sortedKeys])
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            case .form:
                guard case .object(let fields) = filled else { break }
                let pairs = fields.keys.sorted().compactMap { name -> String? in
                    guard let value = fields[name]?.formValue else { return nil }
                    return "\(encode(name))=\(encode(value))"
                }
                urlRequest.httpBody = Data(pairs.joined(separator: "&").utf8)
                urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return urlRequest
    }

    /// The definition's base URL, or the destination's endpoint (https://
    /// assumed without a scheme). Nil when there's neither.
    static func baseURL(definition: ShortLinkDefinition, settings: ShortLinkSettings) throws -> String? {
        if let base = definition.baseUrl { return base }
        let endpoint = (settings.endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { return nil }
        let lowered = endpoint.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") { return endpoint }
        if endpoint.contains("://") { throw ShortLinkError.invalidEndpoint }
        return "https://" + endpoint
    }

    /// http:// only when the user allowed it; nothing but http(s).
    static func checkScheme(_ url: String, settings: ShortLinkSettings) throws {
        let lowered = url.lowercased()
        if lowered.hasPrefix("https://") { return }
        if lowered.hasPrefix("http://") {
            guard settings.allowInsecureHTTP else { throw ShortLinkError.insecureEndpoint }
            return
        }
        throw ShortLinkError.invalidEndpoint
    }

    /// `template` with the placeholders that have values filled in; nil if
    /// it uses one that has none. Braces that aren't a placeholder stay.
    static func fill(_ template: String, values: [ShortLinkPlaceholder: String]) -> String? {
        var result = template
        for placeholder in ShortLinkPlaceholder.allCases where result.contains(placeholder.token) {
            guard let value = values[placeholder] else { return nil }
            result = result.replacingOccurrences(of: placeholder.token, with: value)
        }
        return result
    }

    /// A body template filled in: a string with a placeholder that has no
    /// value drops out of its object or array (nil at the top).
    static func fill(_ template: JSONValue, values: [ShortLinkPlaceholder: String]) -> JSONValue? {
        switch template {
        case .string(let string):
            return fill(string, values: values).map(JSONValue.string)
        case .object(let fields):
            return .object(fields.compactMapValues { fill($0, values: values) })
        case .array(let items):
            return .array(items.compactMap { fill($0, values: values) })
        default:
            return template
        }
    }

    /// Path placeholders are percent-encoded as one segment each; a missing
    /// value can't be left out of a path.
    private static func fillPath(_ template: String, values: [ShortLinkPlaceholder: String]) throws -> String {
        var result = template
        for placeholder in ShortLinkPlaceholder.allCases where result.contains(placeholder.token) {
            guard let value = values[placeholder] else { throw ShortLinkError.missingValue(placeholder.rawValue) }
            result = result.replacingOccurrences(of: placeholder.token, with: encode(value))
        }
        return result
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Everything but unreserved characters encoded, so a `+` or `&` in a
    /// link survives a form body or query string.
    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
}

private extension JSONValue {
    var formValue: String? {
        switch self {
        case .string(let value): return value
        case .number: return String(describing: foundationObject)
        case .bool(let value): return value ? "true" : "false"
        case .null, .object, .array: return nil
        }
    }
}

/// Reading answers: dot paths with array indexes (`visits.data.0.date`).
enum ShortLinkResponse {
    static func value(at path: String?, in json: Any?) -> Any? {
        guard let path, !path.isEmpty, var current = json else { return nil }
        for component in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            if let object = current as? [String: Any], let next = object[component] {
                current = next
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current is NSNull ? nil : current
    }

    /// A string, or a number written out (YOURLS sends clicks as "12").
    static func string(at path: String?, in json: Any?) -> String? {
        switch value(at: path, in: json) {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func int(at path: String?, in json: Any?) -> Int? {
        switch value(at: path, in: json) {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// ISO 8601 with or without fractions, "2026-10-06 12:00:00", or epoch
    /// seconds or milliseconds.
    static func date(at path: String?, in json: Any?) -> Date? {
        switch value(at: path, in: json) {
        case let number as NSNumber:
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        case let string as String:
            return parseDate(string)
        default:
            return nil
        }
    }

    static func parseDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(identifier: "UTC")
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: string)
    }

    /// A 2xx status or one of `successStatuses`, and, when the request has
    /// a `successPath`, `successValue` (or `true`) there.
    static func isSuccess(status: Int, json: Any? = nil, request: ShortLinkRequest) -> Bool {
        guard (200..<300).contains(status) || (request.successStatuses ?? []).contains(status) else { return false }
        guard let path = request.successPath, !path.isEmpty else { return true }
        return (request.successValue ?? .bool(true)).matches(value(at: path, in: json))
    }

    /// The provider's message at the request's `errorPath`, with the token
    /// taken out in case it's echoed back.
    static func error(status: Int, json: Any?, request: ShortLinkRequest, token: String?) -> ShortLinkError {
        let message = string(at: request.errorPath, in: json).map { redact($0, token: token) }
        return .rejected(status: status, message: message.map { String($0.prefix(300)) })
    }

    static func redact(_ text: String, token: String?) -> String {
        guard let token, token.count >= 4 else { return text }
        return text.replacingOccurrences(of: token, with: "\u{2022}\u{2022}\u{2022}")
            .replacingOccurrences(of: ShortLinkRequestBuilder.encode(token), with: "\u{2022}\u{2022}\u{2022}")
    }
}

/// A short link the provider made.
struct CreatedShortLink: Equatable, Sendable {
    var shortUrl: String
    /// The provider's id or code, for delete, update and stats; nil when
    /// the definition doesn't say where it is.
    var providerId: String?
}

/// What Test did: nothing to show for a read-only test, otherwise the
/// short link it made and whether that was deleted again.
struct ShortLinkTestResult: Equatable, Sendable {
    enum Cleanup: Equatable, Sendable {
        /// Nothing to delete with (no delete request), or nothing made.
        case none
        case deleted
        /// The message, without the token.
        case failed(String)
    }

    var created: CreatedShortLink?
    var cleanup: Cleanup
}

struct ShortLinkStats: Equatable, Sendable {
    var clicks: Int?
    var lastClickAt: Date?
}

/// Where a short link is, for the requests about it.
struct ShortLinkTarget: Equatable, Sendable {
    var providerId: String
    var domain: String?
}

/// What a shortener can be asked; `ShortLinkEngine` does it over HTTP, and
/// tests use fakes.
protocol ShortLinkOperations: Sendable {
    /// `ShortLinkDefinition.id` (or "custom"): links made by another
    /// provider aren't this one's to change.
    var provider: String { get }
    var capabilities: ShortLinkCapabilities { get }
    func create(url: String, expiresAt: Date?) async throws -> CreatedShortLink
    func delete(_ target: ShortLinkTarget) async throws
    func update(_ target: ShortLinkTarget, url: String) async throws
    func stats(_ target: ShortLinkTarget) async throws -> ShortLinkStats
}

protocol ShortLinkTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// One shortener over HTTP: a definition, the destination's settings and
/// its token. Nothing is logged; errors never contain the token.
struct ShortLinkEngine: ShortLinkOperations {
    let definition: ShortLinkDefinition
    let settings: ShortLinkSettings
    let token: String?
    var transport: ShortLinkTransport = URLSessionShortLinkTransport.shared

    var provider: String { settings.providerId }
    var capabilities: ShortLinkCapabilities { definition.capabilities }

    func create(url: String, expiresAt: Date?) async throws -> CreatedShortLink {
        var values = ShortLinkPlaceholder.expiryValues(definition.capabilities.supportsExpiration ? expiresAt : nil)
        values[.url] = url
        let json = try await perform(definition.create, values: values)
        let path = definition.create.shortUrlPath ?? ""
        guard let shortUrl = ShortLinkResponse.string(at: path, in: json),
              let parsed = URL(string: shortUrl), parsed.scheme != nil else {
            throw ShortLinkError.noShortLink(path: path)
        }
        return CreatedShortLink(shortUrl: shortUrl, providerId: ShortLinkResponse.string(at: definition.create.idPath, in: json))
    }

    func delete(_ target: ShortLinkTarget) async throws {
        guard let request = definition.delete, definition.capabilities.delete else { throw ShortLinkError.unsupported }
        _ = try await perform(request, values: values(for: target))
    }

    func update(_ target: ShortLinkTarget, url: String) async throws {
        guard let request = definition.update, definition.capabilities.updateDestination else { throw ShortLinkError.unsupported }
        var values = values(for: target)
        values[.url] = url
        _ = try await perform(request, values: values)
    }

    func stats(_ target: ShortLinkTarget) async throws -> ShortLinkStats {
        guard let request = definition.stats, definition.capabilities.hasStats else { throw ShortLinkError.unsupported }
        let json = try await perform(request, values: values(for: target))
        return ShortLinkStats(
            clicks: definition.capabilities.stats.clicks ? ShortLinkResponse.int(at: request.clicksPath, in: json) : nil,
            lastClickAt: definition.capabilities.stats.lastClick ? ShortLinkResponse.date(at: request.lastClickPath, in: json) : nil
        )
    }

    /// The Test button: the definition's read-only request. A custom
    /// definition has none, so it shortens https://getaktar.com/ and gives
    /// back the short link, then deletes it again when it has a delete
    /// request (which tests that too).
    func test() async throws -> ShortLinkTestResult {
        if let request = definition.test {
            _ = try await perform(request, values: [:])
            return ShortLinkTestResult(created: nil, cleanup: .none)
        }
        let created = try await create(url: "https://getaktar.com/", expiresAt: nil)
        guard definition.delete != nil, definition.capabilities.delete else {
            return ShortLinkTestResult(created: created, cleanup: .none)
        }
        guard let id = created.providerId else {
            return ShortLinkTestResult(created: created, cleanup: .failed(ShortLinkError.missingValue(ShortLinkPlaceholder.id.rawValue).localizedDescription))
        }
        do {
            try await delete(ShortLinkTarget(providerId: id, domain: settings.trimmedDomain))
            return ShortLinkTestResult(created: created, cleanup: .deleted)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ShortLinkTestResult(created: created, cleanup: .failed(ShortLinkResponse.redact(message, token: token)))
        }
    }

    private func values(for target: ShortLinkTarget) -> [ShortLinkPlaceholder: String] {
        var values: [ShortLinkPlaceholder: String] = [.id: target.providerId]
        if let domain = target.domain, !domain.isEmpty { values[.domain] = domain }
        return values
    }

    /// Sends the request; the parsed JSON answer on success.
    private func perform(_ request: ShortLinkRequest, values: [ShortLinkPlaceholder: String]) async throws -> Any? {
        let urlRequest = try ShortLinkRequestBuilder.build(request, definition: definition, settings: settings, values: values, token: token)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as ShortLinkError {
            throw error
        } catch {
            throw ShortLinkError.network(ShortLinkResponse.redact(error.localizedDescription, token: token))
        }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard ShortLinkResponse.isSuccess(status: response.statusCode, json: json, request: request) else {
            throw ShortLinkResponse.error(status: response.statusCode, json: json, request: request, token: token)
        }
        return json
    }
}

/// An ephemeral session that doesn't follow redirects (a redirect could
/// carry the token to another host) and gives up after 20 seconds.
final class URLSessionShortLinkTransport: NSObject, ShortLinkTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = URLSessionShortLinkTransport()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
