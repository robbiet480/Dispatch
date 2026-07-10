import DispatchKit
import Foundation
import Observation
import os
import SwiftData
import UserNotifications

private let webhookLog = Logger(subsystem: "io.robbie.Dispatch", category: "webhooks")

/// Injectable transport so tests never touch the real network (plan 24
/// global constraint). `URLSession` is the production conformance; UI tests
/// launch with `--stub-webhook` to get `StubWebhookTransport`.
protocol WebhookTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: WebhookTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Always answers HTTP 200 — the UI-test transport (`--stub-webhook`).
struct StubWebhookTransport: WebhookTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.invalid")!,
                                       statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        return (Data(), response)
    }
}

/// Report webhooks (plan 24): when a report is completed, POST its JSON to
/// the user-configured URL. Queue-and-drain — every save path enqueues the
/// report's uniqueIdentifier in App Group defaults (the widget-extension
/// process enqueues only, via `WebhookQueue`); THIS manager, in the app
/// process, drains: immediately after in-app saves, on foreground, and
/// after the widget-marker drain. Per attempt: 15s timeout, success = any
/// HTTP 2xx; a report is retried at subsequent drains up to 3 attempts,
/// then a local notification (`webhook-failed-<reportID>`) reports the
/// failure and the report drops from the queue. Deliberately NO background
/// URLSession in v1 — drain-on-foreground is honest and simple.
///
/// Config is DEVICE-LOCAL (never synced): a URL+secret is a credential,
/// and syncing would double-deliver from two devices.
@MainActor
@Observable
final class WebhookManager {
    private enum Keys {
        static let url = "webhook.url"
        static let secret = "webhook.secret"
        static let encrypt = "webhook.encrypt"
        static let lastStatus = "webhook.lastDeliveryStatus"
    }

    private let container: ModelContainer
    /// App Group defaults in production (the widget process enqueues into
    /// the same suite); the isolated per-launch suite under test args.
    private let defaults: UserDefaults
    private let transport: any WebhookTransport
    private let isTestEnvironment: Bool
    private var isDraining = false

    init(container: ModelContainer, defaults: UserDefaults, transport: any WebhookTransport,
         isTestEnvironment: Bool) {
        self.container = container
        self.defaults = defaults
        self.transport = transport
        self.isTestEnvironment = isTestEnvironment
        lastDeliveryStatus = defaults.string(forKey: Keys.lastStatus)
        isEnabled = WebhookQueue.isEnabled(in: defaults)
        urlString = defaults.string(forKey: Keys.url) ?? ""
        secret = defaults.string(forKey: Keys.secret) ?? ""
        encryptPayload = defaults.bool(forKey: Keys.encrypt)
    }

    // MARK: - Config (device-local)

    var isEnabled: Bool {
        didSet { WebhookQueue.setEnabled(isEnabled, in: defaults) }
    }

    var urlString: String {
        didSet { defaults.set(urlString, forKey: Keys.url) }
    }

    var secret: String {
        didSet {
            defaults.set(secret, forKey: Keys.secret)
            // Encryption requires a secret (the key derives from it).
            if secret.isEmpty { encryptPayload = false }
        }
    }

    var encryptPayload: Bool {
        didSet { defaults.set(encryptPayload, forKey: Keys.encrypt) }
    }

    /// Human-readable last-delivery status for the settings row; persisted
    /// so it survives relaunches.
    private(set) var lastDeliveryStatus: String? {
        didSet { defaults.set(lastDeliveryStatus, forKey: Keys.lastStatus) }
    }

    var urlValidation: WebhookQueuePolicy.URLRule.ValidationResult {
        WebhookQueuePolicy.URLRule.validate(urlString)
    }

    private var deliverableURL: URL? {
        guard isEnabled, case .valid(let url) = urlValidation else { return nil }
        return url
    }

    // MARK: - Enqueue (app-process side; the widget calls WebhookQueue directly)

    func enqueue(reportID: String) {
        WebhookQueue.enqueue(reportID: reportID, in: defaults)
    }

    /// The in-app save hook: enqueue, then drain immediately.
    func enqueueAndDrain(reportID: String) {
        enqueue(reportID: reportID)
        drain()
    }

    // MARK: - Drain

    /// Fire-and-forget drain for the synchronous call sites (post-save,
    /// scene-active, post-widget-marker-drain).
    func drain() {
        Task { await drainNow() }
    }

