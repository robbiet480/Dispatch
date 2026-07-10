import Foundation

/// Plan 37 — sync diagnostics.
///
/// Pure provenance aggregation, cumulative dedupe totals, and the diagnostics
/// dump renderer. Foundation only, no SwiftData/CloudKit — the structural half
/// of the privacy guarantee is that `render` takes ALREADY-AGGREGATED
/// provenance tuples and has no `Report` parameter by construction, so report
/// content physically cannot reach it. The behavioral half is the sentinel
/// test in `SyncDiagnosticsReportTests`.

/// Per-device report provenance aggregation over the plan-19
/// `sourceDeviceName`/`sourceDeviceModel` fields.
public enum DeviceProvenance {
    /// Buckets `(name, model)` pairs by their display label and returns counts
    /// sorted count-descending, then label-ascending (fully deterministic).
    ///
    /// Label = `name ?? model ?? "Unknown device"`. Generic names ("iPhone",
    /// "Apple Watch") are expected until the user-assigned-device-name
    /// entitlement lands (see `DeviceIdentity`); model identifiers
    /// ("iPhone17,1") are shown raw — no marketing-name table in v1. Pairs
    /// with nil name AND nil model (pre-plan-19 reports) land in
    /// "Unknown device".
    public static func breakdown(_ devices: [(name: String?, model: String?)]) -> [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for device in devices {
            let label = device.name ?? device.model ?? "Unknown device"
            counts[label, default: 0] += 1
        }
        return counts
            .map { (label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.label < rhs.label
            }
    }
}

/// Cumulative, device-local dedupe statistics: lifetime per-type merge counts
/// plus the most recent pass's summary and date. Persisted beside the event
/// log in the appDefaults suite (`syncDedupeTotals`). Codable value type.
public struct DedupeTotals: Codable, Equatable, Sendable {
    public var questions = 0
    public var promptGroups = 0
    public var tokens = 0
    public var people = 0
    public var reports = 0
    public var lastPassDate: Date?
    public var lastPassSummary: DedupeSummary?

    public init() {}

    /// Lifetime total of rows merged across all passes on this device.
    public var totalMerged: Int {
        questions + promptGroups + tokens + people + reports
    }

    /// Folds one pass's summary into the lifetime counters and records it as
    /// the last pass. Called for EVERY pass, including zero-removal ones (a
    /// zero-removal pass still updates `lastPassDate`/`lastPassSummary` —
    /// "we ran and found nothing" is evidence too).
    public mutating func absorb(_ summary: DedupeSummary, at date: Date) {
        questions += summary.questionsRemoved
        promptGroups += summary.promptGroupsRemoved
        tokens += summary.tokensRemoved
        people += summary.peopleRemoved
        reports += summary.reportsRemoved
        lastPassDate = date
        lastPassSummary = summary
    }
}

/// Renders the privacy-safe diagnostics dump shared via `ShareLink`.
public enum SyncDiagnosticsReport {
    /// Builds the text dump. It contains app/build/OS/device identifiers, the
    /// sync toggle + account status, the (pre-sanitized) event ring buffer,
    /// dedupe totals, and provenance counts — and NEVER report content,
    /// answers, question prompts, vocabulary, or health data. Provenance
    /// arrives already aggregated to labels+counts, so nothing from inside a
    /// Report beyond its existence count per device is present. ISO 8601 dates
    /// keep bug reports machine-diffable.
    public static func render(
        appVersion: String,
        osVersion: String,
        deviceModel: String,
        syncEnabled: Bool,
        syncActive: Bool,
        accountStatusText: String,
        events: [SyncEventRecord],
        dedupeTotals: DedupeTotals,
        provenance: [(label: String, count: Int)],
        generatedAt: Date
    ) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []

        lines.append("Dispatch sync diagnostics")
        lines.append("Generated: \(iso.string(from: generatedAt))")
        lines.append("")
        lines.append("App version: \(appVersion)")
        lines.append("OS version: \(osVersion)")
        lines.append("Device model: \(deviceModel)")
        lines.append("iCloud Sync: \(syncEnabled ? "on" : "off") (effective: \(syncActive ? "active" : "inactive"))")
        lines.append("Account status: \(accountStatusText)")

        lines.append("")
        lines.append("EVENTS (newest first, \(events.count)):")
        if events.isEmpty {
            lines.append("  (none observed)")
        } else {
            for event in events.reversed() {
                let name = event.kind?.displayName ?? event.kindRaw
                let result: String
                switch event.succeeded {
                case .some(true): result = " [ok]"
                case .some(false): result = " [failed]"
                case .none: result = ""
                }
                let detail = event.detail.map { " — \($0)" } ?? ""
                lines.append("  \(iso.string(from: event.date))  \(name)\(result)\(detail)")
            }
        }

        lines.append("")
        lines.append("DEDUPE (lifetime merges):")
        lines.append("  Questions: \(dedupeTotals.questions)")
        lines.append("  Prompt groups: \(dedupeTotals.promptGroups)")
        lines.append("  Vocabulary tokens: \(dedupeTotals.tokens)")
        lines.append("  People: \(dedupeTotals.people)")
        lines.append("  Reports: \(dedupeTotals.reports)")
        if let last = dedupeTotals.lastPassDate {
            lines.append("  Last pass: \(iso.string(from: last))")
        } else {
            lines.append("  Last pass: (none)")
        }

        lines.append("")
        lines.append("DEVICES (reports per source device):")
        if provenance.isEmpty {
            lines.append("  (no reports)")
        } else {
            for entry in provenance {
                lines.append("  \(entry.label): \(entry.count)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
