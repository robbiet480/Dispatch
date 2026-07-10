import CoreData
import DispatchKit
import Foundation
import Observation

/// Plan 37 — the app-side sink for sync diagnostics.
///
/// Owns the persisted `SyncEventLog` ring buffer and cumulative `DedupeTotals`
/// (both in the appDefaults suite), and is fed from two sources:
///   1. `RemoteChangeObserver`'s injected `onDiagnosticsEvent` callback —
///      `remoteChange`, `dedupePass` (with its `DedupeSummary`, absorbed into
///      totals), and `pipelineError` records, all already computed by the
///      plan-13 pipeline and previously only logged.
///   2. `NSPersistentCloudKitContainer.eventChangedNotification` — real
///      CloudKit setup/import/export results, PROBE-GATED (see
///      `startCloudKitObservation`).
///
/// It is a SINK, not a second observer of store changes: it never runs the
/// dedupe pipeline. The CloudKit-event subscription only records diagnostic
/// rows — unlike `NSPersistentStoreRemoteChange`, `eventChangedNotification`
/// does not drive any pipeline, so subscribing is side-effect-free.
///
/// Test-gated: under `--ui-testing`/`--mock-sensors` it uses the isolated
/// per-launch defaults suite and NEVER subscribes to any notification.
@MainActor
@Observable
final class SyncDiagnostics {
    /// appDefaults key holding the JSON-encoded event ring buffer.
    static let eventLogKey = "syncEventLog"
    /// appDefaults key holding the JSON-encoded cumulative dedupe totals.
    static let dedupeTotalsKey = "syncDedupeTotals"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool

    private var log: SyncEventLog
    private(set) var dedupeTotals: DedupeTotals

