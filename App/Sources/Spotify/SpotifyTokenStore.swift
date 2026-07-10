import Foundation
import Security

/// Minimal Keychain wrapper for the Spotify App Remote access token (plan 26).
/// A token is a credential → generic-password item, this-device-only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable).
/// Tokens NEVER touch UserDefaults or synced storage. Grep-verified there was
/// no existing Keychain helper in the repo to reuse (2026-07-10).
enum SpotifyTokenStore {
    private static let service = "io.robbie.Dispatch.spotify"
    private static let account = "access-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
