import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the destination form's "Short Links" section edits. The token is
/// only what's typed here; empty keeps the saved one (for the same
/// provider).
struct ShortLinkFormState: Equatable {
    /// Nil is Off.
    var providerId: String?
    var endpoint = ""
    var domain = ""
    var token = ""
    var onlyLongerThan = 0
    var shortenTemporaryLinks = false
    var allowInsecureHTTP = false
    // Custom HTTP.
    var customMethod = "POST"
    var customPath = ""
    var customHeaders = ""
    var customQuery = ""
    var customBodyType: ShortLinkRequest.BodyType? = .json
    var customBody = ""
    var customShortUrlPath = ""
    var customIdPath = ""
    var customDeletePath = ""
    var customDeleteMethod = "DELETE"

    static let methods = ShortLinkProviders.customMethods
    static let deleteMethods = ["DELETE", "GET", "POST"]

    init(_ settings: ShortLinkSettings?) {
        guard let settings else {
            loadCustom(ShortLinkProviders.customTemplate)
            return
        }
        providerId = settings.providerId
        endpoint = settings.endpoint ?? ""
        domain = settings.domain ?? ""
        onlyLongerThan = settings.onlyLongerThan
        shortenTemporaryLinks = settings.shortenTemporaryLinks
        allowInsecureHTTP = settings.allowInsecureHTTP
        loadCustom(settings.custom ?? ShortLinkProviders.customTemplate)
    }

    private mutating func loadCustom(_ definition: ShortLinkDefinition) {
        let create = definition.create
        customMethod = create.method.uppercased()
        customPath = create.path
        customHeaders = (create.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        customQuery = (create.query ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        customBodyType = create.bodyType
        if let body = create.body, let data = try? JSONSerialization.data(withJSONObject: body.foundationObject, options: [.sortedKeys, .withoutEscapingSlashes]) {
            customBody = String(decoding: data, as: UTF8.self)
        }
        customShortUrlPath = create.shortUrlPath ?? ""
        customIdPath = create.idPath ?? ""
        customDeletePath = definition.delete?.path ?? ""
        customDeleteMethod = definition.delete?.method.uppercased() ?? "DELETE"
        if let query = definition.delete?.query, !query.isEmpty {
            customDeletePath += "?" + query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
        }
    }

    /// A ShareX configuration the user agreed to: the custom definition and
    /// its token, ready to save. http:// was already refused unless allowed.
    mutating func apply(_ imported: ShareXImport) {
        providerId = ShortLinkProviders.customID
        endpoint = ""
        loadCustom(imported.definition)
        token = imported.token ?? ""
    }

    var isCustom: Bool { providerId == ShortLinkProviders.customID }

    /// The definition picked, or the custom one as edited (nil while it
    /// can't be read).
    var definition: ShortLinkDefinition? {
        guard let providerId else { return nil }
        return providerId == ShortLinkProviders.customID ? try? customDefinition() : ShortLinkProviders.definition(id: providerId)
    }

    /// The custom definition from the fields, or what's wrong with them.
    func customDefinition() throws -> ShortLinkDefinition {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let path = trimmed(customPath)
        guard !path.isEmpty else { throw FormProblem(String(localized: "Enter the request\u{2019}s path or URL.")) }
        let shortUrlPath = trimmed(customShortUrlPath)
        guard !shortUrlPath.isEmpty else { throw FormProblem(String(localized: "Enter where the short link is in the answer, such as shortUrl or data.link.")) }
        var headers: [String: String] = [:]
        for line in customHeaders.split(whereSeparator: \.isNewline) where !trimmed(String(line)).isEmpty {
            guard let colon = line.firstIndex(of: ":"), !trimmed(String(line[..<colon])).isEmpty else {
                throw FormProblem(String(localized: "Put each header on its own line, as Name: value."))
            }
            headers[trimmed(String(line[..<colon]))] = trimmed(String(line[line.index(after: colon)...]))
        }
        var query: [String: String] = [:]
        for line in customQuery.split(whereSeparator: \.isNewline) where !trimmed(String(line)).isEmpty {
            let parts = line.split(separator: "=", maxSplits: 1).map { trimmed(String($0)) }
            guard let name = parts.first, !name.isEmpty else {
                throw FormProblem(String(localized: "Put each query parameter on its own line, as name=value."))
            }
            query[name] = parts.count > 1 ? parts[1] : ""
        }
        var body: JSONValue?
        if customBodyType != nil {
            let text = trimmed(customBody)
            guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object = value else {
                throw FormProblem(String(localized: "The body has to be a JSON object, such as {\"url\": \"{url}\"}."))
            }
            body = value
        }
        let deletePath = trimmed(customDeletePath)
        let idPath = trimmed(customIdPath)
        return ShortLinkDefinition(
            id: ShortLinkProviders.customID,
            name: String(localized: "Custom HTTP"),
            kind: .custom,
            baseUrl: nil,
            needsDomain: false,
            auth: nil,
            create: ShortLinkRequest(
                method: customMethod,
                path: path,
                query: query.isEmpty ? nil : query,
                headers: headers.isEmpty ? nil : headers,
                body: body,
                bodyType: customBodyType,
                shortUrlPath: shortUrlPath,
                idPath: idPath.isEmpty ? nil : idPath
            ),
            delete: deletePath.isEmpty ? nil : ShortLinkRequest(
                method: customDeleteMethod,
                path: deletePath,
                headers: headers.isEmpty || !Self.sameHost(deletePath, path) ? nil : headers
            ),
            capabilities: ShortLinkProviders.customCapabilities(canDelete: !deletePath.isEmpty && !idPath.isEmpty)
        )
    }

    /// The headers (and the token in them) go to the delete request only
    /// when it's sent where the create request is: a relative path, or a
    /// URL on the same host.
    static func sameHost(_ deletePath: String, _ createPath: String) -> Bool {
        func host(_ path: String) -> String? {
            guard path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") else { return nil }
            let rest = path.drop { $0 != "/" }.dropFirst(2)
            return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }).lowercased()
        }
        guard let deleteHost = host(deletePath) else { return true }
        return deleteHost == host(createPath)
    }