    /// Delivers queued reports oldest-first. Re-entrancy guarded: a save
    /// during a drain simply leaves its entry for this pass or the next.
    func drainNow() async {
        guard !isDraining, let url = deliverableURL else { return }
        isDraining = true
        defer { isDraining = false }

        for entry in WebhookQueue.entries(in: defaults) {
            let context = ModelContext(container)
            guard let report = Self.fetchReport(id: entry.reportID, in: context) else {
                // Deleted since it was queued — nothing to deliver.
                WebhookQueue.remove(reportID: entry.reportID, in: defaults)
                continue
            }
            let body: Data
            do {
                body = try prepare(try WebhookPayload.body(for: report))
            } catch {
                webhookLog.error("payload build failed for \(entry.reportID, privacy: .public): \(error, privacy: .public)")
                WebhookQueue.remove(reportID: entry.reportID, in: defaults)
                continue
            }
            if await post(body: body, to: url, timeout: WebhookQueuePolicy.attemptTimeout) {
                WebhookQueue.remove(reportID: entry.reportID, in: defaults)
                recordStatus("Delivered", detail: nil)
            } else if let attempts = WebhookQueue.recordFailure(reportID: entry.reportID, in: defaults) {
                webhookLog.warning("delivery failed for \(entry.reportID, privacy: .public) (attempt \(attempts)/\(WebhookQueuePolicy.maxAttempts)) — will retry at the next drain")
                recordStatus("Failed (attempt \(attempts) of \(WebhookQueuePolicy.maxAttempts)) — will retry", detail: nil)
                // Attempts are per-drain-opportunity; don't burn the
                // remaining attempts inside this same drain.
                break
            } else {
                webhookLog.error("delivery failed permanently for \(entry.reportID, privacy: .public) after \(WebhookQueuePolicy.maxAttempts) attempts")
                recordStatus("Failed after \(WebhookQueuePolicy.maxAttempts) attempts", detail: nil)
                postFailureNotification(for: report)
                break
            }
        }
    }

    // MARK: - Send Test

    /// Posts `{"event":"test"}` through the SAME transport/signing/
    /// encryption path as real deliveries; returns the inline result text.
    func sendTest() async -> String {
        guard case .valid(let url) = urlValidation else {
            if case .rejected(let reason) = urlValidation { return reason }
            return "Enter a valid URL first."
        }
        do {
            let body = try prepare(try WebhookPayload.testBody())
            if await post(body: body, to: url, timeout: WebhookQueuePolicy.attemptTimeout) {
                return "Test delivered ✓"
            }
            return "Test failed — check the URL and that your server answers 2xx."
        } catch {
            return "Test failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Send All Reports (one-time bulk)

    var reportCount: Int {
        let context = ModelContext(container)
        return (try? context.fetchCount(FetchDescriptor<Report>())) ?? 0
    }

    /// Individual mode: every report enqueued through the normal queue as
    /// `report.created` events, oldest-first, with the same retry/
    /// notification semantics as any other save.
    func sendAllIndividually() {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Report>(
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)])
        guard let reports = try? context.fetch(descriptor) else { return }
        WebhookQueue.enqueue(reportIDs: reports.map(\.uniqueIdentifier), in: defaults)
        drain()
    }

    /// Single-payload mode: one `report.bulk` POST (oldest-first, 60s
    /// timeout). Does NOT enter the retry queue — a failure is reported
    /// back so the UI can offer one retry via alert.
    func sendAllAsSinglePayload() async -> Bool {
        guard let url = deliverableURL else { return false }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Report>(
            sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)])
        guard let reports = try? context.fetch(descriptor),
              let body = try? prepare(try WebhookPayload.bulkBody(for: reports)) else {
            return false
        }
        let delivered = await post(body: body, to: url, timeout: WebhookQueuePolicy.bulkTimeout)
        recordStatus(delivered ? "Delivered (bulk, \(reports.count) reports)"
                               : "Bulk send failed", detail: nil)
        return delivered
    }

    // MARK: - Request plumbing

    /// Encrypt-then-MAC: encryption (when enabled, secret required) wraps
    /// the payload first; the HMAC header then signs the bytes AS SENT.
    private func prepare(_ payload: Data) throws -> Data {
        guard encryptPayload, !secret.isEmpty else { return payload }
        return try WebhookCrypto.encrypt(payload, secret: secret)
    }

    /// POSTs `body`; true on any HTTP 2xx (the whole family counts — see
    /// docs/webhooks.md).
    private func post(body: Data, to url: URL, timeout: TimeInterval) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !secret.isEmpty {
            request.setValue(WebhookSigner.signatureHeader(body: body, secret: secret),
                             forHTTPHeaderField: WebhookSigner.headerName)
        }
        request.httpBody = body
        do {
            let (_, response) = try await transport.send(request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            webhookLog.warning("webhook POST failed: \(error, privacy: .public)")
            return false
        }
    }

    private func recordStatus(_ status: String, detail: String?) {
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        lastDeliveryStatus = "\(status) — \(stamp)"
    }

    /// The 3rd-failure local notification. Identifier
    /// `webhook-failed-<reportID>` joins the standard removal-batch prefix
    /// discipline (see NotificationIdentifiers.webhookFailedPrefix).
    /// Test-gated like every other center access.
    private func postFailureNotification(for report: Report) {
        guard !isTestEnvironment else { return }
        let content = UNMutableNotificationContent()
        content.title = "Webhook delivery failed"
        let time = report.date.formatted(date: .omitted, time: .shortened)
        content.body = "Webhook delivery failed for your \(time) report — check the URL in Settings."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(NotificationIdentifiers.webhookFailedPrefix)\(report.uniqueIdentifier)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                webhookLog.error("failed to post webhook-failure notification: \(error, privacy: .public)")
            }
        }
    }

    private static func fetchReport(id: String, in context: ModelContext) -> Report? {
        var descriptor = FetchDescriptor<Report>(
            predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
