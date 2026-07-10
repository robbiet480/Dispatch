import Foundation
import SwiftData

/// Webhook payload construction (plan 24). Every payload reuses the v2
/// export encoding (`V2Exporter.reportDTO` + `JSONEncoder.v2`) so consumers
/// parse ONE format: a webhook-delivered report is byte-identical to the
/// same report inside a full export file.
public enum WebhookPayload {
    /// Event names on the wire.
    public enum Event {
        public static let reportCreated = "report.created"
        public static let reportBulk = "report.bulk"
        public static let test = "test"
    }

    /// `{"event": <event>, "schemaVersion": 2, "report": <v2 report>}`
    struct SingleEnvelope: Codable {
        var event: String
        var schemaVersion: Int
        var report: V2Report
    }

    /// `{"event": "report.bulk", "schemaVersion": 2, "reports": [<v2 report>…]}`
    struct BulkEnvelope: Codable {
        var event: String
        var schemaVersion: Int
        var reports: [V2Report]
    }

    struct TestEnvelope: Codable {
        var event: String
    }

    /// Body for a single-report event (`report.created`).
    public static func body(for report: Report, event: String = Event.reportCreated) throws -> Data {
        let envelope = SingleEnvelope(event: event,
                                      schemaVersion: DispatchKitInfo.schemaVersion,
                                      report: V2Exporter.reportDTO(report))
        return try JSONEncoder.v2.encode(envelope)
    }

    /// Body for the one-time Send All bulk mode. Callers pass reports
    /// oldest-first (the same sort the exporter uses).
    public static func bulkBody(for reports: [Report]) throws -> Data {
        let envelope = BulkEnvelope(event: Event.reportBulk,
                                    schemaVersion: DispatchKitInfo.schemaVersion,
                                    reports: reports.map(V2Exporter.reportDTO(_:)))
        return try JSONEncoder.v2.encode(envelope)
    }

    /// Body for the settings screen's Send Test button.
    public static func testBody() throws -> Data {
        try JSONEncoder.v2.encode(TestEnvelope(event: Event.test))
    }
}
