import Foundation

/// A ShareX custom uploader (`.sxcu`) for a URL shortener, read into a
/// custom definition (docs/short-links.md, "Custom HTTP and .sxcu"). Only
/// what maps onto the definition schema one to one is taken: anything else
/// refuses the import rather than being guessed at. Secrets found in the
/// headers, parameters and body move into the token, and the definition
/// says `{token}` there instead, so they never end up in the destination's
/// settings.
struct ShareXImport: Equatable {
    /// Where a secret was found, for the consent screen.
    enum SecretLocation: Hashable {
        case header(String)
        case query(String)
        case body(String)
    }

    /// The configuration's own name, if it has one.
    var name: String?
    /// A custom definition; its create path is the whole request URL
    /// without the query, which is in `query`.
    var definition: ShortLinkDefinition
    /// The secret taken out of the configuration, if any.
    var token: String?
    var secretLocations: [SecretLocation]
    /// The host the token (and every link) is sent to.
    var host: String
    var method: String
    /// The request URL with its query, secrets as {token}.
    var endpoint: String
    var usesHTTP: Bool
    /// It has a DeletionURL that isn't a simple request, so links made
    /// with it can't be deleted from Aktar.
    var deletionSkipped: Bool

    /// Larger than any real configuration.
    static let maxFileSize = 256 * 1024

    /// Reads a `.sxcu` file. `allowInsecureHTTP`: the user turned on
    /// "Allow insecure HTTP"; without it an http:// request is refused.
    static func parse(_ data: Data, allowInsecureHTTP: Bool) throws -> ShareXImport {
        guard data.count <= maxFileSize,
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareXImportError.invalid
        }
        // ShareX writes these keys in PascalCase; case doesn't matter here.
        var root: [String: Any] = [:]
        for (key, value) in raw { root[key.lowercased()] = value }

