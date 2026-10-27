import Foundation
import Security

/// API tokens the user pasted for servers that need one, in the login Keychain keyed by
/// endpoint. (Tokens Hearth can read from a server's own environment are never stored.)
public enum TokenStore {
    private static let service = "ai.hearth.api-token"

    public static func token(for endpoint: Endpoint) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.description,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setToken(_ token: String?, for endpoint: Endpoint) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.description,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Hearth: process-compose token for \(endpoint.description)"
        SecItemAdd(item as CFDictionary, nil)
    }
}
