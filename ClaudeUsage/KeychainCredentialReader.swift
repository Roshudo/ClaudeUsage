import CryptoKit
import Foundation
import Security

enum KeychainCredentialError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessDenied(OSStatus)

    // A missing session and an expired one are both fixed by the same
    // single step, so the wording lives here and `ClaudeUsageError` reuses it.
    static var signInHint: String {
        String(localized: "Open Xcode's Claude assistant once – the widget picks the new session up automatically.")
    }

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

    var recoverySuggestion: String? {
        switch self {
        case .itemNotFound:
            return Self.signInHint
        case .unexpectedData, .accessDenied:
            return nil
        }
    }
}

struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?

    // Claude Code writes `expiresAt` as milliseconds since the epoch;
    // values small enough to be seconds are read as such in case that
    // ever changes.
    var expiryDate: Date? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt > 1_000_000_000_000 ? expiresAt / 1000 : expiresAt
        return Date(timeIntervalSince1970: seconds)
    }

    // Asking the API with an expired token can only earn a 401, so it's
    // worth knowing locally before spending a request on it.
    var isExpired: Bool {
        guard let expiryDate else { return false }
        return expiryDate <= Date()
    }
}

private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials
}

enum KeychainCredentialReader {
    private static let servicePrefix = "Claude Code-credentials"

    static func loadCredentials() throws -> ClaudeOAuthCredentials {
        let service = try findServiceName()
        let data = try readSecretData(forService: service)
        return try decodeCredentials(from: data)
    }

    // Identifies the stored session without keeping the token itself
    // around, so callers can tell "Claude Code has written a new session"
    // from "still the same one that just failed". Nil when the credentials
    // can't be read at all, which is a distinguishable state in its own right.
    static func currentFingerprint() -> String? {
        guard let credentials = try? loadCredentials() else { return nil }
        let digest = SHA256.hash(data: Data(credentials.accessToken.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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
