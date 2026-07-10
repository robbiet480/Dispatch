// PLAN-39 TASK 0 PROBE — remove after measurement.
//
// Empirical spike measuring HealthKit sleepAnalysis background-delivery
// timing on device (plan 39, Task 0): the load-bearing forum-grade claim is
// that watch-written sleep samples only reach the phone's store minutes-or-
// longer AFTER wake (Apple Developer Forums 650330/763329/781261), so Signal 2
// of the auto-sleep design can never be a real-time onset signal. This probe
// exists to replace that claim with a measurement. It logs every observer
// fire — timestamp, app state, and the delivery lag of every sleep sample in
// the last 24h — to Documents/sleep-probe.log (readable in the Files app)
// and to os_log (category "sleep-probe").
import Foundation
import HealthKit
import os
import UIKit

private let probeLog = Logger(subsystem: "io.robbie.Dispatch", category: "sleep-probe")

/// Carries HealthKit's pre-Sendable observer completion handler across the
/// hop to the main actor (same shape as WorkoutEndObserver's private box).
private struct ProbeSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// A sleepAnalysis sample reduced to the fields the probe reports. Pure data
/// so the log-line formatter is unit-testable without HealthKit objects.
struct SleepProbeSample {
    let value: Int
    let startDate: Date
    let endDate: Date
    let sourceName: String
}

/// Pure log-line formatting for the probe — the one piece worth pinning with
/// a test (lag arithmetic and stage naming feed the plan-39 measurement).
enum SleepProbeLogFormatter {
    /// ISO 8601 with fractional seconds — FormatStyle, not the reference
    /// formatter (Sendable-safe under Swift 6 strict concurrency).
    private static func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Modern HKCategoryValueSleepAnalysis case names (inBed/awake/core/deep/
    /// REM/unspecified); raw values outside the enum print as "unknown(n)".
    static func stageName(forValue value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: "inBed"
        case .asleepUnspecified: "asleepUnspecified"
        case .awake: "awake"
        case .asleepCore: "asleepCore"
        case .asleepDeep: "asleepDeep"
        case .asleepREM: "asleepREM"
        default: "unknown(\(value))"
        }
    }

    /// Signed compact duration, e.g. "42m11s" or "-3m05s" (negative = the
    /// sample's endDate is after the fire — an in-progress/future segment).
    static func lagDescription(_ interval: TimeInterval) -> String {
        let sign = interval < 0 ? "-" : ""
        let total = Int(abs(interval).rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return String(format: "%@%dh%02dm%02ds", sign, hours, minutes, seconds) }
        if minutes > 0 { return String(format: "%@%dm%02ds", sign, minutes, seconds) }
        return "\(sign)\(seconds)s"
    }

    /// One multi-line log entry per observer fire. `lag` per sample is
    /// fireDate − sample.endDate: the delivery lag this spike exists to
    /// measure (how long after a sleep segment ended did HealthKit tell us).
    static func fireEntry(fireDate: Date, appState: String, samples: [SleepProbeSample]) -> String {
        var lines = ["[\(stamp(fireDate))] fire appState=\(appState) samples(24h)=\(samples.count)"]
        for sample in samples {
            let lag = lagDescription(fireDate.timeIntervalSince(sample.endDate))
            lines.append("  \(stageName(forValue: sample.value)) \(stamp(sample.startDate)) → \(stamp(sample.endDate)) source=\"\(sample.sourceName)\" lag=\(lag)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Diagnostic observer (plan 39 Task 0): HKObserverQuery on sleepAnalysis +
/// `enableBackgroundDelivery(.immediate)` (entitlement already present —
/// WorkoutEndObserver is the shipping precedent and the pattern followed
/// here). Toggled from Settings > Sensors; the enabled flag persists so the
/// probe re-registers on launch, including HealthKit's headless background
/// relaunches. Entirely test-gated like WorkoutEndObserver.
@MainActor
@Observable
final class SleepDeliveryProbe {
    static let enabledKey = "sleepProbe.enabled"
    static let logFileName = "sleep-probe.log"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var query: HKObserverQuery?

    init(defaults: UserDefaults, isTestEnvironment: Bool) {
        self.defaults = defaults
        self.isTestEnvironment = isTestEnvironment
    }

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return defaults.bool(forKey: Self.enabledKey)
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                defaults.set(newValue, forKey: Self.enabledKey)
            }
            refresh()
        }
    }

    /// Starts the observer when the flag is on, stops it (and disables
    /// background delivery) otherwise. Called at launch and on toggle.
    func refresh() {
        guard !isTestEnvironment else { return }
        if defaults.bool(forKey: Self.enabledKey) {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard query == nil, HKHealthStore.isHealthDataAvailable() else { return }

        let sleepType = HKCategoryType(.sleepAnalysis)
        let observerQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) {
            [weak self] _, completionHandler, error in
            // The completion handler MUST be called on every path — missing
            // it makes HealthKit throttle background delivery (same contract
            // as WorkoutEndObserver; the box carries the pre-Sendable handler
            // to the main actor, documented safe to call from any context).
            let box = ProbeSendableBox(value: completionHandler)
            Task { @MainActor in
                if let error {
                    probeLog.error("sleep probe observer fired with error: \(error, privacy: .public)")
                } else {
                    await self?.handleObserverFire()
                }
                box.value()
            }
        }
        store.execute(observerQuery)
        query = observerQuery

        store.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { enabled, error in
            if let error {
                probeLog.error("sleep probe background delivery enable failed: \(error, privacy: .public)")
            } else {
                probeLog.info("sleep probe background delivery enabled: \(enabled, privacy: .public)")
            }
        }
    }

    private func stop() {
        guard let query else { return }
        store.stop(query)
        self.query = nil
        store.disableBackgroundDelivery(for: HKCategoryType(.sleepAnalysis)) { _, error in
            if let error {
                probeLog.error("sleep probe background delivery disable failed: \(error, privacy: .public)")
            }
        }
    }

    private func handleObserverFire() async {
        let fireDate = Date()
        let appState: String = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let samples = await sleepSamples(since: fireDate.addingTimeInterval(-24 * 3600))
        let entry = SleepProbeLogFormatter.fireEntry(
            fireDate: fireDate, appState: appState, samples: samples)
        probeLog.info("\(entry, privacy: .public)")
        appendToLogFile(entry)
    }

    /// sleepAnalysis samples from the last 24h, oldest first. Denied read
    /// authorization just returns nothing (HealthKit surfaces read denial as
    /// empty results by design) — the log line still records the fire.
    private func sleepSamples(since cutoff: Date) async -> [SleepProbeSample] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
            let sampleQuery = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    probeLog.error("sleep probe sample fetch failed: \(error, privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }
                let mapped = (samples ?? []).compactMap { sample -> SleepProbeSample? in
                    guard let category = sample as? HKCategorySample else { return nil }
                    return SleepProbeSample(
                        value: category.value, startDate: category.startDate,
                        endDate: category.endDate,
                        sourceName: category.sourceRevision.source.name)
                }
                continuation.resume(returning: mapped)
            }
            store.execute(sampleQuery)
        }
    }

    /// Appends to Documents/sleep-probe.log — visible in the Files app
    /// (LSSupportsOpeningDocumentsInPlace + file-sharing are already on) so
    /// the morning-after measurement needs no cable or Console session.
    private func appendToLogFile(_ entry: String) {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appendingPathComponent(Self.logFileName)
        guard let data = entry.data(using: .utf8) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            probeLog.error("sleep probe log write failed: \(error, privacy: .public)")
        }
    }
}
