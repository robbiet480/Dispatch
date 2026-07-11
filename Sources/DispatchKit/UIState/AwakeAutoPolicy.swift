import Foundation

/// Decides whether an automation signal may change the AWAKE/ASLEEP state
/// (plan 39). Pure: callers own persistence and side effects. Signal roles
/// are asymmetric BY VERIFIED PLATFORM REALITY (see plan 39 design log —
/// forums 650330/763329/781261 + the enableBackgroundDelivery doc, and the
/// Task 0 on-device measurement: the night's sleepAnalysis samples arrived in
/// a single batch ~4h AFTER wake): the Sleep Focus filter is the only
/// real-time path for both onset and wake; HealthKit events arrive
/// hours-scale late and act as authoritative, retrospective correction only.
/// Do NOT attempt real-time onset via HealthKit without re-running the Task 0
/// measurement.
public enum AwakeAutoPolicy {
    /// Manual changes outrank automation for this long — long enough to
    /// survive Sleep Focus's scheduled flip and a straggling HealthKit
    /// delivery, short enough that automation recovers the same night.
    public static let manualCooldown: TimeInterval = 90 * 60
    /// HealthKit samples older than this are history, not a signal.
    public static let healthRecencyWindow: TimeInterval = 90 * 60

    public enum Event: Equatable, Sendable {
        case focusSleepActivated
        case focusSleepDeactivated
        case healthSleepEnded(at: Date)
        case healthSleepStarted(at: Date)
    }

    public enum Decision: Equatable, Sendable {
        case transition(toAwake: Bool, reason: String)
        case ignore(reason: String)
    }

    public static func decide(
        event: Event, isAwake: Bool, lastManualChangeAt: Date?, now: Date = Date()
    ) -> Decision {
        if let manual = lastManualChangeAt, now.timeIntervalSince(manual) < manualCooldown {
            return .ignore(reason: "manual cooldown (\(Int(now.timeIntervalSince(manual) / 60))m ago)")
        }
        switch event {
        case .focusSleepActivated:
            guard isAwake else { return .ignore(reason: "already asleep") }
            return .transition(toAwake: false, reason: "sleep focus activated")
        case .focusSleepDeactivated:
            guard !isAwake else { return .ignore(reason: "already awake") }
            return .transition(toAwake: true, reason: "sleep focus deactivated")
        case .healthSleepEnded(let endedAt):
            guard now.timeIntervalSince(endedAt) < healthRecencyWindow else {
                return .ignore(reason: "stale sample (ended \(Int(now.timeIntervalSince(endedAt) / 60))m ago)")
            }
            guard !isAwake else { return .ignore(reason: "already awake") }
            return .transition(toAwake: true, reason: "health sleep period ended")
        case .healthSleepStarted(let startedAt):
            guard now.timeIntervalSince(startedAt) < healthRecencyWindow else {
                return .ignore(reason: "stale sample")
            }
            guard isAwake else { return .ignore(reason: "already asleep") }
            return .transition(toAwake: false, reason: "health sleep period started")
        }
    }
}
