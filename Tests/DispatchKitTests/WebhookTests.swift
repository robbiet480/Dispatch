import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// MARK: - Payload

/// The webhook's report object must be BYTE-IDENTICAL to how V2Exporter
/// encodes the same report in a full export — one wire format for consumers.
@Test func webhookPayloadReportMatchesV2ExporterEncoding() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let reports = try context.fetch(
        FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)]))
    let exported = try V2Exporter.export(from: context).reports
    #expect(!reports.isEmpty)
    #expect(reports.count == exported.count)

    for (report, exporterDTO) in zip(reports, exported) {
        let body = try WebhookPayload.body(for: report)
        let envelope = try JSONDecoder.v2.decode(WebhookPayload.SingleEnvelope.self, from: body)
        #expect(envelope.event == "report.created")
        #expect(envelope.schemaVersion == 2)
        // Byte-for-byte: both DTOs render identically under the v2 encoder.
        let fromWebhook = try JSONEncoder.v2.encode(envelope.report)
        let fromExporter = try JSONEncoder.v2.encode(exporterDTO)
        #expect(fromWebhook == fromExporter)
    }
}

@Test func webhookBulkPayloadIsOldestFirstWithBulkEvent() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let reports = try context.fetch(
        FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)]))
    let body = try WebhookPayload.bulkBody(for: reports)
    let envelope = try JSONDecoder.v2.decode(WebhookPayload.BulkEnvelope.self, from: body)
    #expect(envelope.event == "report.bulk")
    #expect(envelope.schemaVersion == 2)
    #expect(envelope.reports.map(\.uniqueIdentifier) == reports.map(\.uniqueIdentifier))
    let dates = envelope.reports.map(\.date)
    #expect(dates == dates.sorted())
}

@Test func webhookTestPayloadIsTheDocumentedShape() throws {
    let body = try WebhookPayload.testBody()
    #expect(String(data: body, encoding: .utf8) == "{\n  \"event\" : \"test\"\n}")
}

// MARK: - Signing (python3 hmac reference — session crypto rule)

/// Vector generated with python3:
/// `hmac.new(b"test-secret", b'{"event":"test"}', hashlib.sha256).hexdigest()`
@Test func webhookSignatureMatchesPythonHMACReference() {
    let header = WebhookSigner.signatureHeader(
        body: Data("{\"event\":\"test\"}".utf8), secret: "test-secret")
    #expect(header == "sha256=ad386d9a61a0540a089d2955a07280771439f9f8c41a4b94cd404a740061c3d9")
    #expect(WebhookSigner.headerName == "X-Dispatch-Signature")
}

// MARK: - Payload encryption (python `cryptography` reference — session crypto rule)

/// Key vector generated with python `cryptography`:
/// `HKDF(SHA256, length=32, salt=b"io.robbie.Dispatch.webhook",
///       info=b"payload-encryption").derive(b"test-secret")`
/// (cross-checked against a manual hashlib HKDF implementation).
@Test func webhookHKDFKeyMatchesPythonReference() {
    #expect(WebhookCrypto.keyHex(secret: "test-secret")
        == "ca609d47aa95a2a0143e9f13b20a49ff4235833e9d5e7df595e1591c5dfd5b2a")
}

/// Ciphertext vector generated with python `cryptography`:
/// `AESGCM(key).encrypt(bytes(range(1,13)), b'{"event":"test"}', None)`,
/// combined = nonce ‖ ciphertext ‖ tag, base64-encoded.
@Test func webhookEncryptionMatchesPythonAESGCMReference() throws {
    let plaintext = Data("{\"event\":\"test\"}".utf8)
    let nonce = try CryptoKitNonce(bytes: Array(1...12))
    let envelope = try WebhookCrypto.encrypt(plaintext, secret: "test-secret", nonce: nonce)
    let json = try #require(String(data: envelope, encoding: .utf8))
    #expect(json == "{\"algorithm\":\"aes-256-gcm\",\"data\":\"AQIDBAUGBwgJCgsMC9jYjJ4ugwkGaHUXnnfLbeTVxpZEtqtO8r9U1G+koMc=\",\"encrypted\":true}")

    // And the python-produced envelope decrypts back to the plaintext.
    let decrypted = try WebhookCrypto.decrypt(envelope: envelope, secret: "test-secret")
    #expect(decrypted == plaintext)
}

@Test func webhookEncryptionRoundTripsWithRandomNonceAndRejectsWrongSecret() throws {
    let plaintext = try WebhookPayload.testBody()
    let envelope = try WebhookCrypto.encrypt(plaintext, secret: "hunter2")
    #expect(try WebhookCrypto.decrypt(envelope: envelope, secret: "hunter2") == plaintext)
    #expect(throws: (any Error).self) {
        try WebhookCrypto.decrypt(envelope: envelope, secret: "wrong")
    }
    // Encrypt-then-MAC: the signature covers the envelope bytes as sent.
    let header = WebhookSigner.signatureHeader(body: envelope, secret: "hunter2")
    #expect(header.hasPrefix("sha256="))
}

