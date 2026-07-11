import DispatchKit
import Foundation
import HealthKit
import Observation
import os

private let sleepLog = Logger(subsystem: "io.robbie.Dispatch", category: "awake-auto")

/// Carries a non-Sendable value across an isolation boundary the caller has
/// verified is safe (HealthKit's observer completion handler).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Signal 2 of the auto awake/asleep feature (plan 39): an HKObserverQuery
/// on sleepAnalysis plus HealthKit background delivery, modeled on
/// `WorkoutEndObserver`. BY DESIGN this is the lagged, authoritative
/// CORRECTION path, not a real-time signal: iOS accepts any frequency for
/// sleepAnalysis (forums 650330) but wakes at most ~hourly for most types
/// (the enableBackgroundDelivery doc), forum reports (763329) say
/// watch-native samples arrive minutes-or-longer after wake, and the Task 0
/// two-night device measurement (plan 39 doc, 2026-07-11) found the night's
/// samples arrive as ONE BATCH ≈4 HOURS after wake — overnight fires happen
/// but carry only the previous night's data. Real-time onset AND wake are
/// the Sleep Focus filter's job (Signal 1); do not attempt real-time
/// HealthKit onset without re-running that measurement.
///
/// Entirely test-gated: under `--mock-sensors`/`--ui-testing` this never
/// touches HealthKit. Starts regardless of authorization state — HealthKit
/// surfaces read denial as queries returning nothing, and
/// `authorizationStatus(for:)` is unreliable for read types by design.
@MainActor
@Observable
final class SleepObserver {
    static let lastSeenKey = "sleepAuto.lastSeenEndDate"
    static let windowStartKey = "sleepAuto.lastSleepWindowStart"
    static let windowEndKey = "sleepAuto.lastSleepWindowEnd"

    @ObservationIgnored private let controller: AwakeAutoController
    @ObservationIgnored private let prefs: NotificationPrefs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var query: HKObserverQuery?
    /// Serializes handleObserverFire — same rationale as WorkoutEndObserver:
    /// the handler reads the last-seen marker and then SUSPENDS at the
    /// sample fetch, so an interleaving fire would read the same stale
    /// marker and double-emit. While set, subsequent fires are skipped
    /// (their completion handlers still run in start()'s wrapper).
    @ObservationIgnored private var isHandlingFire = false

    init(controller: AwakeAutoController, prefs: NotificationPrefs,
         defaults: UserDefaults, isTestEnvironment: Bool) {
        self.controller = controller
        self.prefs = prefs
        self.defaults = defaults
        self.isTestEnvironment = isTestEnvironment
    }

    /// Starts the observer when the auto-sleep toggle is ON, stops it (and
    /// disables background delivery) otherwise. Called at launch (headless
    /// background relaunches must re-register — see DispatchApp), onAppear,
    /// and from the Settings toggle.
    func refresh() {
        guard !isTestEnvironment else { return }
        if prefs.autoSleepEnabled, HKHealthStore.isHealthDataAvailable() {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard query == nil else { return }

        // First start ever: baseline the last-seen marker to now so
        // historical sleep data doesn't fire an event storm.
        if defaults.double(forKey: Self.lastSeenKey) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
        }

        let sleepType = HKCategoryType(.sleepAnalysis)
        let observerQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) {
            [weak self] _, completionHandler, error in
            // The completion handler MUST be called on every path — missing
            // it makes HealthKit throttle background delivery. HealthKit's
            // handler type predates Sendable; the box just carries it across
            // to the main actor (calling it from any context is documented
            // as safe).
            let box = UncheckedSendableBox(value: completionHandler)
            Task { @MainActor in
                if let error {
                    sleepLog.error("sleep observer fired with error: \(error, privacy: .public)")
                } else {
                    await self?.handleObserverFire()
                }
                box.value()
            }
        }
        store.execute(observerQuery)
        query = observerQuery

