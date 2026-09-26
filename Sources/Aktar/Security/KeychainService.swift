import Foundation
import Security

struct StorageCredentials: Codable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
}

enum KeychainError: Error, LocalizedError {
    case notFound
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound: return "No credentials found in Keychain for this destination."
        case .unhandled(let status): return "Keychain error (\(status))."
        }
    }
}

/// Secrets (Access Key ID, Secret Access Key, session token) live only in the
/// macOS Keychain, never in UserDefaults, plists, JSON config, or the SQLite history.
enum KeychainService {
    private static let service = "com.getaktar.mac.credentials"

    static func save(_ credentials: StorageCredentials, for destinationID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let account = destinationID.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    static func load(for destinationID: UUID) throws -> StorageCredentials {
        let account = destinationID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw KeychainError.notFound }
            throw KeychainError.unhandled(status)
        }
        return try JSONDecoder().decode(StorageCredentials.self, from: data)
    }

    static func delete(for destinationID: UUID) throws {
        let account = destinationID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
