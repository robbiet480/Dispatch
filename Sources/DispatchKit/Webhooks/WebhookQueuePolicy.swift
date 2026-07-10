import Foundation

/// Pure webhook delivery policy (plan 24): URL admission rules and the
/// retry-attempt cap. The app-side WebhookManager consumes these; keeping
/// them kit-side makes them unit-testable without any networking.
public enum WebhookQueuePolicy {
    /// Per-attempt request timeout (seconds) for single-report deliveries.
    public static let attemptTimeout: TimeInterval = 15
    /// Timeout for the one-shot bulk (`report.bulk`) POST.
    public static let bulkTimeout: TimeInterval = 60
    /// Delivery attempts per report before the failure notification fires
    /// and the report drops from the queue (revised per Robbie 2026-07-09:
    /// 3, not 5).
    public static let maxAttempts = 3

    /// Whether a report with `attempts` prior failures gets another try.
    public static func nextAttemptAllowed(attempts: Int) -> Bool {
        attempts < maxAttempts
    }

    /// URL admission: HTTPS anywhere; plain HTTP only for local-network
    /// hosts (localhost/loopback, `.local`, RFC1918 — the Home Assistant
    /// case, served by the scoped `NSAllowsLocalNetworking` ATS key).
    /// Everything else is rejected at entry with a reason the settings UI
    /// shows inline.
    public enum URLRule {
        public enum ValidationResult: Equatable {
            case valid(URL)
            case rejected(reason: String)
        }

        public static func validate(_ urlString: String) -> ValidationResult {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .rejected(reason: "Enter a URL.")
            }
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  let host = url.host(), !host.isEmpty else {
                return .rejected(reason: "That doesn't look like a valid URL.")
            }
            switch scheme {
            case "https":
                return .valid(url)
            case "http":
                if isLocalNetworkHost(host) {
                    return .valid(url)
                }
                return .rejected(reason: "Plain HTTP is only allowed for servers on your local network (192.168.x.x, 10.x.x.x, .local, localhost). Use HTTPS for anything else.")
            default:
                return .rejected(reason: "Only https:// (or http:// to a local-network server) URLs are supported.")
            }
        }

        /// localhost / loopback / `.local` / RFC1918 private ranges.
        static func isLocalNetworkHost(_ rawHost: String) -> Bool {
            let host = rawHost.lowercased()
            if host == "localhost" || host == "::1" { return true }
            if host.hasSuffix(".local") { return true }
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            if octets[0] == 127 { return true } // loopback
            if octets[0] == 10 { return true } // 10/8
            if octets[0] == 172, (16...31).contains(octets[1]) { return true } // 172.16/12
            if octets[0] == 192, octets[1] == 168 { return true } // 192.168/16
            return false
        }
    }
}

/// A queued delivery: the report's uniqueIdentifier plus how many attempts
/// have already failed.
public struct WebhookQueueEntry: Codable, Equatable, Sendable {
    public var reportID: String
    public var attempts: Int

    public init(reportID: String, attempts: Int = 0) {
        self.reportID = reportID
        self.attempts = attempts
    }
}

/// The enqueue-and-drain queue itself, stored in App Group defaults so
/// EVERY save path can enqueue — including the widget-extension process
/// (which enqueues only, never delivers; same marker pattern as
/// `WidgetQuickAnswerMarker`). The app process drains.
public enum WebhookQueue {
    /// JSON-encoded `[WebhookQueueEntry]`, FIFO (oldest first).
    public static let queueKey = "webhook.queue"
    /// Mirrored enabled flag readable from the widget process, so a
    /// disabled (or never-configured) webhook never grows a queue.
    public static let enabledKey = "webhook.enabled"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: enabledKey)
    }

    public static func entries(in defaults: UserDefaults) -> [WebhookQueueEntry] {
        guard let data = defaults.data(forKey: queueKey),
              let entries = try? JSONDecoder().decode([WebhookQueueEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func write(_ entries: [WebhookQueueEntry], in defaults: UserDefaults) {
        if entries.isEmpty {
            defaults.removeObject(forKey: queueKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: queueKey)
        }
    }

    /// Appends `reportID` (FIFO) unless it is already queued, and only when
    /// the mirrored enabled flag is set.
    public static func enqueue(reportID: String, in defaults: UserDefaults) {
        guard isEnabled(in: defaults) else { return }
        var entries = entries(in: defaults)
        guard !entries.contains(where: { $0.reportID == reportID }) else { return }
        entries.append(WebhookQueueEntry(reportID: reportID))
        write(entries, in: defaults)
    }

    /// Bulk enqueue for Send All (individual mode) — oldest-first order is
    /// the caller's responsibility; already-queued IDs are skipped.
    public static func enqueue(reportIDs: [String], in defaults: UserDefaults) {
        guard isEnabled(in: defaults) else { return }
        var entries = entries(in: defaults)
        let queued = Set(entries.map(\.reportID))
        for reportID in reportIDs where !queued.contains(reportID) {
            entries.append(WebhookQueueEntry(reportID: reportID))
        }
        write(entries, in: defaults)
    }

    /// Removes a delivered (or permanently failed) report from the queue.
    public static func remove(reportID: String, in defaults: UserDefaults) {
        write(entries(in: defaults).filter { $0.reportID != reportID }, in: defaults)
    }

    /// Records a failed attempt. Returns the new attempt count, or removes
    /// the entry and returns nil when the cap is exhausted (the caller then
    /// posts the failure notification).
    public static func recordFailure(reportID: String, in defaults: UserDefaults) -> Int? {
        var entries = entries(in: defaults)
        guard let index = entries.firstIndex(where: { $0.reportID == reportID }) else { return nil }
        entries[index].attempts += 1
        if WebhookQueuePolicy.nextAttemptAllowed(attempts: entries[index].attempts) {
            write(entries, in: defaults)
            return entries[index].attempts
        }
        entries.remove(at: index)
        write(entries, in: defaults)
        return nil
    }

    public static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: queueKey)
    }
}
