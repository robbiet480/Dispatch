import CryptoKit
import Foundation
import Testing
@testable import DispatchKit

// Test-only P-256 key (freshly generated for these tests, never used against
// a real container) in the SEC1 PEM shape the CloudKit Console workflow
// produces via `openssl ecparam -name prime256v1 -genkey`.
private let testPEM = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIIjmxYssNAM0mGXKBG/8whfujk5p0q4cdIGi4tUVr7L/oAoGCCqGSM49
AwEHoUQDQgAENQaFSRSImmCAys4tb9FNdW85Ke+89vExox3liUadqCW9wmX1fzKf
Kl/7Pq0qWjeuWUrVJBVtP9X+EfOb5mSoGg==
-----END EC PRIVATE KEY-----
"""

// MARK: - Documented message format (unit test vectors)

@Test func bodyHashMatchesKnownSHA256Vectors() {
    // SHA-256 of the empty string is a published constant.
    #expect(CKWebServicesSigner.bodyHash(Data()) == "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
    // Independent recomputation for a non-empty body.
    let body = Data(#"{"query":{"recordType":"SubmittedQuestion"}}"#.utf8)
    #expect(CKWebServicesSigner.bodyHash(body) == Data(SHA256.hash(data: body)).base64EncodedString())
}

@Test func iso8601DateHasSecondsPrecisionUTC() {
    #expect(CKWebServicesSigner.iso8601Date(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    #expect(CKWebServicesSigner.iso8601Date(Date(timeIntervalSince1970: 1_453_760_143)) == "2016-01-25T22:15:43Z")
    // No fractional seconds even for sub-second instants.
    #expect(CKWebServicesSigner.iso8601Date(Date(timeIntervalSince1970: 1.75)) == "1970-01-01T00:00:01Z")
}

@Test func messageToSignConcatenatesDateHashSubpathWithColons() {
    // The documented shape: [date]:[base64(sha256(body))]:[subpath], subpath
    // WITHOUT host or API token.
    let subpath = "/database/1/iCloud.io.robbie.Dispatch/development/public/records/query"
    let message = CKWebServicesSigner.message(
        date: "2016-01-25T22:15:43Z",
        bodyHash: CKWebServicesSigner.bodyHash(Data()),
        subpath: subpath
    )
    #expect(message == "2016-01-25T22:15:43Z:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:\(subpath)")
}

// MARK: - ECDSA signature (P-256 / SHA-256 / DER / base64)

@Test func signatureVerifiesWithPublicKeyAndIsDEREncoded() throws {
    let signer = try CKWebServicesSigner(keyID: "test-key-id", pemPrivateKey: testPEM)
    let body = Data(#"{"operations":[]}"#.utf8)
    let subpath = "/database/1/iCloud.io.robbie.Dispatch/development/public/records/modify"
    let date = "2026-07-09T12:00:00Z"

    let signature = try signer.signature(date: date, body: body, subpath: subpath)
    let der = try #require(Data(base64Encoded: signature))
    #expect(der.first == 0x30, "ECDSA signature must be a DER SEQUENCE")

    // Round trip through CryptoKit's verifier over the exact message bytes.
    #expect(signer.verify(signatureBase64: signature, date: date, body: body, subpath: subpath))
    // Any component change must invalidate it.
    #expect(!signer.verify(signatureBase64: signature, date: "2026-07-09T12:00:01Z", body: body, subpath: subpath))
    #expect(!signer.verify(signatureBase64: signature, date: date, body: Data(), subpath: subpath))
    #expect(!signer.verify(signatureBase64: signature, date: date, body: body, subpath: subpath + "x"))
}

@Test func headersCarryTheThreeDocumentedNames() throws {
    let signer = try CKWebServicesSigner(keyID: "abc123", pemPrivateKey: testPEM)
    let date = Date(timeIntervalSince1970: 1_453_760_143)
    let headers = try signer.headers(
        body: Data(), subpath: "/database/1/c/development/public/records/query", date: date
    )
    #expect(headers["X-Apple-CloudKit-Request-KeyID"] == "abc123")
    #expect(headers["X-Apple-CloudKit-Request-ISO8601Date"] == "2016-01-25T22:15:43Z")
    let signature = try #require(headers["X-Apple-CloudKit-Request-SignatureV1"])
    #expect(signer.verify(
        signatureBase64: signature, date: "2016-01-25T22:15:43Z", body: Data(),
        subpath: "/database/1/c/development/public/records/query"
    ))
}

@Test func signerRejectsGarbagePEMAndAcceptsSEC1() throws {
    #expect(throws: (any Error).self) {
        _ = try CKWebServicesSigner(keyID: "k", pemPrivateKey: "not a pem")
    }
    // SEC1 "EC PRIVATE KEY" (the Console-documented openssl output) parses,
    // and the public PEM export is available for Console pasting.
    let signer = try CKWebServicesSigner(keyID: "k", pemPrivateKey: testPEM)
    #expect(signer.publicKeyPEM.contains("BEGIN PUBLIC KEY"))
}