        // Requesting .immediate is correct even though iOS may coalesce to
        // ~hourly — the design tolerates arbitrary lag (see the type-level
        // comment: measured arrival is ≈4h post-wake in one batch anyway).
        store.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { enabled, error in
            if let error {
                sleepLog.error("sleep background delivery enable failed: \(error, privacy: .public)")
            } else {
                sleepLog.info("sleep background delivery enabled: \(enabled, privacy: .public)")
            }
        }
    }

    private func stop() {
        guard let query else { return }
        store.stop(query)
        self.query = nil
        store.disableBackgroundDelivery(for: HKCategoryType(.sleepAnalysis)) { _, error in
            if let error {
                sleepLog.error("sleep background delivery disable failed: \(error, privacy: .public)")
            }
        }
    }

    private func handleObserverFire() async {
        guard !isHandlingFire else {
            sleepLog.info("sleep observer fire skipped — a fire is already being handled")
            return
        }
        isHandlingFire = true
        defer { isHandlingFire = false }

        let now = Date()
        let lastSeen = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastSeenKey))
        let samples = await asleepSamples(endingAfter: lastSeen)

        if let newestEndDate = samples.map(\.endDate).max() {
            // Persist BEFORE emitting so a rapid second observer fire can't
            // double-emit for the same samples (the workout-observer
            // double-fire discipline).
            defaults.set(newestEndDate.timeIntervalSince1970, forKey: Self.lastSeenKey)
        }

        // The recorded window is refreshed on EVERY fire (even eventless
        // ones) — it is display/log context, not a signal.
        await recordSleepWindow(now: now)

        guard let event = Self.deriveEvent(samples: samples, now: now) else {
            sleepLog.debug("sleep observer fire: \(samples.count, privacy: .public) new sample(s), no event")
            return
        }
        // Recency/direction/cooldown arbitration lives in the POLICY
        // (kit-tested) — this observer only describes what it saw.
        controller.handle(event, now: now)
    }

    /// At most one event per fire, from asleep-stage samples newer than the
    /// last-seen marker:
    /// - a sample covering `now` ⇒ sleep is in progress ⇒ `.healthSleepStarted`
    ///   (rare in practice — realistic only for sources that write live,
    ///   e.g. some third-party apps/beds; watch-native data arrives hours
    ///   after wake, see the type-level comment);
    /// - else the newest endDate ⇒ `.healthSleepEnded` (the policy discards
    ///   it as "stale sample" when it's outside `healthRecencyWindow` —
    ///   history updates the recorded window but is not a signal).
    static func deriveEvent(
        samples: [(startDate: Date, endDate: Date)], now: Date
    ) -> AwakeAutoPolicy.Event? {
        guard !samples.isEmpty else { return nil }
        if let covering = samples.filter({ $0.startDate <= now && $0.endDate >= now })
            .max(by: { $0.startDate < $1.startDate }) {
            return .healthSleepStarted(at: covering.startDate)
        }
        if let newestEnd = samples.map(\.endDate).max() {
            return .healthSleepEnded(at: newestEnd)
        }
        return nil
    }

    /// Asleep-stage samples (`allAsleepValues` — inBed is ignored, the
    /// `sleepSeconds` precedent) with endDate after `lastSeen`, ascending.
    private func asleepSamples(endingAfter lastSeen: Date) async -> [(startDate: Date, endDate: Date)] {
        await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            // Pre-filter in HealthKit to samples whose endDate is after the
            // last-seen marker (.strictEndDate ⇒ the sample's END, not just an
            // overlap, must fall in the window) instead of pulling everything
            // and filtering in memory. Sort stays DESCENDING so the limit
            // keeps the NEWEST samples (deriveEvent needs the max endDate /
            // covering-now sample); we re-sort ascending below. Limit-bounded
            // like the workout fetch: a full night is ~30 stage samples
            // (Task 0 measured 28), so 200 covers several nights of backlog.
            let predicate = HKQuery.predicateForSamples(
                withStart: lastSeen, end: nil, options: .strictEndDate)
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                limit: 200, sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    sleepLog.error("sleep sample fetch failed: \(error, privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }
                let asleep = (samples ?? [])
                    .compactMap { $0 as? HKCategorySample }
                    .filter { sample in
                        guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) else {
                            return false
                        }
                        return HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage)
                            && sample.endDate > lastSeen
                    }
                    .sorted { $0.endDate < $1.endDate }
                    .map { (startDate: $0.startDate, endDate: $0.endDate) }
                continuation.resume(returning: asleep)
            }
            store.execute(query)
        }
    }

    /// Persists the night's window (earliest asleep-stage start → latest end)
    /// for wake-report context. The lookback starts 18h BEFORE the start of
    /// today (≈yesterday evening), so its span is ~18–42h depending on the
    /// time of day — deliberately identical to the
    /// `sleepSeconds(sinceYesterdayEvening:)` precedent, not a rolling "last
    /// 18h". v1 consumers: this log line and the hero caption's honesty; no
    /// report-schema change (plan 39 constraint).
    private func recordSleepWindow(now: Date) async {
        // Matches sleepSeconds(sinceYesterdayEvening:) exactly; the unwrap is
        // total for this Gregorian date arithmetic (same as the precedent).
        let start = Calendar.current.date(
            byAdding: .hour, value: -18, to: Calendar.current.startOfDay(for: now))!
        let window: (start: Date, end: Date)? = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    sleepLog.error("sleep window fetch failed: \(error, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                let asleep = (samples ?? [])
                    .compactMap { $0 as? HKCategorySample }
                    .filter { sample in
                        guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) else {
                            return false
                        }
                        return HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage)
                    }
                guard let first = asleep.map(\.startDate).min(),
                      let last = asleep.map(\.endDate).max() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (start: first, end: last))
            }
            store.execute(query)
        }
        guard let window else { return }
        defaults.set(window.start.timeIntervalSince1970, forKey: Self.windowStartKey)
        defaults.set(window.end.timeIntervalSince1970, forKey: Self.windowEndKey)
        sleepLog.info("recorded sleep window \(window.start, privacy: .public) → \(window.end, privacy: .public)")
    }
}
