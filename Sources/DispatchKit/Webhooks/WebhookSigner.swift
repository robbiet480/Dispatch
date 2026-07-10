import CryptoKit
import Foundation

/// Optional HMAC signing for webhook deliveries (plan 24). If the user set
/// a secret, every request carries `X-Dispatch-Signature: sha256=<hex>` —
/// the hex HMAC-SHA256 of the body AS SENT (encrypt-then-MAC: when payload
/// encryption is on, the signature covers the encrypted envelope bytes).
/// No secret → no header.
public enum WebhookSigner {
    public static let headerName = "X-Dispatch-Signature"

    /// `"sha256=<lowercase hex HMAC-SHA256>"` — verified against a python3
    /// `hmac` reference vector in WebhookTests (session crypto rule).
    public static func signatureHeader(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Optional payload encryption on top of signing (plan 24 amendment,
/// Robbie 2026-07-09). AES-256-GCM with a key derived from the shared
/// secret via HKDF-SHA256 (salt `io.robbie.Dispatch.webhook`, info
/// `payload-encryption`, 32 bytes). The body becomes the envelope
/// `{"algorithm":"aes-256-gcm","data":"<base64 combined>","encrypted":true}`
/// (sorted keys), where `data` is `AES.GCM.SealedBox.combined`
/// (nonce ‖ ciphertext ‖ tag). Verified against a python `cryptography`
/// reference in WebhookTests; the receiver decrypt recipe ships in
/// docs/webhooks.md.
public enum WebhookCrypto {
    public static let hkdfSalt = "io.robbie.Dispatch.webhook"
    public static let hkdfInfo = "payload-encryption"
    public static let algorithm = "aes-256-gcm"

    struct Envelope: Codable {
        var encrypted: Bool
        var algorithm: String
        var data: String
    }

    public enum CryptoError: Error {
        case malformedEnvelope
        case unsupportedAlgorithm(String)
    }

    /// HKDF-SHA256(secret) → 32-byte AES key.
    public static func key(secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                               salt: Data(hkdfSalt.utf8),
                               info: Data(hkdfInfo.utf8),
                               outputByteCount: 32)
    }

    /// Derived key bytes as lowercase hex — test hook for the python
    /// reference-vector comparison.
    static func keyHex(secret: String) -> String {
        key(secret: secret).withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Encrypts `payload` and returns the JSON envelope bytes to send.
    /// `nonce` is injectable for deterministic tests only; production
    /// callers omit it and get a fresh random nonce per delivery.
    public static func encrypt(_ payload: Data, secret: String,
                               nonce: AES.GCM.Nonce? = nil) throws -> Data {
        let sealed = try AES.GCM.seal(payload, using: key(secret: secret),
                                      nonce: nonce ?? AES.GCM.Nonce())
        guard let combined = sealed.combined else {
            // combined is only nil for non-standard nonce sizes; ours is
            // always the 12-byte default.
            throw CryptoError.malformedEnvelope
        }
        let envelope = Envelope(encrypted: true, algorithm: algorithm,
                                data: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Opens an envelope produced by `encrypt` (or by the documented
    /// receiver recipe run in reverse) — used by tests and available to a
    /// future import path.
    public static func decrypt(envelope envelopeData: Data, secret: String) throws -> Data {
        let envelope = try JSONDecoder().decode(Envelope.self, from: envelopeData)
        guard envelope.encrypted else { throw CryptoError.malformedEnvelope }
        guard envelope.algorithm == algorithm else {
            throw CryptoError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard let combined = Data(base64Encoded: envelope.data) else {
            throw CryptoError.malformedEnvelope
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key(secret: secret))
    }
}