        let types = (root["destinationtype"] as? String ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard types.contains("urlshortener") else { throw ShareXImportError.notShortener }

        if let regexes = root["regexlist"] as? [Any], !regexes.isEmpty {
            throw ShareXImportError.unsupported(String(localized: "regular expressions"))
        }
        if let fileField = root["fileformname"] as? String, !fileField.isEmpty {
            throw ShareXImportError.unsupported(String(localized: "a file form field"))
        }
        if let responseType = root["responsetype"] as? String, !["", "text", "json"].contains(responseType.lowercased()) {
            throw ShareXImportError.unsupported(responseType)
        }

        let method = ((root["requestmethod"] ?? root["requesttype"]) as? String ?? "POST").uppercased()
        guard ShortLinkProviders.customMethods.contains(method) else {
            throw ShareXImportError.unsupported(method)
        }

        // The request URL, with any query it carries as parameters.
        guard let rawURL = (root["requesturl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else {
            throw ShareXImportError.missingRequestURL
        }
        var base = try map(rawURL)
        var query: [String: String] = [:]
        if let mark = base.firstIndex(of: "?") {
            for (name, value) in formPairs(String(base[base.index(after: mark)...])) { query[name] = value }
            base = String(base[..<mark])
        }
        if let hash = base.firstIndex(of: "#") { base = String(base[..<hash]) }
        // A placeholder can be in the path, never in the host.
        guard let components = URLComponents(string: base.replacingOccurrences(of: "{url}", with: "aktarplaceholder")),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains("aktarplaceholder") else {
            throw ShareXImportError.missingRequestURL
        }
        let usesHTTP = scheme == "http"
        if usesHTTP, !allowInsecureHTTP { throw ShareXImportError.insecure }

        for (name, value) in try strings(root["parameters"], what: "Parameters") { query[name] = try map(value) }
        let headers = try strings(root["headers"], what: "Headers").mapValues(map)

        // The body.
        let bodyKind = (root["body"] as? String ?? "").lowercased()
        let arguments = try strings(root["arguments"], what: "Arguments").mapValues(map)
        var body: JSONValue?
        var bodyType: ShortLinkRequest.BodyType?
        switch bodyKind {
        case "json":
            bodyType = .json
            if let text = root["data"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), case .object = value else {
                    throw ShareXImportError.unsupported(String(localized: "a JSON body that isn\u{2019}t an object"))
                }
                body = try mapValue(value)
            } else {
                body = .object(arguments.mapValues(JSONValue.string))
            }
        case "formurlencoded":
            bodyType = .form
            var fields = arguments
            if let text = root["data"] as? String, !text.isEmpty {
                for (name, value) in formPairs(text) { fields[name] = try map(value) }
            }
            body = .object(fields.mapValues(JSONValue.string))
        case "", "none":
            // Older configurations sent their arguments in the query.
            for (name, value) in arguments { query[name] = value }
        default:
            throw ShareXImportError.unsupported(root["body"] as? String ?? bodyKind)
        }

        // The answer.
        guard let shortUrlPath = try responsePath(root["url"] as? String) else {
            throw ShareXImportError.responseNotJSON
        }
        let errorPath = (try? responsePath(root["errormessage"] as? String)) ?? nil

        // Secrets out, {token} in.
        var extractor = SecretExtractor()
        let safeHeaders = try Dictionary(uniqueKeysWithValues: headers.map { name, value in
            (name, try extractor.take(value, name: name, at: .header(name)))
        })
        let safeQuery = try Dictionary(uniqueKeysWithValues: query.map { name, value in
            (name, try extractor.take(value, name: name, at: .query(name)))
        })
        let safeBody = try body.map { try extractor.take($0, path: nil) }

        // The deletion URL, when it's the same request for every link with
        // the link's id from the answer in it.
        var delete: ShortLinkRequest?
        var idPath: String?
        var deletionSkipped = false
        if let deletion = (root["deletionurl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !deletion.isEmpty {
            if let simple = try? simpleDeletion(deletion, extractor: &extractor) {
                delete = simple.request
                idPath = simple.idPath
            } else {
                deletionSkipped = true
            }
        }

        let definition = ShortLinkDefinition(
            id: ShortLinkProviders.customID,
            name: String(localized: "Custom HTTP"),
            kind: .custom,
            baseUrl: nil,
            needsDomain: false,
            auth: nil,
            create: ShortLinkRequest(
                method: method,
                path: base,
                query: safeQuery.isEmpty ? nil : safeQuery,
                headers: safeHeaders.isEmpty ? nil : safeHeaders,
                body: safeBody,
                bodyType: bodyType,
                errorPath: errorPath,
                shortUrlPath: shortUrlPath,
                idPath: idPath
            ),
            delete: delete,
            capabilities: ShortLinkProviders.customCapabilities(canDelete: delete != nil)
        )
        let shownQuery = safeQuery.keys.sorted().map { "\($0)=\(safeQuery[$0] ?? "")" }.joined(separator: "&")
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShareXImport(
            name: name?.isEmpty == false ? name : nil,
            definition: definition,
            token: extractor.token,
            secretLocations: extractor.locations,
            host: host,
            method: method,
            endpoint: shownQuery.isEmpty ? base : base + "?" + shownQuery,
            usesHTTP: usesHTTP,
            deletionSkipped: deletionSkipped
        )
    }

    // MARK: - ShareX syntax

    /// ShareX's syntax functions (`{name}` or `{name:argument}`, and
    /// `$name$` in files from before ShareX 13). Other braces and dollar
    /// signs are just text, as they are to ShareX.
    static let syntaxNames: Set<String> = [
        "input", "json", "xml", "regex", "response", "responseurl", "header", "filename", "name",
        "random", "select", "prompt", "inputbox", "outputbox", "base64", "link", "file",
    ]

    /// The ShareX syntax in `value`: each function as written, and its name.
    static func syntax(in value: String) throws -> [(token: String, name: String)] {
        var found: [(String, String)] = []
        for pattern in [#"\{([A-Za-z]+)(:[^{}]*)?\}"#, #"\$([A-Za-z]+)(:[^$]*)?\$"#] {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                guard let whole = Range(match.range, in: value), let name = Range(match.range(at: 1), in: value) else { continue }
                let lowered = value[name].lowercased()
                if syntaxNames.contains(lowered) { found.append((String(value[whole]), lowered)) }
            }
        }
        return found
    }

