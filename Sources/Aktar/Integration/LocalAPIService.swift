import Foundation
import Observation
import Security

/// Owns the local API that companion tools (the Raycast extension) talk to.
/// It's off until the user turns it on in Settings > Integrations or
/// approves a connection request, listens on 127.0.0.1 only, and every
/// request needs the token, which lives in the Keychain.
@MainActor
@Observable
final class LocalAPIService {
    static let shared = LocalAPIService()
    static let defaultPort: UInt16 = 47913

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var token: String = ""

    var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            restart()
        }
    }

    var port = LocalAPIService.storedPort() {
        didSet {
            guard port != oldValue else { return }
            UserDefaults.standard.set(Int(port), forKey: Keys.port)
            restart()
        }
    }

    private static func storedPort() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Keys.port)
        return (1024...65535).contains(stored) ? UInt16(stored) : defaultPort
    }

    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private var router: LocalAPIRouter?

    private enum Keys {
        static let enabled = "localAPIEnabled"
        static let port = "localAPIPort"
    }

    private init() {}

    func configure(appState: AppState) {
        router = LocalAPIRouter(appState: appState)
        token = TokenStore.load() ?? ""
        restart()
    }

    /// Replaces the token; anything already connected has to reconnect.
    func regenerateToken() {
        token = TokenStore.generate()
        TokenStore.save(token)
        restart()
    }

    private func restart() {
        server?.stop()
        server = nil
        guard isEnabled, let router else {
            status = .off
            return
        }
        if token.isEmpty {
            token = TokenStore.generate()
            TokenStore.save(token)
        }
        let server = LocalHTTPServer(port: port, token: token) { request in
            await router.handle(request)
        }
        do {
            try server.start { [weak self] state in
                Task { @MainActor in
                    guard let self, self.server === server else { return }
                    switch state {
                    case .starting: self.status = .starting
                    case .ready: self.status = .running
                    case .failed(let message): self.status = .failed(message)
                    }
                }
            }
            self.server = server
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// The API token is a secret like storage credentials, so it's kept in the
/// Keychain under its own service rather than in UserDefaults.
private enum TokenStore {
    private static let service = "com.getaktar.mac.local-api"
    private static let account = "token"

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Never fall back to the zeroed buffer; the system RNG behind
            // SystemRandomNumberGenerator is cryptographically secure too.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
