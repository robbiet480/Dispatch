import CryptoKit
import Foundation

/// CloudKit Web Services server-to-server request signing (plan 20).
///
/// Lives in DispatchKit (not the `dispatch-mod` target) so the pure signing
/// math is covered by the kit test suite — it holds no key material and never
/// imports CloudKit. Only `dispatch-mod` constructs one with a real key.
///
/// Format verified 2026-07-09 against Apple's CloudKit Web Services Reference
/// ("Composing Web Service Requests", archive documentation):
///
/// - Headers: `X-Apple-CloudKit-Request-KeyID`,
///   `X-Apple-CloudKit-Request-ISO8601Date`,
///   `X-Apple-CloudKit-Request-SignatureV1`.
/// - Message to sign: `[ISO8601 date]:[base64(SHA-256(request body))]:[subpath]`
///   where the date has no fractional seconds (e.g. `2016-01-25T22:15:43Z`)
///   and the subpath is the URL path WITHOUT the host and WITHOUT any API
///   token (e.g. `/database/1/iCloud.../development/public/records/query`).
/// - Signature: ECDSA over SHA-256 with a prime256v1 (P-256) private key —
///   openssl `dgst -sha256 -sign` equivalent — DER-encoded, then base64.
/// - Signed requests expire after 10 minutes (server clock skew matters).
public struct CKWebServicesSigner: Sendable {
    public let keyID: String
    private let privateKey: P256.Signing.PrivateKey

    /// Accepts the PEM the CloudKit Console workflow produces
    /// (`openssl ecparam -name prime256v1 -genkey` → SEC1 "EC PRIVATE KEY")
    /// as well as PKCS#8 "PRIVATE KEY" PEMs.
    public init(keyID: String, pemPrivateKey: String) throws {
        self.keyID = keyID
        self.privateKey = try P256.Signing.PrivateKey(
            pemRepresentation: pemPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// PEM of the public key — what gets pasted into CloudKit Console.
    public var publicKeyPEM: String { privateKey.publicKey.pemRepresentation }

    /// ISO8601, seconds precision, UTC `Z` suffix — the documented date shape.
    public static func iso8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// base64(SHA-256(body)) — the middle component of the message to sign.
    public static func bodyHash(_ body: Data) -> String {
        Data(SHA256.hash(data: body)).base64EncodedString()
    }

    /// `[date]:[bodyHash]:[subpath]` exactly as documented.
    public static func message(date: String, bodyHash: String, subpath: String) -> String {
        "\(date):\(bodyHash):\(subpath)"
    }

    /// base64 of the DER-encoded ECDSA-SHA256 signature over the message.
    public func signature(date: String, body: Data, subpath: String) throws -> String {
        let message = Self.message(date: date, bodyHash: Self.bodyHash(body), subpath: subpath)
        let signature = try privateKey.signature(for: Data(message.utf8))
        return signature.derRepresentation.base64EncodedString()
    }

    /// The three authentication headers for a request.
    public func headers(body: Data, subpath: String, date: Date = .init()) throws -> [String: String] {
        let dateString = Self.iso8601Date(date)
        return [
            "X-Apple-CloudKit-Request-KeyID": keyID,
            "X-Apple-CloudKit-Request-ISO8601Date": dateString,
            "X-Apple-CloudKit-Request-SignatureV1": try signature(
                date: dateString, body: body, subpath: subpath
            ),
        ]
    }

    /// Test hook: verify a base64 DER signature against a message with this
    /// signer's public key (ECDSA over SHA-256, matching `signature`).
    public func verify(signatureBase64: String, date: String, body: Data, subpath: String) -> Bool {
        guard let der = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der) else {
            return false
        }
        let message = Self.message(date: date, bodyHash: Self.bodyHash(body), subpath: subpath)
        return privateKey.publicKey.isValidSignature(signature, for: Data(message.utf8))
    }
}
