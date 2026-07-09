import CoreData
import DispatchKit
import Foundation
import Observation
import os
import SwiftData

/// Reacts to store changes arriving from CloudKit (another device edited a
/// question, filed a report, …). SwiftData doesn't surface CloudKit events
/// directly, so this listens for `NSPersistentStoreRemoteChange` — posted by
/// the store coordinator when persistent history + remote-change
/// notifications are enabled, which SwiftData's CloudKit mirroring does.
/// Subscribing with `object: nil` reaches the coordinator without needing
/// SwiftData to expose it (verified empirically via `--probe-remote-change`).
///
/// Events are debounced 2s, then a single pipeline runs on a background
/// context: SyncDedupe → VocabularyBuilder.rebuild → Spotlight reindex
/// (lock-policy-gated inside SpotlightIndexer) → the `onRemoteChangesApplied`
/// callback on the main actor (notification replan + category re-register —
/// questions may have changed on another device).
///
/// Self-feedback guard: `NSPersistentStoreRemoteChange` also fires for this
/// process's OWN saves — including the pipeline's dedupe/rebuild saves —
/// which would otherwise loop the handler forever. Events are ignored while
/// the handler runs and for a short cooldown after it finishes.
///
/// Test-gated off: never starts under `--ui-testing`/`--mock-sensors`.
@MainActor
@Observable
final class RemoteChangeObserver {
    private let container: ModelContainer
    private let isTestEnvironment: Bool
    /// Whether the launched container is actually CloudKit-backed. When it
    /// isn't (toggle off, or fallback after a CloudKit construction failure),
    /// no subscription happens: `NSPersistentStoreRemoteChange` fires for
    /// own-process saves too (verified via `--probe-remote-change`), so
    /// subscribing on a local-only store would run the pipeline after every
    /// save — a behavior change the sync-disabled path must not have.
    private let isSyncActive: Bool
    private let onRemoteChangesApplied: @MainActor () -> Void

    /// Timestamp of the most recent store-change event seen (fed to the
    /// Settings "Last sync activity" caption; nil until the first event).
    private(set) var lastEventDate: Date?

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var notificationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isHandlerRunning = false
    @ObservationIgnored private var suppressEventsUntil: Date = .distantPast
    /// Set when an event arrives while suppressed (handler running or in
    /// cooldown) so it coalesces into one rescheduled pass instead of being
    /// dropped — a genuine remote burst overlapping the pipeline would
    /// otherwise never be processed.
    @ObservationIgnored private var hasPendingEvent = false

    private static let debounceInterval: TimeInterval = 2
    private static let postHandlerCooldown: TimeInterval = 1

    init(
        container: ModelContainer,
        isTestEnvironment: Bool,
        isSyncActive: Bool,
        onRemoteChangesApplied: @escaping @MainActor () -> Void
    ) {
        self.container = container
        self.isTestEnvironment = isTestEnvironment
        self.isSyncActive = isSyncActive
        self.onRemoteChangesApplied = onRemoteChangesApplied
    }

    /// Subscribes to remote-change notifications (sync-active only) and
    /// schedules the launch dedupe pass (debounced together with launch's
    /// own notification burst, so launch + first fire collapse into one
    /// pipeline run). With sync inactive the launch pass still runs, but as
    /// dedupe-only — no vocabulary/Spotlight/replan side effects, so the
    /// sync-disabled path behaves exactly as before unless duplicates
    /// actually exist (e.g. the same export imported twice).
    func start() {
        guard !isTestEnvironment, notificationObserver == nil else { return }
        if isSyncActive {
            notificationObserver = NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.noteRemoteChange()
                }
            }
            syncLog.info("remote-change observer subscribed")
        } else {
            syncLog.info("remote-change observer not subscribed: sync inactive (launch dedupe only)")
        }
        scheduleHandler()
    }

    private func noteRemoteChange() {
        // Ignore our own pipeline's saves (see class doc); genuine remote
        // events arriving later are unaffected. Suppressed events are
        // coalesced into a single rescheduled pass (see handleChanges).
        guard !isHandlerRunning, Date() >= suppressEventsUntil else {
            hasPendingEvent = true
            return
        }
        lastEventDate = Date()
        scheduleHandler()
    }

    private func scheduleHandler() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleChanges()
        }
    }

    private func handleChanges() async {
        isHandlerRunning = true
        defer {
            isHandlerRunning = false
            suppressEventsUntil = Date().addingTimeInterval(Self.postHandlerCooldown)
            // Events that arrived while suppressed coalesce into ONE follow-up
            // pass. The debounce interval (2s) exceeds the cooldown (1s), so
            // by the time the rescheduled handler runs the cooldown has
            // lapsed; steady state (no store changes → no saves → no events)
            // terminates the chain.
            if hasPendingEvent {
                hasPendingEvent = false
                scheduleHandler()
            }
        }

        // Heavy lifting on a background context (same cross-context pattern
        // as DataSettingsView's import): ModelContainer is Sendable, and
        // SpotlightIndexer snapshots its models before any async work.
        let container = self.container
        let fullPipeline = isSyncActive
        let summary: DedupeSummary? = await Task.detached(priority: .utility) {
            do {
                let context = ModelContext(container)
                let summary = try SyncDedupe.run(in: context)
                guard fullPipeline else { return summary }
                try VocabularyBuilder.rebuild(in: context)
                let reports = try context.fetch(FetchDescriptor<Report>())
                SpotlightIndexer.rebuildAll(reports: reports)
                return summary
            } catch {
                syncLog.error("remote-change pipeline failed: \(error, privacy: .public)")
                return nil
            }
        }.value

        if let summary, summary.totalRemoved > 0 {
            syncLog.info("remote-change pass removed \(summary.totalRemoved, privacy: .public) duplicate rows")
        }
        if fullPipeline {
            onRemoteChangesApplied()
        }
    }
}
