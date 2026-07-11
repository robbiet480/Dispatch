import Foundation
import Testing
@testable import DispatchKit

// Plan 39 Task 2 — the pure auto-sleep decision machine. Every case asserts
// BOTH the decision and the reason-string prefix, because the app's os_log
// trace is diffed against these reasons in the field.

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
private func minutes(_ m: Double) -> TimeInterval { m * 60 }

// MARK: - Focus filter (Signal 1, real-time both directions)

@Test func focusActivationWhileAwakeTransitionsAsleep() {
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepActivated, isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: false, reason: "sleep focus activated"))
}

@Test func focusActivationWhileAlreadyAsleepIgnores() {
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepActivated, isAwake: false, lastManualChangeAt: nil, now: t0)
    #expect(d == .ignore(reason: "already asleep"))
}

@Test func focusDeactivationWhileAsleepTransitionsAwake() {
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepDeactivated, isAwake: false, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: true, reason: "sleep focus deactivated"))
}

@Test func focusDeactivationWhileAwakeIgnores() {
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepDeactivated, isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .ignore(reason: "already awake"))
}

// MARK: - HealthKit sleep ended (lagged wake correction)

@Test func healthSleepEndedRecentWhileAsleepTransitionsAwake() {
    let endedAt = t0.addingTimeInterval(-minutes(30))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: false, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: true, reason: "health sleep period ended"))
}

@Test func healthSleepEndedStaleIgnores() {
    // Older than healthRecencyWindow (90m) — history, not a signal.
    let endedAt = t0.addingTimeInterval(-minutes(200))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: false, lastManualChangeAt: nil, now: t0)
    guard case .ignore(let reason) = d else { Issue.record("expected ignore, got \(d)"); return }
    #expect(reason.hasPrefix("stale sample"))
}

@Test func healthSleepEndedWhileAlreadyAwakeIgnores() {
    let endedAt = t0.addingTimeInterval(-minutes(10))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .ignore(reason: "already awake"))
}

// MARK: - HealthKit sleep started (rare live-onset source)

@Test func healthSleepStartedRecentWhileAwakeTransitionsAsleep() {
    let startedAt = t0.addingTimeInterval(-minutes(20))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepStarted(at: startedAt), isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: false, reason: "health sleep period started"))
}

@Test func healthSleepStartedStaleIgnores() {
    let startedAt = t0.addingTimeInterval(-minutes(200))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepStarted(at: startedAt), isAwake: true, lastManualChangeAt: nil, now: t0)
    guard case .ignore(let reason) = d else { Issue.record("expected ignore, got \(d)"); return }
    #expect(reason.hasPrefix("stale sample"))
}

@Test func healthSleepStartedWhileAlreadyAsleepIgnores() {
    let startedAt = t0.addingTimeInterval(-minutes(10))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepStarted(at: startedAt), isAwake: false, lastManualChangeAt: nil, now: t0)
    #expect(d == .ignore(reason: "already asleep"))
}

// MARK: - Manual cooldown (both directions, all four events)

@Test func everyEventIgnoredWithinManualCooldown() {
    let manual = t0.addingTimeInterval(-minutes(30)) // 30m < 90m cooldown
    let events: [AwakeAutoPolicy.Event] = [
        .focusSleepActivated,
        .focusSleepDeactivated,
        .healthSleepEnded(at: t0.addingTimeInterval(-minutes(5))),
        .healthSleepStarted(at: t0.addingTimeInterval(-minutes(5))),
    ]
    // Both standing states — manual-asleep suppresses focus-wake, and
    // manual-awake suppresses focus-sleep.
    for isAwake in [true, false] {
        for event in events {
            let d = AwakeAutoPolicy.decide(
                event: event, isAwake: isAwake, lastManualChangeAt: manual, now: t0)
            guard case .ignore(let reason) = d else {
                Issue.record("expected cooldown ignore for \(event) isAwake=\(isAwake), got \(d)")
                continue
            }
            #expect(reason.hasPrefix("manual cooldown"))
        }
    }
}

@Test func cooldownExpiresAtNinetyMinutesPlusOne() {
    let manual = t0.addingTimeInterval(-(AwakeAutoPolicy.manualCooldown + 1))
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepActivated, isAwake: true, lastManualChangeAt: manual, now: t0)
    #expect(d == .transition(toAwake: false, reason: "sleep focus activated"))
}

@Test func nilManualChangeAtMeansNoCooldown() {
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepActivated, isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: false, reason: "sleep focus activated"))
}

// MARK: - Conflicting-signal sequences (folded)

// (a) Manual wake, Sleep Focus still active re-fires activation, then a lagged
// HealthKit sleep-ended delivery — state stays awake throughout.
@Test func sequenceManualWakeThenStragglingSignals() {
    let manualWake = t0                       // manual awake at 06:00
    let reactivate = t0.addingTimeInterval(minutes(10)) // Focus re-fires 06:10
    let d1 = AwakeAutoPolicy.decide(
        event: .focusSleepActivated, isAwake: true,
        lastManualChangeAt: manualWake, now: reactivate)
    guard case .ignore(let r1) = d1 else { Issue.record("expected ignore, got \(d1)"); return }
    #expect(r1.hasPrefix("manual cooldown"))

    // HealthKit sleep-ended-06:05 delivered 07:45 — cooldown has expired
    // (>90m) but the state is already awake, so still a no-op.
    let delivery = t0.addingTimeInterval(minutes(105))
    let endedAt = t0.addingTimeInterval(minutes(5))
    let d2 = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: true,
        lastManualChangeAt: manualWake, now: delivery)
    // Stale by recency (ended 100m ago) — ignore either way; assert it's an ignore.
    guard case .ignore = d2 else { Issue.record("expected ignore, got \(d2)"); return }
}

// (b) Sleep Focus on (→ asleep), user manually flips awake (insomnia), Focus
// deactivation later → ignore (already awake).
@Test func sequenceInsomniaManualWakeThenFocusDeactivation() {
    let manualWake = t0.addingTimeInterval(minutes(60)) // 23:00
    let deactivate = t0.addingTimeInterval(minutes(540)) // 07:00, well past cooldown
    let d = AwakeAutoPolicy.decide(
        event: .focusSleepDeactivated, isAwake: true,
        lastManualChangeAt: manualWake, now: deactivate)
    #expect(d == .ignore(reason: "already awake"))
}

// (c) Focus deactivates (→ awake), HealthKit delivers sleep-ended shortly
// after → ignore (already awake, correct no-op).
@Test func sequenceFocusWakeThenHealthConfirmation() {
    let endedAt = t0.addingTimeInterval(-minutes(8))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: true, lastManualChangeAt: nil, now: t0)
    #expect(d == .ignore(reason: "already awake"))
}

// (d) NO Focus configured: healthSleepEnded while asleep → transition awake
// (health as the sole, lagged wake path).
@Test func sequenceHealthSoleWakePath() {
    let endedAt = t0.addingTimeInterval(-minutes(45))
    let d = AwakeAutoPolicy.decide(
        event: .healthSleepEnded(at: endedAt), isAwake: false, lastManualChangeAt: nil, now: t0)
    #expect(d == .transition(toAwake: true, reason: "health sleep period ended"))
}

@Test func cooldownConstantsAreNinetyMinutes() {
    #expect(AwakeAutoPolicy.manualCooldown == 90 * 60)
    #expect(AwakeAutoPolicy.healthRecencyWindow == 90 * 60)
}