// MARK: - URL rules

@Test(arguments: [
    "https://example.com/webhook",
    "https://hooks.internal:8443/dispatch",
    "http://localhost:8123/api/webhook/abc",
    "http://127.0.0.1/hook",
    "http://homeassistant.local:8123/api/webhook/abc",
    "http://192.168.1.50/hook",
    "http://10.0.0.5:9000/hook",
    "http://172.16.0.1/hook",
    "http://172.31.255.254/hook",
])
func webhookURLRuleAccepts(_ urlString: String) {
    #expect(WebhookQueuePolicy.URLRule.validate(urlString) == .valid(URL(string: urlString)!))
}

@Test(arguments: [
    "http://example.com/webhook", // public http
    "http://8.8.8.8/hook", // public IP http
    "http://172.32.0.1/hook", // just outside 172.16/12
    "http://172.15.0.1/hook", // just below 172.16/12
    "ftp://example.com/hook", // wrong scheme
    "not a url",
    "",
    "   ",
])
func webhookURLRuleRejects(_ urlString: String) {
    guard case .rejected = WebhookQueuePolicy.URLRule.validate(urlString) else {
        Issue.record("expected rejection for \(urlString)")
        return
    }
}

// MARK: - Attempt cap

@Test func webhookAttemptCapIsThree() {
    #expect(WebhookQueuePolicy.maxAttempts == 3)
    #expect(WebhookQueuePolicy.nextAttemptAllowed(attempts: 0))
    #expect(WebhookQueuePolicy.nextAttemptAllowed(attempts: 1))
    #expect(WebhookQueuePolicy.nextAttemptAllowed(attempts: 2))
    #expect(!WebhookQueuePolicy.nextAttemptAllowed(attempts: 3))
    #expect(!WebhookQueuePolicy.nextAttemptAllowed(attempts: 4))
}

// MARK: - Queue semantics (App Group defaults-backed)

private func makeIsolatedDefaults() throws -> UserDefaults {
    let suite = "webhook-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@Test func webhookQueueEnqueuesFIFOWithoutDuplicatesOnlyWhenEnabled() throws {
    let defaults = try makeIsolatedDefaults()

    // Disabled (default): enqueue is a no-op, so a never-configured webhook
    // can't grow a queue from the widget process.
    WebhookQueue.enqueue(reportID: "r1", in: defaults)
    #expect(WebhookQueue.entries(in: defaults).isEmpty)

    WebhookQueue.setEnabled(true, in: defaults)
    WebhookQueue.enqueue(reportID: "r1", in: defaults)
    WebhookQueue.enqueue(reportID: "r2", in: defaults)
    WebhookQueue.enqueue(reportID: "r1", in: defaults) // duplicate collapses
    #expect(WebhookQueue.entries(in: defaults).map(\.reportID) == ["r1", "r2"])

    WebhookQueue.enqueue(reportIDs: ["r2", "r3", "r4"], in: defaults)
    #expect(WebhookQueue.entries(in: defaults).map(\.reportID) == ["r1", "r2", "r3", "r4"])

    WebhookQueue.remove(reportID: "r1", in: defaults)
    #expect(WebhookQueue.entries(in: defaults).map(\.reportID) == ["r2", "r3", "r4"])
}

@Test func webhookQueueDropsEntryAfterThirdFailedAttempt() throws {
    let defaults = try makeIsolatedDefaults()
    WebhookQueue.setEnabled(true, in: defaults)
    WebhookQueue.enqueue(reportID: "r1", in: defaults)

    // Attempts 1 and 2 fail → retained with the incremented count.
    #expect(WebhookQueue.recordFailure(reportID: "r1", in: defaults) == 1)
    #expect(WebhookQueue.entries(in: defaults) == [WebhookQueueEntry(reportID: "r1", attempts: 1)])
    #expect(WebhookQueue.recordFailure(reportID: "r1", in: defaults) == 2)

    // Attempt 3 fails → nil (cap exhausted) and the entry drops.
    #expect(WebhookQueue.recordFailure(reportID: "r1", in: defaults) == nil)
    #expect(WebhookQueue.entries(in: defaults).isEmpty)

    // Unknown IDs are a nil no-op.
    #expect(WebhookQueue.recordFailure(reportID: "ghost", in: defaults) == nil)
}

// MARK: - Helpers

import CryptoKit

private func CryptoKitNonce(bytes: [UInt8]) throws -> AES.GCM.Nonce {
    try AES.GCM.Nonce(data: Data(bytes))
}