    /// ShareX's input (`{input}`, or `$input$` in older files) as `{url}`.
    /// Any other function of its syntax (`{filename}`, `{random}`,
    /// `{select}`, `{prompt}`, `{response}`, `{regex}`, `{json}` in a
    /// request ...) means a request Aktar can't make the same way.
    static func map(_ value: String) throws -> String {
        for (token, _) in try syntax(in: value) where !["{input}", "$input$"].contains(token.lowercased()) {
            throw ShareXImportError.unsupported(token)
        }
        return value
            .replacingOccurrences(of: "{input}", with: "{url}", options: .caseInsensitive)
            .replacingOccurrences(of: "$input$", with: "{url}", options: .caseInsensitive)
    }

    /// "a=1&b=2", percent-decoded.
    private static func formPairs(_ text: String) -> [(String, String)] {
        text.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return (name, parts.count > 1 ? parts[1] : "")
        }
    }

    private static func mapValue(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .string(let string): return .string(try map(string))
        case .object(let fields): return .object(try fields.mapValues(mapValue))
        case .array(let items): return .array(try items.map(mapValue))
        default: return value
        }
    }

    /// `{json:data.link}` or `$json:data.link$` as `data.link`; nil for
    /// none at all. JSONPath's `$.` and `[0]` are read as dot paths. Any
    /// other answer (plain text, a link put together around the value)
    /// can't be read.
    static func responsePath(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        // {response}, {regex:...} and the like transform the answer.
        for (token, name) in try syntax(in: value) where name != "json" {
            throw ShareXImportError.unsupported(token)
        }
        let inner: Substring
        if value.lowercased().hasPrefix("{json:"), value.hasSuffix("}") {
            inner = value.dropFirst(6).dropLast()
        } else if value.lowercased().hasPrefix("$json:"), value.hasSuffix("$") {
            inner = value.dropFirst(6).dropLast()
        } else {
            throw ShareXImportError.responseNotJSON
        }
        guard let path = dotPath(String(inner)) else { throw ShareXImportError.responseNotJSON }
        return path
    }

    static func dotPath(_ jsonPath: String) -> String? {
        var path = jsonPath.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("$.") { path.removeFirst(2) } else if path.hasPrefix("$") { path.removeFirst() }
        path = path.replacingOccurrences(of: #"\[(\d+)\]"#, with: ".$1", options: .regularExpression)
        path = path.replacingOccurrences(of: #"\[['"]([^'"\]]+)['"]\]"#, with: ".$1", options: .regularExpression)
        while path.hasPrefix(".") { path.removeFirst() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !path.isEmpty, !path.contains(".."), path.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return path
    }

    /// A dictionary of strings (Headers, Parameters, Arguments); numbers
    /// and booleans are written out.
    private static func strings(_ value: Any?, what: String) throws -> [String: String] {
        guard let value, !(value is NSNull) else { return [:] }
        guard let object = value as? [String: Any] else { throw ShareXImportError.invalid }
        var result: [String: String] = [:]
        for (key, item) in object {
            switch item {
            case let string as String: result[key] = string
            case let number as NSNumber: result[key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            default: throw ShareXImportError.unsupported(what)
            }
        }
        return result
    }

    /// `https://s.example.com/delete/{json:id}`: a GET (ShareX opens it in
    /// the browser) to a fixed URL with one value of the answer in it,
    /// which becomes the link's id. The headers aren't sent along.
    private static func simpleDeletion(_ value: String, extractor: inout SecretExtractor) throws -> (request: ShortLinkRequest, idPath: String) {
        let regex = try NSRegularExpression(pattern: #"\{json:([^{}]+)\}|\$json:([^$]+)\$"#, options: .caseInsensitive)
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard matches.count == 1, let match = matches.first, let whole = Range(match.range, in: value) else {
            throw ShareXImportError.invalid
        }
        let captured = [1, 2].compactMap { Range(match.range(at: $0), in: value) }.first.map { String(value[$0]) }
        guard let captured, let idPath = dotPath(captured) else { throw ShareXImportError.invalid }
        var template = value.replacingCharacters(in: whole, with: "{id}")
        _ = try map(template.replacingOccurrences(of: "{id}", with: ""))
        var query: [String: String] = [:]
        if let mark = template.firstIndex(of: "?") {
            for (name, value) in formPairs(String(template[template.index(after: mark)...])) {
                query[name] = try extractor.take(value, name: name, at: .query(name))
            }
            template = String(template[..<mark])
        }
        guard let components = URLComponents(string: template.replacingOccurrences(of: "{id}", with: "aktarplaceholder")),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, !host.contains("aktarplaceholder") else {
            throw ShareXImportError.invalid
        }
        let path = template
        return (ShortLinkRequest(method: "GET", path: path, query: query.isEmpty ? nil : query), idPath)
    }
}

/// Finds values that look like secrets and swaps them for `{token}`. A
/// definition has one token, so a second, different secret refuses the
/// import.
struct SecretExtractor {
    private(set) var token: String?
    private(set) var locations: [ShareXImport.SecretLocation] = []

    private static let schemes = ["bearer ", "basic ", "token ", "bot "]

    /// Whether a header, parameter or field called `name` holds a secret.
    static func isSecretName(_ name: String) -> Bool {
        let name = name.lowercased()
        if ["token", "secret", "signature", "password", "passwd", "auth"].contains(where: name.contains) { return true }
        return name.contains("key") && !name.contains("keyword")
    }

    mutating func take(_ value: String, name: String, at location: ShareXImport.SecretLocation) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("{url}"), !trimmed.contains("{token}") else { return value }
        let lowered = trimmed.lowercased()
        let scheme = Self.schemes.first { lowered.hasPrefix($0) && trimmed.count > $0.count }
        guard scheme != nil || Self.isSecretName(name) else { return value }
        let prefix = scheme.map { String(trimmed.prefix($0.count)) } ?? ""
        let secret = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard !secret.isEmpty else { return value }
        if let token, token != secret { throw ShareXImportError.multipleSecrets }
        token = secret
        if !locations.contains(location) { locations.append(location) }
        return prefix + "{token}"
    }

    /// The string values of a body, by their key (`data.apiKey` for a
    /// nested one).
    mutating func take(_ value: JSONValue, path: String?) throws -> JSONValue {
        switch value {
        case .string(let string):
            guard let path else { return value }
            let name = path.split(separator: ".").last.map(String.init) ?? path
            return .string(try take(string, name: name, at: .body(path)))
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, field) in fields {
                result[key] = try take(field, path: path.map { "\($0).\(key)" } ?? key)
            }
            return .object(result)
        case .array(let items):
            return .array(try items.map { try take($0, path: path) })
        default:
            return value
        }
    }
}

enum ShareXImportError: LocalizedError, Equatable {
    case invalid
    case notShortener
    case missingRequestURL
    case responseNotJSON
    case insecure
    case multipleSecrets
    /// What it uses, as ShareX writes it or described.
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalid:
            return String(localized: "This isn\u{2019}t a ShareX custom uploader (.sxcu) file.")
        case .notShortener:
            return String(localized: "This ShareX configuration isn\u{2019}t a URL shortener.")
        case .missingRequestURL:
            return String(localized: "This ShareX configuration has no valid request URL.")
        case .responseNotJSON:
            return String(localized: "Aktar can only read the short link as one value of a JSON answer, such as {json:link}.")
        case .insecure:
            return String(localized: "This configuration sends requests over http://. Turn on \u{201C}Allow insecure HTTP\u{201D} to import it anyway.")
        case .multipleSecrets:
            return String(localized: "This configuration has more than one secret. Aktar keeps one token per destination.")
        case .unsupported(let feature):
            return String(localized: "Aktar can\u{2019}t import this configuration: it uses \(feature).")
        }
    }
}
