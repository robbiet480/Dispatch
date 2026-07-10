import Foundation
import Security

/// Keychain storage for the webhook secret (PR #12 review must-fix): the
/// secret is a credential AND the AES key source, so it must not sit as
/// plaintext in App Group UserDefaults (world-readable within the group
/// container and included in device backups).
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available after the
/// first unlock (foreground drains never run before one) and never migrates
/// to another device via backup — consistent with the config being
/// deliberately device-local.
///
/// No keychain access group: only the APP process signs/encrypts; the
/// widget-extension process only enqueues report IDs and never needs the
/// secret.
enum WebhookSecretStore {
    private static let service = "io.robbie.Dispatch.webhook"
    private static let account = "webhook-secret"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Writes (upserting) the secret; an empty string deletes the item.
    static func write(_ secret: String) {
        guard !secret.isEmpty else {
            delete()
            return
        }
        let data = Data(secret.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Silent one-time migration: TestFlight users may already have a
    /// secret in (group) UserDefaults from the pre-review build — move it
    /// into the Keychain and remove the plaintext copy. A secret already in
    /// the Keychain wins (defaults leftovers are just deleted).
    static func migrateFromDefaultsIfNeeded(_ defaults: UserDefaults, key: String) {
        guard let legacy = defaults.string(forKey: key) else { return }
        if read() == nil, !legacy.isEmpty {
            write(legacy)
        }
        defaults.removeObject(forKey: key)
    }
}
