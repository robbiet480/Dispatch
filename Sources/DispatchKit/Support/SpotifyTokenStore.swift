import Foundation
import Security

/// Minimal Keychain wrapper for the Spotify App Remote access token (plan 26).
/// A token is a credential → generic-password item, this-device-only
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable).
/// Tokens NEVER touch UserDefaults or synced storage. Grep-verified there was
/// no existing Keychain helper in the repo to reuse (2026-07-10).
///
/// Lives in the kit (not the app target) so the delete-idempotency contract
/// is unit-testable; the injectable service name keeps tests off the app's
/// real item. Deleted on Delete All Data via
/// `SpotifyController.clearCredentialForDataWipe()` — Keychain items survive
/// even app deletion, so the wipe path must clear it explicitly (the
/// WebhookManager.clearSecretForDataWipe precedent).
public struct SpotifyTokenStore: Sendable {
    private let service: String
    private let account = "access-token"

    public init(service: String = "io.robbie.Dispatch.spotify") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns whether the token actually persisted — callers must not claim
    /// a connected state on a failed save (PR #25 review).
    @discardableResult
    public func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        return status == errSecSuccess
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Idempotent: deleting a missing item is a no-op (errSecItemNotFound is
    /// swallowed by design), so wipe paths may call this unconditionally.
    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
