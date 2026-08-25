import Foundation
import Security

enum KeychainCredentialError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessDenied(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return String(localized: "No Claude credentials found in the Keychain.")
        case .unexpectedData:
            return String(localized: "The credentials stored in the Keychain have an unknown format.")
        case .accessDenied(let status):
            return String(localized: "Keychain access was denied (\(status)).")
        }
    }
}

struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
}

private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials
}

enum KeychainCredentialReader {
    private static let servicePrefix = "Claude Code-credentials"

    static func loadAccessToken() throws -> String {
        let service = try findServiceName()
        let data = try readSecretData(forService: service)
        return try decodeCredentials(from: data).accessToken
    }

    private static func findServiceName() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainCredentialError.itemNotFound
        }

        guard let match = items.first(where: { entry in
            (entry[kSecAttrService as String] as? String)?.hasPrefix(servicePrefix) == true
        }), let service = match[kSecAttrService as String] as? String else {
            throw KeychainCredentialError.itemNotFound
        }

        return service
    }

    private static func readSecretData(forService service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainCredentialError.accessDenied(status)
        }
        return data
    }

    private static func decodeCredentials(from data: Data) throws -> ClaudeOAuthCredentials {
        if let wrapper = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data) {
            return wrapper.claudeAiOauth
        }
        if let flat = try? JSONDecoder().decode(ClaudeOAuthCredentials.self, from: data) {
            return flat
        }
        throw KeychainCredentialError.unexpectedData
    }
}
