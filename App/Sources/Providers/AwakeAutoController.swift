import DispatchKit
import Foundation
import Observation
import os

private let awakeLog = Logger(subsystem: "io.robbie.Dispatch", category: "awake-auto")

/// Applies AwakeAutoPolicy decisions (plan 39): the single funnel for both
/// automation signals — the Sleep Focus filter (real-time, both directions)
/// and HealthKit sleepAnalysis delivery (retrospective correction, hours-
/// scale lag per the Task 0 measurement). Gated on the Settings toggle;
/// auto transitions never present a survey (background launches have no UI,
/// and the manual pill remains the only survey-offering path).
@MainActor
@Observable
final class AwakeAutoController {
    @ObservationIgnored private let awakeStore: AwakeStore
    @ObservationIgnored private let prefs: NotificationPrefs
    @ObservationIgnored private let scheduler: NotificationScheduler
    /// Plan 37 mirror (optional by design decision): each auto TRANSITION is
    /// also recorded into the sync-diagnostics ring buffer with the same
    /// reason string os_log gets, so the diagnostics timeline shows why the
    /// state flipped. Ignores are os_log-only (debug level) — they'd flood
    /// the bounded buffer. `kindRaw` rides the buffer's unknown-kind leniency.
    @ObservationIgnored private let mirrorToDiagnostics: ((String) -> Void)?

    init(awakeStore: AwakeStore, prefs: NotificationPrefs, scheduler: NotificationScheduler,
         mirrorToDiagnostics: ((String) -> Void)? = nil) {
        self.awakeStore = awakeStore
        self.prefs = prefs
        self.scheduler = scheduler
        self.mirrorToDiagnostics = mirrorToDiagnostics
    }

    func handle(_ event: AwakeAutoPolicy.Event, now: Date = Date()) {
        guard prefs.autoSleepEnabled else { return }
        let decision = AwakeAutoPolicy.decide(
            event: event, isAwake: awakeStore.isAwake,
            lastManualChangeAt: awakeStore.lastManualChangeAt, now: now)
        switch decision {
        case .transition(let toAwake, let reason):
            awakeLog.info("auto transition → \(toAwake ? "awake" : "asleep", privacy: .public): \(reason, privacy: .public)")
            awakeStore.setAwake(toAwake, source: Self.source(for: event), now: now)
            // Replan AFTER the state change so it sees the new state —
            // same ordering contract as filterClearedInApp/replanInApp.
            scheduler.replan(prefs: prefs, awakeStore: awakeStore)
            mirrorToDiagnostics?("→ \(toAwake ? "awake" : "asleep"): \(reason)")
        case .ignore(let reason):
            awakeLog.debug("auto event \(String(describing: event), privacy: .public) ignored: \(reason, privacy: .public)")
        }
    }

    private static func source(for event: AwakeAutoPolicy.Event) -> AwakeChangeSource {
        switch event {
        case .focusSleepActivated, .focusSleepDeactivated: .focusFilter
        case .healthSleepEnded, .healthSleepStarted: .health
        }
    }
}