    @ObservationIgnored private var cloudKitObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults, isTestEnvironment: Bool) {
        self.defaults = defaults
        self.isTestEnvironment = isTestEnvironment
        self.log = SyncEventLog(decodingFrom: defaults.data(forKey: Self.eventLogKey))
        if let data = defaults.data(forKey: Self.dedupeTotalsKey),
           let decoded = try? JSONDecoder().decode(DedupeTotals.self, from: data) {
            self.dedupeTotals = decoded
        } else {
            self.dedupeTotals = DedupeTotals()
        }
    }

    /// Events newest-first for the timeline UI.
    var events: [SyncEventRecord] { log.records.reversed() }

    /// Most recent CloudKit import result observed (probe path only; nil on
    /// the fallback path since no `ckImport` records are ever recorded there).
    var lastCloudKitImport: (date: Date, succeeded: Bool)? { lastResult(of: .ckImport) }

    /// Most recent CloudKit export result observed (probe path only).
    var lastCloudKitExport: (date: Date, succeeded: Bool)? { lastResult(of: .ckExport) }

    private func lastResult(of kind: SyncEventKind) -> (date: Date, succeeded: Bool)? {
        guard let record = log.records.last(where: { $0.kind == kind }),
              let succeeded = record.succeeded else { return nil }
        return (record.date, succeeded)
    }

    /// Records a generic event (`remoteChange`, `pipelineError`, `ck*`) into
    /// the ring buffer and persists. Dedupe passes go through
    /// `recordDedupePass` instead so their `DedupeSummary` can be absorbed.
    func record(_ event: SyncEventRecord) {
        log.append(event)
        persistLog()
    }

    /// Records a completed dedupe pass: appends a `dedupePass` event (counts in
    /// `detail`, zero-removal passes included) AND folds the summary into the
    /// lifetime totals.
    func recordDedupePass(_ summary: DedupeSummary, at date: Date) {
        dedupeTotals.absorb(summary, at: date)
        log.append(SyncEventRecord(
            date: date,
            kindRaw: SyncEventKind.dedupePass.rawValue,
            succeeded: true,
            detail: Self.dedupeDetail(summary)
        ))
        persistLog()
        persistTotals()
    }

    private static func dedupeDetail(_ summary: DedupeSummary) -> String {
        guard summary.totalRemoved > 0 else { return "no duplicates found" }
        var parts: [String] = []
        if summary.questionsRemoved > 0 { parts.append("\(summary.questionsRemoved) questions") }
        if summary.promptGroupsRemoved > 0 { parts.append("\(summary.promptGroupsRemoved) prompt groups") }
        if summary.tokensRemoved > 0 { parts.append("\(summary.tokensRemoved) tokens") }
        if summary.peopleRemoved > 0 { parts.append("\(summary.peopleRemoved) people") }
        if summary.reportsRemoved > 0 { parts.append("\(summary.reportsRemoved) reports") }
        return "merged " + parts.joined(separator: ", ")
    }

    private func persistLog() {
        if let data = log.encoded() {
            defaults.set(data, forKey: Self.eventLogKey)
        }
    }

    private func persistTotals() {
        if let data = try? JSONEncoder().encode(dedupeTotals) {
            defaults.set(data, forKey: Self.dedupeTotalsKey)
        }
    }

    // MARK: - CloudKit event observation (probe-gated)

    /// Subscribes to `NSPersistentCloudKitContainer.eventChangedNotification`
    /// and maps setup/import/export results into `ckSetup`/`ckImport`/
    /// `ckExport` records.
    ///
    /// PROBE FINDING (plan 37, `--probe-cloudkit-events`): whether this
    /// notification actually fires through SwiftData's CloudKit mirroring
    /// stack when subscribed with `object: nil` — SwiftData never exposes the
    /// `NSPersistentCloudKitContainer` — is the same empirical question plan 13
    /// faced for `NSPersistentStoreRemoteChange`. Empirical on-device/simulator
    /// verification with a signed-in iCloud account is REQUIRED to confirm; it
    /// was NOT run in the implementation environment (no iCloud sign-in
    /// available). The subscription ships ENABLED because it is provably
    /// side-effect-free: it only records diagnostic rows and never drives the
    /// dedupe pipeline, so if the notification never fires we simply record no
    /// `ck*` rows and the UI's honest fallback copy ("no sync events observed")
    /// applies automatically; if it DOES fire, the timeline gains real
    /// import/export results at no additional cost. Run
    /// `--probe-cloudkit-events` on a signed-in device, file a report, and
    /// confirm `CLOUDKIT-EVENT:` log lines to settle the finding and update
    /// this comment + the plan completion note.
    ///
    /// SDK shape verified against NSPersistentCloudKitContainerEvent.h
    /// (iPhoneOS26.5): userInfo key `eventNotificationUserInfoKey`, Event has
    /// `type` (`.setup`/`.import`/`.export`), `startDate`, `endDate?`,
    /// `succeeded`, `error?`.
    func startCloudKitObservation() {
        guard !isTestEnvironment, cloudKitObserver == nil else { return }
        // queue: .main guarantees the closure runs on the main thread, so the
        // MainActor.assumeIsolated hop below is sound. The non-Sendable Event
        // is decomposed into Sendable value types INSIDE the closure (it never
        // crosses the isolation boundary) — only the resulting record does.
        cloudKitObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                  ] as? NSPersistentCloudKitContainer.Event else { return }
            // Only completed events (endDate set) carry a meaningful success/
            // failure result; in-progress deliveries (endDate nil) are skipped
            // — no fake progress (the honesty decision).
            guard let endDate = event.endDate else { return }
            let kind: SyncEventKind
            switch event.type {
            case .setup: kind = .ckSetup
            case .import: kind = .ckImport
            case .export: kind = .ckExport
            @unknown default: return
            }
            let record = SyncEventRecord(
                date: endDate,
                kindRaw: kind.rawValue,
                succeeded: event.succeeded,
                detail: event.error.map { SyncEventRecord.sanitize(error: $0) }
            )
            syncLog.info("CLOUDKIT-EVENT: \(kind.rawValue, privacy: .public) succeeded=\(event.succeeded, privacy: .public)")
            MainActor.assumeIsolated {
                self.record(record)
            }
        }
        syncLog.info("CloudKit event observation subscribed (probe-gated)")
    }
}