    /// The settings to save; nil when Off.
    func settings() -> ShortLinkSettings? {
        guard let providerId, let definition else { return nil }
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShortLinkSettings(
            providerId: providerId,
            endpoint: definition.usesEndpoint && !endpoint.isEmpty ? endpoint : nil,
            domain: domain.isEmpty ? nil : domain,
            custom: isCustom ? definition : nil,
            onlyLongerThan: max(0, onlyLongerThan),
            shortenTemporaryLinks: shortenTemporaryLinks && ShortLinkRules.canShortenTemporaryLinks(definition.capabilities),
            allowInsecureHTTP: allowInsecureHTTP
        )
    }

    /// Whether any address the requests go to is http://.
    var usesHTTP: Bool {
        let lowered = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("http://") || (isCustom && customPath.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://"))
    }

    /// What keeps these settings from being saved, given whether a token
    /// for this provider is already saved.
    func problem(hasSavedToken: Bool) -> String? {
        guard providerId != nil else { return nil }
        if isCustom {
            do { _ = try customDefinition() } catch { return (error as? FormProblem)?.message ?? error.localizedDescription }
        }
        guard let definition, let settings = settings() else { return nil }
        let customIsAbsolute = isCustom && customPath.lowercased().hasPrefix("http")
        if definition.usesEndpoint, !customIsAbsolute {
            do {
                guard let base = try ShortLinkRequestBuilder.baseURL(definition: definition, settings: settings) else {
                    return ShortLinkError.missingEndpoint.localizedDescription
                }
                guard URL(string: base)?.host?.isEmpty == false else { return ShortLinkError.invalidEndpoint.localizedDescription }
            } catch {
                return ShortLinkError.invalidEndpoint.localizedDescription
            }
        }
        if usesHTTP, !allowInsecureHTTP { return ShortLinkError.insecureEndpoint.localizedDescription }
        if definition.needsDomain, settings.trimmedDomain == nil { return ShortLinkError.missingDomain.localizedDescription }
        if definition.auth != nil, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasSavedToken {
            return ShortLinkError.missingToken.localizedDescription
        }
        return nil
    }

    struct FormProblem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// "Short Links" in the destination form: Off or a shortener, its address,
/// domain and key, Test, and when links are shortened.
struct ShortLinksFormSection: View {
    @Binding var state: ShortLinkFormState
    /// The provider whose token is saved for this destination, if any.
    let savedTokenProvider: String?
    /// The saved token, read only when testing.
    let savedToken: () -> String?

    @State private var test: TestState?
    /// A ShareX configuration waiting for the user's consent.
    @State private var pendingImport: ShareXImport?
    @State private var importError: String?
    /// The last import was refused for http://, so the toggle that allows
    /// it is shown.
    @State private var importNeedsInsecureHTTP = false

    private enum TestState: Equatable {
        case testing
        case passed(ShortLinkTestResult)
        case failed(String)
    }

    private var hasSavedToken: Bool {
        savedTokenProvider != nil && savedTokenProvider == state.providerId
    }

    var body: some View {
        Section {
            Picker("Shortener", selection: $state.providerId) {
                Text("Off").tag(String?.none)
                ForEach(ShortLinkProviders.builtIn) { definition in
                    Text(verbatim: definition.name).tag(String?.some(definition.id))
                }
                Text("Custom HTTP\u{2026}").tag(String?.some(ShortLinkProviders.customID))
            }
            .onChange(of: state.providerId) { test = nil }
            if state.providerId != nil {
                fields
            } else if importNeedsInsecureHTTP {
                insecureToggle
            }
            Button("Import ShareX Configuration (.sxcu)\u{2026}") { chooseShareXFile() }
        } header: {
            Text("Short Links")
        } footer: {
            footer
        }
        .sheet(item: $pendingImport) { imported in
            ShareXConsentView(imported: imported) {
                state.apply(imported)
                importNeedsInsecureHTTP = false
                test = nil
                pendingImport = nil
            } cancel: {
                pendingImport = nil
            }
        }
        .alert("Couldn\u{2019}t Import the Configuration", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// Reads a .sxcu file and asks before anything changes.
    private func chooseShareXFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sxcu"), .json].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a ShareX custom uploader for a URL shortener.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            pendingImport = try ShareXImport.parse(data, allowInsecureHTTP: state.allowInsecureHTTP)
        } catch {
            if error as? ShareXImportError == .insecure { importNeedsInsecureHTTP = true }
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private var fields: some View {
        let definition = state.definition
        if definition?.usesEndpoint ?? state.isCustom {
            TextField("Address", text: $state.endpoint, prompt: Text(verbatim: "https://s.example.com"))
        }
        if state.usesHTTP || importNeedsInsecureHTTP {
            insecureToggle
        }
        if let definition, definition.needsDomain || definition.capabilities.customDomain {
            TextField("Domain", text: $state.domain, prompt: definition.needsDomain ? Text(verbatim: "short.example.com") : Text("Optional"))
        }
        SecureField(
            state.isCustom ? LocalizedStringKey("Token") : LocalizedStringKey("API Key"),
            text: $state.token,
            prompt: hasSavedToken ? Text("Unchanged") : (definition?.auth == nil ? Text("Optional") : nil)
        )
        if state.isCustom {
            customFields
        }
        LabeledContent("Only shorten links longer than") {
            HStack(spacing: 4) {
                TextField("Only shorten links longer than", value: $state.onlyLongerThan, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("characters").foregroundStyle(.secondary)
            }
        }
        let canExpire = ShortLinkRules.canShortenTemporaryLinks(definition?.capabilities)
        Toggle("Also shorten temporary links", isOn: Binding(
            get: { state.shortenTemporaryLinks && canExpire },
            set: { state.shortenTemporaryLinks = $0 }
        ))
        .disabled(!canExpire)
        HStack {
            Button(test == .testing ? LocalizedStringKey("Testing\u{2026}") : LocalizedStringKey("Test")) { runTest() }
                .disabled(test == .testing || state.problem(hasSavedToken: hasSavedToken) != nil)
            testResult
        }
        if let problem = state.problem(hasSavedToken: hasSavedToken) {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var insecureToggle: some View {
        Toggle("Allow insecure HTTP", isOn: $state.allowInsecureHTTP)
        Text("Links and your API key are sent unencrypted over http://. Use this only on a network you trust, such as your own computer.")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var customFields: some View {
        Picker("Method", selection: $state.customMethod) {
            ForEach(ShortLinkFormState.methods, id: \.self) { Text(verbatim: $0).tag($0) }
        }
        TextField("Path or URL", text: $state.customPath, prompt: Text(verbatim: "/api/shorten"))
        TextField("Headers", text: $state.customHeaders, prompt: Text(verbatim: "Authorization: Bearer {token}"), axis: .vertical)
            .lineLimit(1...4)
        TextField("Query", text: $state.customQuery, prompt: Text("Optional"), axis: .vertical)
            .lineLimit(1...4)
        Picker("Body", selection: $state.customBodyType) {
            Text("None").tag(ShortLinkRequest.BodyType?.none)
            Text(verbatim: "JSON").tag(ShortLinkRequest.BodyType?.some(.json))
            Text("Form").tag(ShortLinkRequest.BodyType?.some(.form))
        }
        if state.customBodyType != nil {
            TextField("Body", text: $state.customBody, prompt: Text(verbatim: "{\"url\": \"{url}\"}"), axis: .vertical)
                .lineLimit(1...6)
                .font(.system(.body, design: .monospaced))
        }
        TextField("Short link in the answer", text: $state.customShortUrlPath, prompt: Text(verbatim: "data.shortUrl"))
        TextField("ID in the answer", text: $state.customIdPath, prompt: Text("Optional"))
        TextField("Delete path", text: $state.customDeletePath, prompt: Text(verbatim: "/api/links/{id}"))
        if !state.customDeletePath.trimmingCharacters(in: .whitespaces).isEmpty {
            Picker("Delete method", selection: $state.customDeleteMethod) {
                ForEach(ShortLinkFormState.deleteMethods, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .testing:
            ProgressView().controlSize(.small)
        case .passed(let result):
            if let shortUrl = result.created?.shortUrl {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text("Created \(shortUrl)").textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                    switch result.cleanup {
                    case .deleted:
                        Text("Deleted it again with the delete request.").foregroundStyle(.secondary)
                    case .failed(let message):
                        Text("Deleting it again failed: \(message)")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    case .none:
                        EmptyView()
                    }
                }
                .font(.caption)
            } else {
                Label("The shortener accepts this key", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("After each upload, the link is shortened with your own link shortener and the short link is copied. If it can\u{2019}t be, the original link is copied and you\u{2019}re told. Your links and click data stay in your infrastructure.")
            if let definition = state.definition {
                if definition.isHosted {
                    Text("This service sees every link you shorten and every click.")
                }
                if state.shortenTemporaryLinks, ShortLinkRules.canShortenTemporaryLinks(definition.capabilities) {
                    Text("Short link will expire together with the original temporary URL.")
                } else if !ShortLinkRules.canShortenTemporaryLinks(definition.capabilities) {
                    Text("This shortener can\u{2019}t expire links, so temporary links aren\u{2019}t shortened.")
                }
                if state.isCustom {
                    Text("Use {url} for the link and {token} for the token in the path, headers, query or body. The short link and ID are read from the JSON answer with dot paths, such as data.link or items.0.id; deleting needs both the delete path and the ID.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func runTest() {
        guard let settings = state.settings(), let definition = settings.definition else { return }
        let typed = state.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty && hasSavedToken ? savedToken() : typed
        let engine = ShortLinkEngine(definition: definition, settings: settings, token: token)
        test = .testing
        Task {
            do {
                test = .passed(try await engine.test())
            } catch {
                test = .failed(ShortLinkService.message(for: error, token: token))
            }
        }
    }
}

extension ShareXImport: Identifiable {
    var id: String { endpoint + (token ?? "") }
}

/// Importing a ShareX configuration is a consent screen: where the token
/// and the links go, and in which headers or parameters, before anything
/// is filled in.
struct ShareXConsentView: View {
    let imported: ShareXImport
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import ShareX Configuration").font(.headline)
            if let name = imported.name {
                Text(verbatim: name).foregroundStyle(.secondary)
            }
            if imported.token != nil {
                Text("This configuration will send your API token to **\(imported.host)**.")
            } else {
                Text("This configuration will send your links to **\(imported.host)**.")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Method").foregroundStyle(.secondary)
                    Text(verbatim: imported.method).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Endpoint").foregroundStyle(.secondary)
                    Text(verbatim: imported.endpoint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !imported.secretLocations.isEmpty {
                    GridRow {
                        Text("Token sent in").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(imported.secretLocations, id: \.self) { location in
                                Text(Self.describe(location))
                            }
                        }
                    }
                }
            }
            if imported.token != nil {
                Text("The token is kept in your Keychain with this destination\u{2019}s keys, not in its settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if imported.usesHTTP {
                Text("Links and your API key are sent unencrypted over http://. Use this only on a network you trust, such as your own computer.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if imported.deletionSkipped {
                Text("Its deletion URL isn\u{2019}t a simple request, so short links made with it can\u{2019}t be deleted from Aktar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 460)
    }

    static func describe(_ location: ShareXImport.SecretLocation) -> String {
        switch location {
        case .header(let name): return String(localized: "Header \(name)")
        case .query(let name): return String(localized: "Query parameter \(name)")
        case .body(let name): return String(localized: "Body field \(name)")
        }
    }
}
