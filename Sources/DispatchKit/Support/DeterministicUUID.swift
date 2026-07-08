import CryptoKit
import Foundation

extension UUID {
    /// RFC 4122 version-5 (SHA-1, name-based) UUID: deterministic for a given
    /// namespace + name pair. Matches the reference implementation (e.g.
    /// Python's `uuid.uuid5`), so identical inputs produce identical UUIDs on
    /// every device — required so fresh installs seed identical question IDs
    /// and iCloud sync merges rather than duplicates.
    public init(v5Namespace namespace: UUID, name: String) {
        let n = namespace.uuid
        var message = Data([
            n.0, n.1, n.2, n.3, n.4, n.5, n.6, n.7,
            n.8, n.9, n.10, n.11, n.12, n.13, n.14, n.15,
        ])
        message.append(contentsOf: Array(name.utf8))

        var digest = Array(Insecure.SHA1.hash(data: message))
        // Set version (5) in the high nibble of octet 6 and the RFC 4122
        // variant (10xx) in the top bits of octet 8.
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80

        self.init(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
